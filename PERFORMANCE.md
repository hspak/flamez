# Reusable performance work from Zimbr

This document records performance techniques implemented in Zimbr that transfer
to other Zig desktop applications using SDL3 and an immediate-mode layout layer
such as Clay. It complements [FRAME_PACING.md](FRAME_PACING.md): that document
explains when to draw; this one explains how to reduce the work behind a frame,
a content update, or a media request.

The implementation references describe revision `c56dfc1` (0.4.1), reviewed on
2026-10-03, with Zig 0.16.0 and Zimbr's patched SDL 3.4.16. Earlier changes are
identified where useful. This is an implementation and reasoning reference,
not a new benchmark report. Bounds below are current policy choices; complexity
estimates explain the design rather than assert measured speedups.

## Applicability to Zig, SDL3, and Clay

Zimbr previously used Clay through `zclay`. Commit `44ef2cf` replaced its small
pane-layout tree with application-owned geometry in
[layout.zig](src/client/layout.zig). The current text stack is Pango/Cairo, with
SDL owning rendering and textures. Keeping this distinction explicit matters:
the text and Vulkan optimizations below are not features of Clay itself.

Clay produces renderer-independent commands and accepts an application-supplied
text measurement function. Those are the integration points for an SDL renderer
and a cached text service. See the [upstream Clay documentation](https://github.com/nicbarker/clay#readme).
The adaptations below are design suggestions based on Zimbr's implementation;
they are not claims that the current client exercises Clay.

| Layer in another application | Zimbr techniques to carry over |
|---|---|
| Zig model and worker boundary | Immutable records, separate content generations, bounded publication, explicit ownership |
| Clay declarations or custom layout | Visible-range construction, incremental measurements, stable row identities and reading anchors |
| Text measurement/rendering service | Separate metrics, shaped layouts and raster appearances; reuse setup; stable scale |
| SDL render-command adapter | Native pixel formats, indexed meshes, bounded texture reuse, GUI-thread resource ownership |
| SDL direct Vulkan backend | Completed upload-buffer reuse, indexed submission, command-list-local descriptor reuse |
| Storage and transport | Lazy projections, transactional batches, prepared statements, exact JSON bytes, amortized maintenance |

An immediate-mode API does not require every underlying resource to be recreated
every frame. Keep the declarations transient while retaining expensive results
whose inputs have not changed. For Clay, keep persistent application caches
outside its per-layout declarations and keep referenced strings/resources alive
through command consumption. Any deferred rendering needs its own ownership.

## 1. Publish immutable records instead of rebuilding the entire model

**Problem.** A status update, draft save, or one-message edit can accidentally
trigger JSON parsing, display-text preparation, allocation, and copying for the
entire selected conversation. A background worker prevents that parsing from
blocking the GUI directly, but still consumes CPU and delays publication.

**How Zimbr implements it.**
[MessageHistory.zig](src/client/MessageHistory.zig) gives each message record an
independent arena and reference count. The record owns the parsed message,
prepared display text, rich blocks, revision, and enrichment serial.

When rebuilding history, the worker compares ordered IDs, revisions, and
enrichment serials with the previous history. It first checks the corresponding
array position, then falls back to an ID index for prepends or reordering. Only
changed records need their full JSON fetched and parsed. An unchanged prefix
requires no scratch pointer array or per-record reference increments until an
actual change is found. A completely unchanged history retains the existing
history object.

[SharedSnapshot.zig](src/client/SharedSnapshot.zig) shares that history between
publications. Reuse requires the same selected conversation and source epoch.
[Worker.publish](src/client/Worker.zig) maintains separate overall and content
generations; connection diagnostics, upload progress, and drafts can be published
without replacing the message history. The GUI uses the content generation to
decide whether to rebuild prepared rows.

**Why it works.** Expensive work follows changed content rather than publication
frequency. If `N` messages are loaded and `K` change, parsing and presentation
preparation are proportional to `K` instead of `N`. Independently owned records
also prevent one reused message from retaining an obsolete snapshot's whole
arena. Ownership remains valid while the GUI finishes with an older publication.

**When it works and what remains.** This fits read-mostly lists with reliable
identity/version semantics. It does not make an edited history an `O(K)` operation:
the version query still scans loaded history, and a changed history rebuilds
arrays and its index. Status-only publication still allocates a small view and
does diagnostic/draft work. Rich metadata can change at the same message
revision, which is why the enrichment serial is also part of reuse validation.

For a Clay application, retain the immutable snapshot while constructing and
consuming the frame's declarations. Use record identity for widget IDs; the
visible array index changes when older rows are prepended.

**Evidence.** [client_tests.zig](src/client_tests.zig),
`incremental snapshots preserve versions through prepends, reordering, failure and epoch replacement`,
and the shortened-history lifetime test in `MessageHistory.zig`. Measure cold,
unchanged, edit, and append publication separately with
[client_bench.zig](src/client_bench.zig).

## 2. Invalidate geometry according to its actual dependencies

**Problem.** Treating every new view or message revision as a layout change makes
status transitions and connection updates as expensive as text edits. Unstable
scale calculations can turn a harmless resize into a complete text-cache flush.

**How Zimbr implements it.** `App.prepareHistory` in
[client_main.zig](src/client_main.zig) separates several dependencies:

- The row collection depends on content generation.
- Height-cache context depends on conversation, available text width, and scale.
- Individual row heights depend on prepared presentation keys, including sender
  presentation where applicable.
- Rich-block heights have their own keys covering text, width, scale, link count,
  or reaction labels/counts. Attachment/card geometry is computed directly.
- Viewport height affects visibility, scroll limits, and following the bottom;
  it does not inherently change text wrapping.

For ordinary text, the prepared key is derived from display text. Rich content
uses a broader record-derived key because attachments and other metadata can
affect geometry. This is deliberately not a claim that every status update in
every rich message avoids invalidation.

[desktop.zig](src/client/desktop.zig) uses the reported window display scale as
the authoritative scale. Rounded framebuffer dimensions divided by logical
dimensions are not a stable substitute at fractional scale. A one-pixel resize
must not masquerade as a font-scale change. Actual scale changes do invalidate
the text cache through `Text.nextFrame`.

**Why it works.** Invalidation determines how often every downstream optimization
gets a chance to help. Stable dependencies preserve shaped text, row heights,
and textures through unrelated updates. A cached rich-block height is especially
useful when reading-anchor maintenance revisits a partially visible long message
on every frame.

**When it works and what remains.** Use this whenever derived work has several
independent inputs. Under-invalidation is a correctness bug: font/style changes,
metadata affecting size, and the number of extra link rows must still invalidate
the relevant results. A new application's mutable fonts or themes need explicit
generations in its cache keys even if Zimbr's fixed configuration does not.

In Clay, apply these keys to your measurement and rendering services; do not
equate a new set of declarations with a new set of glyph textures.

**Evidence.** Native tests in `client_main.zig` cover rich-block dependencies,
unchanged reading-anchor measurements, send/echo transitions, and horizontal and
vertical resizing. The `rich_anchor`, `caret`, and resize rendering workloads
exercise different invalidation mistakes.

## 3. Virtualize history and spread cold measurement over frames

**Problem.** Drawing only visible rows is insufficient if opening or reflowing a
conversation first shapes every message. A single cold layout pass can still
stall interaction for a large archive.

**How Zimbr implements it.** `prepareHistory`, `measureHistory`, `historyStart`,
and `visibleHistory` in [client_main.zig](src/client_main.zig) keep lightweight
rows with cached or estimated heights and ordered vertical positions. Binary
search locates the visible interval. Drawing and lazy metadata collection iterate
that interval rather than the entire history.

Unmeasured rows initially use a one-line estimate plus padding. Measurement first
serves the visible region: newest rows when following the bottom, or the saved
reading anchor when scrolled. Remaining work resumes newest-to-oldest from a
cursor. Each pass permits at most 256 new row measurements and normally stops
after a 2 ms deadline. It guarantees an initial measurement so a slow preparation
phase cannot prevent progress forever. Cached heights do not consume that
measurement count.

The active conversation retains all measured heights. An earlier cap that
cleared the cache during layout could make a history larger than the cap start
over repeatedly. Small scalar heights and expensive GPU rasters therefore have
different retention policies.

**Why it works.** Settled visible-range lookup and iteration cost approximately
`O(log N + V)` for `N` loaded rows and `V` visible rows. Cold work becomes a series
of bounded opportunities to progress, allowing input and presentation between
batches. Prioritizing visible rows improves time to useful content even before
the whole archive has settled.

**When it works and what remains.** Use this for variable-height timelines,
logs, search results, or document blocks. The 2 ms value is a cooperative budget,
not a hard latency bound: one synchronous Pango measurement can overrun it.
Snapshot preparation and `positionHistory` can still perform `O(N)` work, and
height storage grows with loaded history. This is not complete storage/window
virtualization.

For Clay, one adaptation is to emit only visible rows with spacer extents for
the skipped prefix/suffix, or use a custom history region inside a Clay pane.
Merely clipping a declaration for every row does not remove application-side
construction or measurement. Preserve scroll extents and stable row IDs either
way, and choose one owner for scroll position.

**Evidence.** Tests cover histories above the former cache limit, progress and
yielding, and visible-first loading. The `reflow` benchmark reports both per-frame
cost and frames/total work to settle. A smaller batch can improve individual
frames while delaying convergence; both results matter.

## 4. Preserve a reading anchor while estimates become exact

**Problem.** Deferred layout is fast but unusable if every newly measured row
pushes the text being read. Preserving only the absolute scroll offset cannot
handle prepended history or an earlier image acquiring its true dimensions.

**How Zimbr implements it.** `rememberHistoryAnchor` records a stable row ID and
its offset from the viewport. Rich content can additionally retain the visible
block's ID, kind, and offset. When rows are repositioned, `positionHistory`
restores that relationship. Measuring rows above the anchor adjusts scroll by
their height delta. Follow mode instead keeps the latest content at the bottom.

`visibleHistory` exposes a contiguous range of fully measured rows outward from
the reading location. It does not draw an estimated-height bubble that would
later move already visible content. When a saved block lies beyond a temporary
estimate, measurement resolves its row first and avoids prematurely clamping
the scroll position against incomplete geometry.

Row positions and scroll offsets use `f64`; subtraction happens before converting
to drawing coordinates. This avoids accumulating visible `f32` error over very
large histories. Bottom-following rows round the viewport bottom and their
distance from that bottom separately at display scale, keeping header/body
pixels stable during height changes.

**Why it works.** The invariant becomes “this content stays at this screen
offset,” which remains meaningful as total content height changes. That makes
incremental measurement possible without a visual jump at every batch.

**When it works and what remains.** Use stable content identity rather than
array position. Define a fallback when the anchor is deleted, and distinguish
following new content from reading older content. Height estimates still affect
the scrollbar while layout converges. This technique stabilizes the reading
position; it does not make all geometry final immediately.

**Evidence.** Native tests cover prepends, deferred heights, small upward scrolls,
and an earlier attachment changing dimensions while a later part remains visible.
The fractional-scale resize tests protect the pixel-position invariant.

## 5. Separate scalar measurements, shaped layouts, and raster textures

**Problem.** A single “text cache” mixes resources with very different costs.
Measuring thousands of offscreen messages can evict the layouts and textures
needed for the handful of rows on screen. Rasterizing a whole long document
also consumes memory proportional to document height rather than visibility.

**How Zimbr implements it.** [Text.zig](src/client/Text.zig) separates:

1. Scalar row/block heights retained by the application's history caches.
2. Up to 384 reusable Pango layouts for recent drawing and text interaction.
3. GPU rasters generated only when a layout is drawn, with a 32 MiB live budget.

`Text.height` can retain a layout useful for visible drawing. `Text.measure`
creates a temporary layout, reads its height, and frees it without inserting it
into the drawing cache. Background history measurement uses that path. This still
performs shaping once; its benefit is avoiding pollution of the visible cache.

`drawEntry` limits rasterization to the portion intersecting the window and aligns
its range to 256 physical-pixel bands. Each upload is at most 2,048 pixels high;
tall windows may need several such chunks. This is an aligned raster range, not
a promise that every texture is exactly 256 pixels tall. SDL clipping handles
the finer pane boundary.

**Why it works.** A height is a few bytes, a shaped layout has native allocation
and shaping costs, and a raster costs roughly `width × height × 4` bytes before
driver overhead. They deserve different lifetimes. Aligned ranges let small
scroll movements reuse raster work instead of creating a new texture for every
one-pixel viewport offset.

**When it works and what remains.** This fits long wrapped text with a small
visible working set. It does not eliminate full-string shaping, which is why
Zimbr also bounds text input and defers row measurement. Highly variable width,
scale, or content can still produce many layout misses. Font fallback and layout
objects consume memory outside the GPU-byte budget.

For Clay, use a metrics service compatible with the drawing service. Measuring
with approximate character widths and drawing with Pango can produce different
wraps. Decide whether Clay or the text engine owns wrapping; avoid two independent
wrapping decisions for the same paragraph.

**Evidence.** `offscreen measurements match drawing metrics without evicting layouts`
in [client_main.zig](src/client_main.zig) protects cache isolation. Compare
`cached`, `scroll`, `cold_text`, and `reflow`; none substitutes for the others.

## 6. Cache several raster appearances and normalize invisible differences

**Problem.** One texture per shaped string thrashes when the same avatar initial
appears in several participant colors. Including the current caret offset in a
raster key also forces uploads even though a collapsed selection paints nothing.

**How Zimbr implements it.** Each `Text.Entry` keeps up to 16 raster appearances,
all charged to the shared 32 MiB live-texture budget. A raster key includes its
vertical range, foreground, optional background, and actual selection range.
The oldest appearance is evicted at the per-layout limit; global eviction frees
old rasters when byte capacity is needed.

A collapsed selection always uses `start = 0, end = 0` for rasterization,
regardless of caret position. Real nonempty selections remain distinct.
Caret drawing/hit testing can reuse the shaped layout without modifying its
unselected glyph pixels.

**Why it works.** Several concurrently useful appearances can coexist. The
shared-initial case changes from repeatedly rasterizing/uploading each color to
reusing a small working set. Canonicalizing “no selection” removes a dependency
that never affected the raster's output.

**When it works and what remains.** This helps repeated labels, avatars, search
highlights, and editors with frequent cursor motion. Sixteen is tuned to Zimbr's
appearances, not a universal optimum. Animated colors or many selection ranges
can still churn; an application with freely varying tint may benefit from an
appropriate mask-based renderer instead. Background belongs in the key when
the text raster was composited against that background.

**Evidence.** Native tests inspect colored rasters, bounded eviction, and pixels
under collapsed versus real selections. The `cached --avatars shared` fixture
stresses color reuse; `caret` moves through 64 collapsed-selection positions.

## 7. Reuse immutable Pango setup per thread

**Problem.** Even with an application layout cache, cold text and deferred height
measurement create many new layouts. Repeating Cairo/Pango context setup for
each string adds overhead unrelated to that string's content.

**How Zimbr implements it.** `text_layout` in
[bridge.c](src/client/bridge.c) retains two Pango contexts per thread, one for each
antialiasing mode. A slot is reusable only when its scale, font-map identity,
and font-map serial match. The cached context stays immutable. Replacing a slot
releases the cache's reference, while existing layouts retain their references
to the old context. Thread-local teardown releases the remaining cache entries.

**Why it works.** Repeated layout creation pays for new string-specific layout
work without repeatedly constructing identical native setup. Immutable setup
avoids changing the meaning of layouts that are still in use.

**When it works and what remains.** This applies to Pango/Cairo users; a Clay
application with another font engine needs its equivalent setup object. It helps
cache misses and reflow, not just warm redraws. It does not cache every layout or
remove font fallback and shaping. If language, font options, or resolution become
mutable, include those dependencies in setup reuse. Keep thread-affine native
objects on their owning thread.

**Evidence.** The implementation arrived in `a9a7d2f`. The `cold_text` workload
rebuilds application layouts and rasters while still benefiting from this native
setup cache; it is therefore not a fully cold process/font-cache benchmark.

## 8. Remove pixel-format work before trying to accelerate it

**Problem.** Text and image pipelines often rasterize into one representation,
convert every pixel into another, then upload it. A faster conversion still
moves a whole extra image through memory.

**How Zimbr implements it.** `graphics.uploadPixels` in
[graphics.zig](src/client/graphics.zig) accepts native Cairo ARGB pixels with
their actual row pitch, creates `SDL_PIXELFORMAT_ARGB8888` storage, and selects
premultiplied blending. The text bridge exposes Cairo's bytes directly.
`drawRaster` copies at one physical source pixel per destination pixel with
nearest filtering; Pango/Cairo has already rasterized at display scale.

For JPEGs, [media.c](src/client/media.c) requests `JCS_EXT_RGBA` when the decoder
supports it. Scanlines go directly into the final CPU RGBA buffer, including
opaque alpha. The fallback uses a bounded RGB scanline and adds alpha explicitly.
GPU upload remains a separate operation on the GUI thread.

**Why it works.** Removing a full-image conversion eliminates its CPU arithmetic,
intermediate storage, and memory traffic. A 512 × 512 four-byte image is already
1 MiB per pass. Avoiding unpremultiplication also avoids integer divisions and
unnecessary rounding of antialiased edge colors.

**When it works and what remains.** The producer's byte layout, alpha convention,
consumer format, and blend mode must agree. Cairo ARGB is a native packed-pixel
format, not a promise of literal A/R/G/B byte order on every machine. Preserve
the real pitch; it need not equal `width × 4`. Straight-alpha RGBA still takes
the straight-alpha path. Subpixel text rasterized against a background cannot be
freely reused over a different background.

This avoids an application conversion; it is not zero-copy GPU upload. SDL and
the driver can still stage or convert internally.

**Historical distinction.** The September SIMD pass (`9d9f840`) accelerated the
old opaque Cairo-to-RGBA conversion. The current SDL pipeline removes that
conversion, so copying its old vector loop into a new renderer would reinstate
work Zimbr no longer needs. Direct JPEG RGBA output remains useful.

**Evidence.** Native graphics/text pixel tests and
[tests/client_pixel_safety.py](tests/client_pixel_safety.py) cover the pixel
boundary. Use `cold_text` and `image_upload` to measure raster/upload effects,
and decoder-specific measurements for JPEG; those are different workloads.

## 9. Keep shared geometry shared all the way to the backend

**Problem.** Rounded UI shapes contain many triangles sharing positions and
colors. Expanding every triangle into independent vertices increases CPU
conversion and upload work. Supplying indices at the application boundary is
insufficient if the renderer immediately expands them again.

**How Zimbr implements it.** [shapes.zig](src/client/shapes.zig) builds bounded
contours and index arrays, then calls `graphics.mesh`/`SDL_RenderGeometryRaw`.
It chooses corner segmentation from physical radius, bounded between 8 and 64
segments per quarter-circle. Coverage fringes in vertex alpha provide smooth
edges without a per-shape texture or render target.

Zimbr's [Vulkan patch](build/sdl/vulkan.patch) changes the pinned direct Vulkan
backend to retain shared vertices, normalize indices to 32 bits, and use indexed
draws. It selects index-width conversion outside the vertex loop. Vertices and
indices share the existing GPU buffer lifetime, and contiguous index ranges
preserve SDL's batching. Buffer-size/offset calculations retain overflow checks.

**Why it works.** If a mesh has `U` unique vertices and `I` triangle indices,
expanded storage is roughly `I × vertex_size`; indexed storage is
`U × vertex_size + I × index_size`. Reuse pays when the saved repeated vertices
outweigh the index stream. It also reduces repeated position/color conversion.
Bounded contour arrays avoid heap allocation per shape.

**When it works and what remains.** This helps rounded rectangles, strokes,
circles, and other meshes with substantial sharing. Tiny or entirely unique
triangles may gain little. Tessellation and upload still occur; Zimbr does not
cache all shape meshes. The backend change applies to the patched direct Vulkan
renderer, not automatically to SDL's separate GPU renderer or OpenGL backend.

For Clay, implement its shape commands through your SDL adapter while preserving
command order, clipping, and blending. Sorting arbitrary translucent UI commands
by texture can change their meaning even if it reduces state changes.

**Evidence.** Compare rendering backends with the same synthetic scene and verify
shape/clip pixels separately. An indexed application API alone is not evidence
that less vertex data reaches the GPU; inspect the selected backend as Zimbr did.

## 10. Reuse retired SDL texture storage within a separate budget

**Problem.** Evicting a cached raster can immediately destroy an SDL texture.
The next raster then creates equivalent storage. Allocation, destruction, and
backend synchronization can dominate workloads that look like simple uploads.

**How Zimbr implements it.**
[graphics/TexturePool.zig](src/client/graphics/TexturePool.zig) keeps a FIFO of
retired static four-byte textures, bounded by both 128 entries and 8 MiB of pixel
storage. `take` matches format, width, and height. `uploadPixels` restores blend
and filter settings and overwrites the pixels before the texture is used again.
Render targets, unsupported formats/access types, and oversized textures are
destroyed immediately. The pool is drained before renderer shutdown.

**Why it works.** Content eviction and storage destruction need not be the same
operation. Repeated dimensions can reuse allocations while the logical cache
still forgets the old content. Bounding entries as well as bytes prevents tiny
textures from creating unbounded driver-object overhead.

**When it works and what remains.** This is useful when scrolling, color/selection
changes, or repeated media sizes cause texture churn. It adds up to 8 MiB of
retired pixel capacity beyond live text/image budgets; driver metadata and
alignment are additional. Poor dimension reuse reduces its benefit. FIFO
eviction and exceptional sizes can still trigger destruction costs.

Queued draws may still reference an old texture's pixels. This design relies on
SDL preserving queued uses when a later SDL texture update occurs. A custom GPU
pool needs explicit completion/lifetime tracking; “removed from the cache” is
not proof that the GPU has finished. Reuse reduces allocation churn, not upload
bandwidth or every synchronization point.

**Evidence.** `retired texture storage is reused without changing queued draws`
and `text remains intact when layouts evict textures queued in the same frame`
in [client_main.zig](src/client_main.zig) test the important lifetime behavior.
The `image_upload` workload includes upload, draw, and retirement.

## 11. Recycle upload buffers only after GPU completion

**Problem.** Application texture reuse still leaves the backend allocating
temporary transfer buffers for uploads. A burst of cold glyphs can also exhaust
a small upload batch and force additional submission/wait work.

**How Zimbr implements it.** The [SDL Vulkan patch](build/sdl/vulkan.patch)
retains completed staging buffers instead of destroying every used buffer when
a command list resets. A buffer can serve a later upload if its capacity is
sufficient; an undersized buffer is replaced. The patch raises upload slots
from 32 to 128 and retains at most 8 MiB of buffer capacity per command buffer
after completion. Larger bursts can temporarily require more; the retention
limit is not a hard bound on in-flight upload memory.

Reuse begins only after the associated fence or queue-idle condition establishes
completion. Swapchain recreation and renderer destruction release every retained
slot, including slots not used by the most recent batch.

**Why it works.** Repeated uploads reuse expensive driver allocations. A larger
slot limit can accommodate more small uploads before the backend must break a
batch. This optimizes a different allocation layer from the SDL texture pool:
one retains destination storage, the other transfer storage.

**When it works and what remains.** This is specific to the patched SDL direct
Vulkan implementation. It helps upload-heavy frames; a warm scene with no uploads
has little reason to benefit. Retained memory scales with command-buffer count,
plus driver allocation overhead. It does not remove transfer copies, barriers,
or the requirement to wait before overwriting in-flight memory.

**Evidence.** Use `cold_text` and `image_upload` with backend CPU profiles. Verify
resize/recreation and shutdown as well as steady-state uploads. Patch provenance
and update requirements are in [vendor/sdl/README.zimbr](vendor/sdl/README.zimbr).

## 12. Reuse shader constants and bindings within their valid lifetime

**Problem.** Repeated draws may use identical shader constants and the same
texture/sampler bindings, yet allocate and update a descriptor set each time.
Small UI draws can become dominated by CPU submission overhead.

**How Zimbr implements it.** The [Vulkan patch](build/sdl/vulkan.patch) assigns a
generation to each command list. A pipeline remembers the constant-buffer
location holding its current constant bytes for that generation. Identical
constants reuse that location.

A bounded, 256-entry lookup caches descriptor bindings by generation, descriptor
layout, constant buffer and offset, image views, and samplers. A hit reuses an
existing immutable descriptor set. A collision replaces the CPU lookup entry;
it never updates a descriptor set already referenced by queued GPU commands.
Command-list reset changes the generation, invalidating those lookup results.

**Why it works.** Several draws can share one immutable GPU description of the
same resources. Reducing constant copies and descriptor allocation/update calls
reduces CPU work without changing draw order or pixels.

**When it works and what remains.** Repeated pipeline/texture combinations within
one command list benefit. Constantly changing bindings or lookup collisions can
reduce hits. Reuse across frames would require a broader resource-lifetime
design; Zimbr deliberately limits reuse to the command list's lifetime. Pointer
equality alone is insufficient after resource destruction or descriptor-pool
reset.

**Evidence.** Profile the actual direct Vulkan backend under the cached scene,
including repeated avatar appearances. Validate visual output with mixed
textures and clips. Fewer descriptor updates are a local result; confirm that
whole-frame CPU time improves too.

## 13. Keep media I/O and decoding off the GUI thread, with backpressure

**Problem.** Downloading or decoding an image on demand during drawing can stall
input. Moving it to a worker without bounds can instead accumulate a large queue
of stale requests and decoded images when the user scrolls rapidly.

**How Zimbr implements it.** [Media.zig](src/client/Media.zig) owns a separate
authenticated media lane, two active download slots, a queue capped at 128
requests, and one decoded-result handoff slot. Requests are deduplicated across
queued, active, and completed work. Context generations cancel obsolete work;
stale results do not become images for a new selection. Local staged-attachment
previews use the media worker too, including offline previews (`d2bc2ff`).

The GUI owns SDL texture creation/destruction through
[ImageCache.zig](src/client/ImageCache.zig). It accepts a decoded buffer, validates
dimensions and byte count, makes budget room, uploads, and marks the entry ready
only after upload succeeds. Failed uploads remain retryable and do not count as
resident textures.

The system bounds different resources separately: 512 MiB nominal disk cache,
64 MiB live image textures, bounded encoded/decoded files, and bounded cache
entry counts. These are not a single total-process memory limit. Requests carry
compact keys and generation numbers rather than borrowing transient GUI data.

**Why it works.** Network/disk/decode latency leaves the input/render thread.
The bounded result slot applies backpressure when the GUI cannot consume as
quickly as the worker produces. Deduplication avoids paying for the same asset
repeatedly; cancellation stops old views competing with current work.

**When it works and what remains.** This applies to thumbnails, document previews,
avatars, and image viewers. GUI-thread uploads still cost time, and one large
upload can remain a frame spike. More worker threads are not automatically better:
they can increase CPU contention, peak memory, and stale work. Adapt concurrency
and handoff capacity to the upload budget and visible working set.

**Evidence.** `ImageCache.zig` tests cover local preview transfer and failed
uploads. [tests/client_media_transport.py](tests/client_media_transport.py)
exercises the transport/cache path. Measure first-visible-image latency alongside
GUI responsiveness and peak memory, not download throughput alone.

## 14. Fetch cheap useful content first and defer enrichment to visibility

**Problem.** A conversation list can create one request per conversation for
previews. Opening history can make the user wait for every attachment, link card,
and reaction even when plain text is enough to begin reading.

**How Zimbr implements it.** The protocol and
[Worker.zig](src/client/Worker.zig) support two complementary projections:

- Conversation pages can include compact latest-message previews. They live in
  a separate client table and cannot overwrite canonical full message text.
- Text-first history retains full text and identity/version information while
  deferring rich metadata. The GUI collects IDs only from visible deferred rows,
  bounded to 64 IDs and coalesced over a 250 ms interval. The worker hydrates
  messages through cancellable requests after more urgent work.

Selection/history work takes precedence over background directory or metadata
fetches. A send can preempt an idempotent background GET; that priority mechanism
does not cancel and replay a message POST. Image bytes remain on the independent
media lane. Capability negotiation retains compatibility with older relays.

Background historical events update synchronization and previews without
automatically filling the client with every unrequested old message. Requested
history and live content follow their own cache rules in
[Store.zig](src/client/Store.zig).

**Why it works.** First useful content requires fewer bytes, fewer requests, and
less parsing. Work scales with what the user opens and sees. Priority prevents
optional enrichment from creating head-of-line blocking for interaction.

**When it works and what remains.** This needs a data model that distinguishes
partial projections from authoritative records. Same-revision enrichment must
upgrade the projection without overwriting newer text or metadata. Permanent
deprioritization can starve background work, so scheduling must still provide
progress when interaction quiets. Rich content appears later; this is an explicit
latency tradeoff, not a claim that total network work always decreases.

For a Clay UI, publish the base text first and request enrichment from the visible
model interval. Retain anchors when later metadata changes row height.

**Evidence.** [tests/client_lazy_history.py](tests/client_lazy_history.py),
[tests/client_enrichment.py](tests/client_enrichment.py), and the history/projection
tests in `client_tests.zig`. Commit `438f820` contains the lazy-media work;
[docs/api.md](docs/api.md) describes the transport contract.

## 15. Batch durable work and coalesce publications independently

**Problem.** A network burst can trigger one transaction and one full GUI
publication per message. Disk synchronization and repeated snapshot construction
then dominate work that could be shared by a batch.

**How Zimbr implements it.** `Worker.receiveBatch` commits complete SSE frames
from one network delivery in one transaction. Record changes, unread markers,
and the durable event cursor advance together. Invalid input or a failed write
rolls back the batch; notification side effects are released only after commit.

The worker separately coalesces dirty view publication on a roughly 16 ms
interval. Upload progress requests a publication at most every 100 ms rather
than per chunk; other reasons to publish can also include the current progress.
Network readiness and a command pipe wake the worker, so publication timing does
not require a fixed sleep after every request. These intervals govern worker
publication, not the display's frame cadence.

**Why it works.** Batching amortizes transaction and durability costs. Publication
coalescing prevents an event burst from producing many snapshots that the GUI
will never display. The two boundaries remain independent: durable ingestion can
proceed while a later publication represents several committed changes.

**When it works and what remains.** This fits event streams, sync clients, and
progress-heavy jobs. A batch must preserve ordering and recover atomically.
Coalescing adds latency, so choose its interval against the product's response
budget. A busy worker may exceed the nominal interval; 16 ms is not a hard
publication guarantee. Important effects such as send acknowledgement must keep
their durable semantics even if intermediate visual progress is skipped.

Zimbr retains WAL and full durability settings. The improvement comes from doing
fewer repeated commits and publications, not weakening the commit contract.

**Evidence.** `client_tests.zig` covers event/cursor atomicity, replay deduplication,
and rollback after a cursor-write failure.
[tests/performance.py](tests/performance.py) includes live bursts and send paths;
do not infer end-to-end latency from isolated transaction speed.

## 16. Preserve valid caches across reconnects and routine refreshes

**Problem.** A reconnect, expired replay cursor, or unchanged source refresh can
be misinterpreted as content replacement. Clearing valid history/media causes
avoidable downloads, parsing, texture creation, and visible disappearance.

**How Zimbr implements it.** Cache continuity is tied to source identity and
content versions. Same-epoch bootstrap merges records while retaining cached
history and contacts. A genuinely new epoch invalidates replicated content.
Media keys include relay endpoint, CA digest, epoch, asset ID, version, and
variant, so ordinary reconnection does not need to invent new identities.

Changing a media context cancels obsolete requests while retaining usable ready
textures. Permission loss still removes private avatar content. Relay asset
work preserves valid cached outputs when source identity/version remains valid
(`9a9c7b0`), and source-anchor checks distinguish ordinary row deletion from
actual source discontinuity (`12d4beb`).

**Why it works.** A cache can only amortize work if its lifetime spans routine
use. Avoiding false invalidation improves both warm latency and continuity of
what the user sees. Explicit epochs make the expensive full reset correspond to
a real domain boundary.

**When it works and what remains.** This requires a trustworthy content/version
contract. A connection becoming available does not prove data is unchanged;
reconciliation still runs. Trust changes, permission changes, corrupt files,
actual source replacement, and budget eviction may legitimately discard content.
Do not preserve caches by omitting those dependencies from the key.

**Evidence.** [docs/cache-continuity.md](docs/cache-continuity.md) records reset
rules and [tests/client_cache.py](tests/client_cache.py) checks expired replay,
multiple clients, retained contact/media state, and source discontinuity.

## 17. Amortize disk-cache maintenance using sole-writer accounting

**Problem.** Scanning, sorting, and pruning a cache directory after every download
turns a small image into filesystem work proportional to the entire cache.

**How Zimbr implements it.**
[Media/DiskCache.zig](src/client/Media/DiskCache.zig) scans at startup, then tracks
a conservative upper bound on bytes and entries as downloads complete. Most
installations update counters only. A scan/prune occurs when accounting crosses
a high-water threshold or accounting is unavailable.

The nominal disk budget is 512 MiB. The worker leaves 16 MiB for two bounded
download lanes, starts maintenance above the resulting 496 MiB threshold, and
trims toward 448 MiB. Entry accounting similarly allows 8,192 entries and trims
toward 7,680. The gap provides headroom so the next download does not immediately
trigger another full scan.

Replacements and removals can overcount until the next scan. They cannot create
fictional free space. Startup can remove orphan temporary files because downloads
have not begun; later maintenance preserves active temporary ownership.

**Why it works.** If a directory scan costs `S` and headroom admits `B` downloads,
the amortized scan cost approaches `S / B` per download rather than `S`, plus
constant counter updates. This removes repeated metadata I/O without needing a
durable index of every file operation.

**When it works and what remains.** The cache must have a single coordinated
writer and bounded in-flight writes. Another process writing unnoticed files
would invalidate the accounting proof. Maintenance can still have a noticeable
tail when it occurs; it runs on the media worker, not during drawing. Small
headroom increases scan frequency; large headroom reduces the useful cache.

**Evidence.** `DiskCache.zig` tests cover active/orphan temporaries, replacement
overcounting, restart, and byte/entry limits. `hotpath-bench` includes maintenance
with different initial directory sizes; its sparse-file fixture excludes actual
payload writing, decoding, and fsync latency.

## 18. Reuse bounded scratch storage and encode IDs only at boundaries

**Problem.** Repeated short-lived heap/page allocations add allocator overhead
and memory traffic. Retaining every peak allocation forever solves churn by
creating a different problem: one exceptional frame can set permanent memory
usage. String-shaped IDs also waste space when their underlying size is fixed.

**How Zimbr implements it.** `App.draw` resets frame scratch with a 1 MiB retention
limit. A separate control arena retains at most 256 KiB across rebuilds because
hit regions must remain usable between drawing and subsequent input processing.
The history arena lives across unchanged frames and retains capacity when rows
are rebuilt. Relay ingestion reuses decoder scratch with a 256 KiB retention
limit per row.

[Media/Key.zig](src/client/Media/Key.zig) stores a media key as 32 bytes and encodes
its existing 64-character hexadecimal filename only at filesystem boundaries.
The high nibble retains the variant discriminator. Request IDs/versions and URL
buffers use bounds derived from the protocol; the queue does not need a heap
string for every fixed-size field.

**Why it works.** Arena reset reuses allocations for recurring temporary work and
reduces per-object cleanup. A retention cap prevents an unusually large frame
from pinning all of its scratch capacity. Compact binary identities reduce
copying, hashing, and queue footprint without changing persisted cache names.

**When it works and what remains.** Separate allocations by lifetime first. Frame
scratch cannot own text referenced by the next input event, an asynchronous job,
or a retained SDL/Clay resource. Retention limits apply to storage kept after
reset, not peak allocation during the operation. The history arena intentionally
has a different policy; this is not a claim of a 1 MiB total application budget.
Fixed arrays are appropriate only where validated bounds exist, not for arbitrary
user content.

**Evidence.** `Media/Key.zig` checks unchanged filenames and variant isolation;
media tests check queue ownership and deduplication. Use allocation/peak-memory
profiles as well as wall time when changing these policies.

## 19. Cache prepared statements without weakening ownership or durability

**Problem.** Repeatedly compiling the same small SQL query wastes CPU in history,
ingestion, and snapshot construction. Reusing a live cursor or retaining bindings
into a freed arena, however, can corrupt results or memory.

**How Zimbr implements it.** [Sqlite.zig](src/relay/Sqlite.zig), shared by both
endpoints, owns 256 direct-mapped idle-statement slots per connection. It caches
short recurring DML queries, compares full SQL on a candidate hit, and leaves
DDL/PRAGMA execution outside that policy.

Checkout removes a statement from its slot, so nested identical queries receive
independent cursors and bindings. Closing a reusable statement resets it and
clears borrowed bindings before returning it. Failed resets finalize the
statement. A slot collision discards the old idle statement rather than changing
a checked-out one.

Client connections with explicit thread confinement use `SQLITE_OPEN_NOMUTEX`.
Other connections retain the serialized option. Separate connections can still
read/write the same WAL database; confinement concerns the connection object,
not exclusive access to the whole database.

**Why it works.** Warm operations avoid SQL compilation and its allocations.
Confinement can remove redundant connection mutex overhead where the application
already guarantees single-thread use. Neither removes query execution, lock
contention between connections, disk I/O, or durable commit cost.

**When it works and what remains.** This fits a bounded set of recurring query
templates with bind parameters. It is less useful for unique generated SQL.
Statements must close before connection teardown and before borrowed inputs die.
Do not use `NOMUTEX` merely because there is one user: multiple application
threads can still share a connection incorrectly.

**Evidence.** `Sqlite.zig` tests nested queries, cleared bindings, and unfinished
cursors. `confined client connections preserve WAL readers while another thread writes`
in [client_tests.zig](src/client_tests.zig) checks the confinement boundary.
`hotpath-bench` separates SQL overhead from other hot paths.

## 20. Avoid JSON representation round trips; vectorize only the remaining scan

**Problem.** Parsing a generic JSON tree, serializing it, then parsing a typed
record duplicates work and allocations. It can also change unknown numeric
fields while forwarding a record the application did not intend to modify.

**How Zimbr implements it.** `Decoded(T)` in
[json_input.zig](src/protocol/json_input.zig) parses the typed record once while
retaining its exact input span. Cache writers persist those original bytes while
using typed fields for validation and indexing. Borrowed versus owned parsing
is explicit; SQLite must copy borrowed bytes before the input buffer disappears.

[Json.zig](src/protocol/Json.zig) represents an opaque validated JSON value where
only the enclosing envelope needs interpretation. It can serialize the original
value without building a generic tree or interpreting its numbers. Literal
formatting CR/LF bytes are removed when embedding in an SSE data line; escaped
newlines inside strings remain unchanged. Changed domain records still require
normal serialization.

Before parsing, the allocation-free bounds scanner limits bytes, nesting, and
tokens. Inside ordinary quoted text it uses `@Vector(16, u8)` to locate quotes
or backslashes and skip 16-byte blocks. Escape/delimiter handling remains scalar,
UTF-8 validation is separate, and the actual parser still validates JSON grammar.

**Why it works.** Removing representation round trips avoids more work than
accelerating each conversion. It also preserves unknown fields and exact number
tokens. SIMD then reduces loop overhead in a remaining pass whose common case
is long runs of ordinary message text.

**When it works and what remains.** Raw preservation fits validated pass-through
records. It does not authorize embedding arbitrary bytes, skip semantic checks,
or permit borrowing beyond input lifetime. Modified records need a new encoding.
SIMD helps sufficiently long ordinary strings; short or escape-heavy input may
remain dominated by scalar processing. The bounds scan is not a replacement JSON
parser, and the optimization does not eliminate every pass over input bytes.

**Evidence.** `Json.zig` and `json_input.zig` test malformed input, exact integers,
unknown fields, borrowed/owned lifetimes, and vector/scalar agreement. The hot-path
benchmark measures JSON checking and event construction/ingestion independently.
Commit `3cfca37` contains the bounded-storage/serialization work.

## Measuring whether a transfer actually helps

Use the existing [development guide](docs/development.md#rendering-benchmarks)
for build prerequisites. The commands below use the pinned Zig toolchain and
generic output paths. This documentation change did not execute benchmarks or
establish new timing results.

### Choose a workload that can expose the proposed improvement

| Workload/tool | What it exposes | What it does not establish |
|---|---|---|
| `cached`, shared avatar initials | Warm draw cost and simultaneous raster appearances | Cold text or typical behavior for every sidebar |
| `scroll` | Visible-set changes and raster-range reuse | First-open storage/network latency |
| `cold_text` | Rebuilding application layouts, rasterization, uploads | Fully cold font/process caches |
| `image_upload` | A 512 × 512 image's upload, draw, and retirement over the chat | JPEG decoding or network speed |
| `rich_anchor` | Repeated rich-block measurement/anchor work | Every rich-content update |
| `caret` | Collapsed-selection raster reuse | Nonempty selection performance |
| `reflow` | Budgeted layout work and convergence | Compositor/window-resize cost |
| `resize_width` / `resize_height` | Actual window/backend resizing and axis-specific layout effects | A real compositor border-drag sequence |
| `client-bench` | Cold, unchanged, edit, append snapshot costs | Durable disk, transport, or GPU cost |
| `hotpath-bench` | SQL, JSON, raster, queue, serialization, cache-maintenance CPU paths | Whole-application latency |
| `tests/performance.py` | Synthetic relay/client ingestion, bursts, and send behavior | Physical display latency or native messaging-service performance |

For example, save a baseline executable before rebuilding, then run each version
serially on the same desktop with matching scale, renderer, and optimization:

```sh
zig build render-bench -Doptimize=ReleaseSafe
python3 tests/rendering.py --output artifacts/performance-baseline \
    --drivers vulkan --workload all --pacing unpaced --runs 5 --frames 1200

# Rebuild the candidate, then use a fresh output directory.
python3 tests/rendering.py --output artifacts/performance-candidate \
    --drivers vulkan --workload all --pacing unpaced --runs 5 --frames 1200

zig build client-bench hotpath-bench -Doptimize=ReleaseSafe
zig-out/bin/client-bench 25000 1024
zig-out/bin/hotpath-bench
```

The renderer fixture has 32 conversations and 1,000 synthetic messages, uses the
production draw path, settles initial layout, and warms each workload for 120
frames. It needs no account or private message data. Alternate baseline/candidate
run order to reduce thermal/load bias. Run profiling separately from timings.
Do not compare a Debug candidate with a ReleaseFast baseline; packaged client
behavior is better represented by ReleaseSafe.

`frame_ms` is CPU-side draw plus presentation wall time. GPU work can remain
asynchronous afterward. `interval_ms` includes time between frame starts, and
process `cpu_ms` measures CPU consumption rather than sleeping. Report upper
tails and the workload's total work as well as medians. An apparent improvement
caused by deferring unfinished work is not equivalent to completing it faster.
For reflow, include completed cycles and frames/work per cycle.

The renderer runner records executable/source identity, SDL build revision, raw
frame samples, dimensions, and system/driver information. Zimbr's SDL revision
includes the upstream package identity plus its patch and build inputs. Preserve
that provenance: unmodified SDL, Zimbr's direct Vulkan backend, and SDL's GPU
renderer are materially different comparison targets.

Correctness checks protect the optimization's invariant: unchanged pixels when
storage is reused, stable anchors after geometry changes, valid old snapshots
after publication, and atomic state after failed persistence. For GUI scenario
work, resolve the `zrct` dependency from [build.zig.zon](build.zig.zon), read its
`SKILL.md`, and use the commands in the
[development guide](docs/development.md#gui-scenarios-with-zrct). Run instrumentation
and recording separately from performance measurements.

## Adoption order and remaining limits

Start by identifying the cost your workload actually pays. Zimbr's layering
suggests this order when several problems are present:

1. Remove unnecessary whole-model work and false invalidation.
2. Restrict drawing, enrichment, and measurement to useful content; budget cold work.
3. Make text/media lifetimes explicit and cache their distinct representations.
4. Remove avoidable conversions and allocation churn.
5. Profile the chosen SDL backend before carrying local driver-facing patches.
6. Confirm the result in a complete interaction after microbenchmarks improve.

Several limits are intentional. Loaded history still has linear preparation and
repositioning paths. A single synchronous text measurement or texture upload can
exceed a cooperative frame budget. Pango/font objects, driver allocations,
retired textures, in-flight uploads, and process scratch are outside any one
live-cache counter. Reconnect reuse still depends on correct trust, epoch, and
version handling.

The transferable design is to make expensive work conditional on a meaningful
change, give it an explicit owner and lifetime, and bound the work that must
remain. Keep frame scheduling from [FRAME_PACING.md](FRAME_PACING.md) alongside
these techniques: reducing draw cost alone does not establish regular frame
cadence or responsive background publication.
