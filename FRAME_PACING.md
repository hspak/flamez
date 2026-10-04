# Frame pacing: responsive interaction and quiet idle

Zimbr renders at the display's cadence while the user interacts, skips unchanged
frames while idle, and wakes for the next visible change. VSync stays enabled,
but the application also enforces a frame-start deadline because presentation
does not always block long enough to pace rendering during window resizing.

This document records the implementation and the 2026-10-02 investigation. It is
a reference for other event-driven desktop applications, including immediate-mode
GUIs. The reusable parts are the scheduling decisions, event ownership, deadline
handling, and measurement method. The particular timeouts and SDL calls are
Zimbr's choices, not universal requirements.

## What caused the reported behavior

The original main loop explicitly selected slower redraw intervals after a
500 ms interaction burst:

| Condition after the burst | Redraw interval | Apparent FPS |
|---|---:|---:|
| Synchronization active | 33 ms | About 30 |
| Otherwise idle | 500 ms | 2 |

Those numbers explained the reported step down to 30 and then 2 FPS. They were
scheduling policy, rather than evidence that drawing suddenly became expensive.
The counter included time spent intentionally waiting between frames.

The idle redesign followed Flamez's approach: keep a short interaction burst,
then skip drawing and presentation when nothing needs to change. Continue
processing events independently of presentation. Flamez uses a 120 ms burst,
four initial frames, and a 32 ms idle poll; Zimbr retains its 25 ms service poll
and adds deadlines for its message, image, and editor behavior. The sibling
checkout's reference is `src/main.zig`, particularly `InteractionBurst` and the
main loop.

The follow-up investigation found two additional gaps:

1. Relying on VSync alone removed the application's frame-start limit. During
   resize, swapchain recreation allowed presentation to return early and the
   application submitted frames in fast, irregular bursts.
2. A recent-input timeout did not cover a key held between events. A held key
   could outlast the burst before another repeat event arrived. Tracking only
   the left mouse button also missed other held buttons.

The final implementation combines event-driven idle with display-rate pacing
and explicit held-input tracking. These solve different parts of the problem.

## Where the implementation lives

| Concern | Source and entry points |
|---|---|
| Main scheduling policy | [src/client_main.zig](src/client_main.zig): `runSession` |
| Visible deadlines and FPS display | [src/client_main.zig](src/client_main.zig): `App.draw`, `redrawAt`, `redrawAfterGrace` |
| Display metrics, frame waits, held input | [src/client/desktop.zig](src/client/desktop.zig): `Metrics`, `refreshMetrics`, `waitNs`, `nextEvent`, `inputHeld` |
| Event-preserving waits and worker wakeups | [src/client/desktop.c](src/client/desktop.c): `zc_desktop_wait`, `zc_desktop_wake`, `zc_desktop_poll` |
| Image retry ownership | [src/client/ImageCache.zig](src/client/ImageCache.zig): `Entry`, `accept`, `wantsRequest` |
| Synthetic production rendering | [src/client_main.zig](src/client_main.zig): `RenderFixture` |
| Per-frame benchmark samples | [src/render_bench.zig](src/render_bench.zig) |
| Benchmark validation and summaries | [tests/rendering.py](tests/rendering.py) |
| Interaction and idle regressions | [tests/zrct/scenarios.py](tests/zrct/scenarios.py), [tests/zrct/content_scenarios.py](tests/zrct/content_scenarios.py) |

The [development guide](docs/development.md#frame-scheduling) gives the shorter
operational description and build prerequisites. The pacing implementation was
included in commit `12d4beb`; the old timer policy is visible in `a9a7d2f`.

## Separate the need to draw from permission to draw

The loop answers two questions on every iteration:

- Does the application need another frame?
- Has the next permitted frame-start time arrived?

Input handling and background updates happen before either decision. A frame
deadline delays rendering; it does not prevent processing newly arrived events.
When several events arrive before the deadline, the next frame reflects the
updated application state without rendering once for every event.

The scheduler uses three independent times:

| Field | Purpose | Clock and unit |
|---|---|---|
| `active_until` | Bridge short gaps between input events | SDL monotonic ticks, nanoseconds |
| `next_draw` | Earliest next frame start | SDL monotonic ticks, nanoseconds |
| `App.redraw_at` | Earliest known visible timed change | Existing application timestamp clock, milliseconds |

`active_until` and `next_draw` are duration-based scheduling decisions.
`redraw_at` also integrates deadlines derived from message and retry timestamps.
Keep their units and clock domains explicit; never compare an application
timestamp directly with SDL ticks. A new project can use monotonic deadlines
for local timers and convert external timestamps at a defined boundary. Zimbr's
existing timestamp-based timers retain their existing clock behavior.

The production loop is equivalent to this outline; setup, shutdown, diagnostics,
and screenshot handling are omitted:

```text
while the window is open:
    poll automation and notification services
    update the application, including ordered input and worker publications
    snapshot display metrics, revisions, pointer position, and worker generation
    now = monotonic_nanoseconds()

    if input, window metrics, editor revision, or drop hover changed:
        active_until = now + 120 ms

    active = startup_frames_remaining
          or fixed_frame_capture
          or layout_pending
          or now < active_until
          or any_key_or_mouse_button_held
          or visible_sync_animation

    needs_draw = active
              or automation_requested_frame
              or background_ready
              or worker_generation_changed
              or application_milliseconds() >= redraw_at

    if needs_draw and now >= next_draw:
        update the FPS sample only if the previous interval was not idle
        mark this frame active or idle for diagnostics
        draw, rebuilding visible deadlines for the new scene
        present
        next_draw = now + display_interval
        remember the state represented by this frame
        clear background_ready
    else:
        if needs_draw:
            ready = wait_ns(max(0, next_draw - now))
        else:
            mark the next FPS interval as following idle
            ready = wait_ms(min(25, max(0, redraw_at - application_milliseconds())))
        background_ready = background_ready or ready
```

The `now` used to set `next_draw` is captured before drawing. Remembered revisions
and geometry describe the last drawn frame, not merely the last event poll.
Worker readiness remains latched until a frame consumes it. Those details keep a
short wait or an extra loop iteration from losing a pending redraw.

The first four frames allow initial window configuration and layout to settle.
Deferred layout also keeps the loop active until its work finishes. Rendering a
single startup frame and immediately sleeping can strand initialization that
needs a later frame.

## Keep interactions active between events

Every observed input, window-metric change, editor revision, or drop-hover change
extends the interaction burst by 120 ms. This bridges event gaps during scrolling,
pointer movement, key repeat, and resize. It also gives short actions a brief run
of regularly paced frames before idle.

A burst alone cannot describe a held input. `desktop.zig` maintains:

- A bitset indexed by SDL scancode for held keys.
- A mouse-button mask covering all valid SDL button numbers.
- Modifier state updated alongside the ordered key events.

Key down sets a bit and key up clears it. Repeated key-down events set the same
bit again, so repeats cannot inflate a counter and leave a key permanently held.
Unknown or out-of-range scancodes are ignored. Mouse down and up similarly update
the corresponding mask bit. Opening the window and losing focus clear held
input, preventing a release delivered elsewhere from leaving the client active
forever.

`inputHeld()` reports whether either collection is nonempty. The main loop treats
that as active regardless of the burst deadline. A modifier key that emits no
repeat events therefore keeps rendering active until release.

Derive this bookkeeping from the same ordered events the application consumes.
That preserves short down/up sequences and makes injected SDL events exercise
the normal input path. Polling only final physical device state can miss a short
click, and may not reflect injected test events. The event consumer remains
responsible for the action; held-input bookkeeping only affects scheduling.

Visible synchronization animation is another active reason. It runs at the same
cadence as interaction, instead of selecting a separate 30 FPS limit. In Zimbr,
settings and details views suppress that main-view animation reason.

## Pace active frames even when VSync is enabled

Interactive sessions request `SDL_SetRenderVSync(renderer, 1)`. Zimbr's pinned
SDL Vulkan renderer selects FIFO presentation for that setting. However, a
successful VSync request does not promise that every `SDL_RenderPresent` call
blocks for one complete refresh interval. The resize measurements demonstrated
early returns during repeated swapchain recreation.

`refreshMetrics()` obtains the window's current display, reads its current mode,
and converts a finite refresh rate between 1 and 1,000 Hz into nanoseconds:

```text
display_interval = 1,000,000,000 / refresh_rate_hz
```

If that information is unavailable or invalid, the fallback is 120 Hz. Metrics
are refreshed after pumping events, allowing the interval to follow a display
change. If enabling VSync fails, the client logs that it is using the display
frame timer and retains the same scheduling limit. Fixed-frame capture uses its
explicit 120 Hz deadline rather than the interactive display policy.

After drawing and presenting, the client sets:

```text
next_draw = frame_start + display_interval
```

This accounts for drawing and presentation time already spent. At 120 Hz, if work
and presentation take 5 ms, approximately 3.33 ms remains. If they take 9 ms,
the deadline has passed and the loop adds no frame-timer wait. Setting the
deadline from the end of presentation would add a full extra interval and could
substantially reduce throughput when VSync already blocks.

Each deadline is based on the actual frame start. The implementation does not
try to catch up missed frames by issuing a burst, or maintain an accumulated
schedule through a long idle period. It is a minimum interval between frame
starts, not a phase lock to the compositor's presentation clock. Sleep overhead
can make the measured cadence slightly slower than the nominal display rate;
that is visible in the results below.

### Preserve the fraction of a millisecond

At 120 Hz, one interval is approximately 8.333 ms. Rounding each remaining wait
up to an integer millisecond introduces avoidable delay. The shared helper uses
an event wait for whole milliseconds and `SDL_DelayNS` for a remaining fraction:

```zig
pub fn waitNs(timeout_ns: u64) bool {
    if (timeout_ns >= std.time.ns_per_ms)
        return wait(@intCast(@min(25, timeout_ns / std.time.ns_per_ms)));
    if (timeout_ns > 0) c.SDL_DelayNS(timeout_ns);
    return false;
}
```

This helper performs one wait, then returns to the loop. The loop processes
events and checks the deadline again. For example, a 3.33 ms remainder first
permits an interruptible 3 ms event wait; a later iteration handles the remaining
fraction. Saturating subtraction prevents a passed deadline from becoming a
huge unsigned timeout.

The nanosecond argument avoids deliberate millisecond rounding; it does not
guarantee nanosecond wake accuracy. The short `SDL_DelayNS` path does not return a
worker-ready indication. Any pending events and wake flag remain for subsequent
processing. Normal scheduling overhead and operating-system delays still apply.

## Idle means skipping unchanged draws

An idle iteration continues servicing the application but does not call drawing
or presentation without a reason. The previous frame remains visible. Input,
worker publications, visible timers, or pending layout can request another frame.

The event wait is capped at 25 ms so notification polling, draft persistence,
transfers, and other loop-driven services keep progressing. SDL events and worker
wakeups can interrupt the event wait. This is a maximum requested wait, not a
hard response-time guarantee: application work, OS scheduling, and presentation
can also take time.

Event polling must be independent of rendering. Frameworks that normally pump
events during an end-of-frame call need an explicit pump on the idle path.
Otherwise the application can sleep through the very input intended to wake it.

Zimbr's C bridge coalesces worker notifications with an atomic pending flag and
one registered SDL event. `SDL_WaitEventTimeout(NULL, ...)` leaves input queued
for the application. The wait reports and clears the pending flag; the main loop
latches that result until drawing. `desktop.nextEvent()` drains with
`SDL_PeepEvents`, preserving queue order and avoiding a poll sentinel hiding
later injected events. A worker publishes data and signals readiness; it does
not draw on the GUI thread's behalf.

### Every visible timer needs an owner

Periodic idle redraws used to hide missing timer dependencies. Once unchanged
frames are skipped, a caret, notice, retry, or relative-age label can remain
stale unless something explicitly requests its next update.

At the beginning of `App.draw`, `redraw_at` resets to the maximum timestamp.
Visible components call `redrawAt(when)`, which takes the minimum. The completed
frame therefore carries the earliest known deadline needed by that scene.
Rebuilding the deadline from the scene drops timers for components no longer
visible instead of leaving stale deadlines active indefinitely.

| Visible behavior | Deadline registered during drawing |
|---|---|
| Focused caret | Next edge of its 600 ms visible / 400 ms hidden cycle |
| Transient notice | Notice expiry |
| Outgoing message with uncertain status | End of the 30-second status grace period |
| Image awaiting automatic retry | The visible image entry's `retry_at` |
| Deferred visible message metadata | The next hydration opportunity, using the existing 250 ms coalescing interval |
| Details ages and reconnect countdown | One second later |
| Optional FPS diagnostic | One second later |

The caret only requests blinking frames when it is visible within its clip,
unobscured, and not displaying IME composition. Image retry deadlines only come
from entries used in the current frame. Background work still has its own
service path; a hidden item need not force redraws just to keep that work alive.

The image path exposed a related ownership bug. A relay result meaning
"preparing" previously lost its retry deadline when converted to a generic
pending image. `ImageCache.accept` now represents it as
`unavailable.kind = .preparing`, retaining the reason and the retry deadline.
For a nonzero worker deadline, the cache takes the later of that deadline and
its local retry backoff; zero retains the meaning of no scheduled retry.

`wantsRequest` can request the image again when the retained deadline arrives.
Manual retry remains unavailable while the relay is preparing the image. This
keeps automatic scheduling separate from whether a Retry button is appropriate.
The practical result is that an idle image viewer can recover without a mouse
movement accidentally supplying its next frame.

### Report idle truthfully

The optional FPS counter displays `Idle` for frames drawn outside an active
period. It does not turn a caret blink or diagnostic refresh into a claim of
poor rendering throughput. `was_idle` also prevents the first frame after an
idle wait from incorporating that wait into the next active FPS sample.

The counter itself schedules a one-second refresh when visible. Consequently,
an FPS-enabled idle client deliberately performs occasional diagnostic draws.
Use drawing-idle tests with that distinction in mind. The displayed active FPS
is based on frame-start intervals; it is not a presentation-feedback instrument.

## Resize has both timing and geometry concerns

A consistent frame interval cannot repair unstable geometry. Zimbr separately
uses `SDL_GetWindowDisplayScale` as its authoritative UI scale. At fractional
scales such as 125%, physical window dimensions are rounded to whole pixels.
Dividing those dimensions by logical width or height makes the apparent scale
change as the window moves through adjacent sizes. That can move text and
invalidate caches even though the display scale stayed constant.

Keep logical size, framebuffer size, and display scale as separate metrics.
Use resize events and metric changes to extend the active burst; use the stable
display scale for text and geometry. Width and height also deserve separate
workloads: width changes cause text reflow, while height changes exercise viewport
and bottom-anchor positioning. These geometry and cache concerns are adjacent
to frame scheduling and should be tested independently. The
[GUI development notes](docs/development.md#gui-scenarios-with-zrct) describe
Zimbr's fractional-scale pixel comparisons and reading-anchor checks.

## Measure capacity, cadence, and correctness separately

We extended the existing benchmark to use the production `RenderFixture` with
32 conversations and 1,000 synthetic messages. It opens a real SDL window and
uses the production renderer without a relay or private message data. The
benchmark shares the client's display interval and `waitNs` helper, but has its
own loop; it does not exercise every service in `runSession`.

| Pacing mode | VSync | Display-rate timer | Question it helps answer |
|---|---|---|---|
| `unpaced` | Off | Off | How much drawing and presentation work can this renderer sustain? |
| `vsync` | On | Off | Does this renderer's presentation path pace this workload? |
| `timer` | Off | On | What cadence does the application timer provide? |
| `capped_vsync` | On | On | What cadence does the combined policy provide? |

Each sample includes `interval_ns`, `draw_ns`, `present_ns`, and process
`cpu_ns`, as well as logical window dimensions and layout progress. Draw and
presentation timings cover CPU wall time through `SDL_RenderPresent`. Process
CPU time excludes sleeping but can include work on other process threads.
The frame-start interval includes the intervening pacing and event handling.
GPU work can remain asynchronous after those CPU-side measurements finish.

Use `interval_ms` percentiles to examine cadence. The benchmark's `frame_ms`
instead sums draw and presentation wall time. Its existing
`over_120hz_budget_percent` describes that work interval, not the percentage of
frames the display missed; it also remains a 120 Hz reference on other displays.

The added resize workloads move one dimension by two logical pixels per frame
through a 200-pixel range and back, starting from 1120 × 780. Each sample records
actual window dimensions, and the Python runner checks that the intended axis
changed while the other stayed fixed. This exercises SDL window and swapchain
resizing. It does not reproduce a compositor's interactive border drag.

The other measured workloads were settled redraws (`cached`), deterministic
scrolling (`scroll`), and moving a collapsed caret through 64 positions of an
unchanged draft (`caret`). Existing cold-text, image-upload, reading-anchor, and
reflow workloads remain useful when a timing problem turns out to be expensive
rendering or layout rather than scheduling.

### Repeatable comparison procedure

1. Build once with the pinned toolchain and the optimization being evaluated.
   Keep the executable fixed during all repetitions. Preserve separate binaries
   when comparing source revisions.
2. Run serially on the GPU-backed desktop being evaluated, with the same
   renderer, display, scale, geometry, fixture, and avatar mode. Keep builds,
   other tests, and competing GPU workloads out of the measurement interval.
3. Let initial layout settle, then discard 120 warm-up frames per workload.
   Retain every measured frame, including slow ones.
4. Alternate the order of the two pacing modes across repetitions to reduce
   consistent order bias. Compare matching workloads.
5. Preserve executable hashes, source revision and working-tree information,
   SDL revision, driver/system metadata, raw JSONL, stderr, and summaries.
6. Run screenshots, recordings, correctness assertions, and profiling separately.
   A screen recording adds capture overhead and is not an FPS measurement.

The following reproduces the structure of the final comparison from the
repository root. Each output directory must be new. Build requirements and
optional dependency-prefix settings are in the development guide.

```sh
set -e
zig build render-bench -Doptimize=ReleaseSafe

for repeat in 1 2 3; do
    if [ "$repeat" -eq 2 ]; then
        modes="capped_vsync vsync"
    else
        modes="vsync capped_vsync"
    fi
    for workload in cached resize_height resize_width scroll caret; do
        for mode in $modes; do
            python3 tests/rendering.py \
                --output "artifacts/frame-pacing/$repeat-$workload-$mode" \
                --drivers vulkan --workload "$workload" --pacing "$mode" \
                --runs 1 --frames 360
        done
    done
done
```

The runner alternates backend order within its own repeated runs. The outer loop
above additionally alternates pacing-mode order, since each runner invocation
selects one pacing mode. Do not rebuild between iterations.

### Recorded results

The final 2026-10-02 comparison used Zig 0.16.0, ReleaseSafe, Zimbr's patched SDL
3.4.16 direct Vulkan renderer, a 120 Hz Wayland display at 125% scale, and an AMD
Radeon 8060S with Mesa RADV 26.2.3. The initial 1120 × 780 logical window had a
1400 × 975 framebuffer. There were three runs per workload and mode, each with
120 warm-up frames and 360 measured frames: 30 runs and 10,800 measured frames
in total.

The table pools the 1,080 measured intervals for each workload and mode. All
values are milliseconds between CPU-side frame starts, rounded to three decimals.

| Workload | VSync p50 | VSync p99 | VSync + deadline p50 | VSync + deadline p99 |
|---|---:|---:|---:|---:|
| Settled redraw | 8.327 | 9.555 | 8.388 | 8.412 |
| Height resize | 1.914 | 3.619 | 8.388 | 8.405 |
| Width resize | 5.054 | 6.453 | 8.388 | 8.408 |
| Scroll | 8.340 | 9.473 | 8.388 | 8.413 |
| Caret movement | 8.328 | 9.565 | 8.388 | 8.406 |

The short VSync-only resize intervals show that presentation was not enforcing
the display cadence in those workloads. They do not mean the 120 Hz display
showed hundreds of distinct frames per second. The combined policy produced
regular intervals around 8.39 ms, equivalent to roughly 119 frame starts per
second. Its largest recorded interval across these workloads was 8.466 ms.

These are two modes of one fixed benchmark binary, not separately rebuilt
before/after application binaries. The measured SHA-256 was:

```text
f672b7bf3d5b909b3c4aede81a217b9dd7a79e114dde06d0026aa021f4074072
```

Local evidence is retained under `artifacts/frame-pacing-final/`, including
`comparison.json` and each run's `environment.json`, `01-vulkan.jsonl`,
`01-vulkan.stderr.log`, and `summary.json`. These generated artifacts may be
absent from another checkout; the table and methodology above preserve the
result independently of them. The environment records include the base source
revision and a working-tree diff summary; the binary hash identifies the tested
artifact. Archive the full source patch as well when exact reconstruction of an
uncommitted build is required.

The measurements establish CPU submission regularity on that configuration.
They do not establish physical input-to-display latency, GPU completion times,
compositor presentation intervals, or interactive border-drag smoothness.
The resize trajectory is frame-driven, so the faster mode also traverses it
faster in wall time. A constant-speed drag experiment needs time-driven input
and compositor or presentation evidence. Variable refresh, other displays and
drivers, and larger workloads require their own measurements.

## Preserve behavioral coverage alongside timing evidence

The real application loop is exercised by GUI scenarios independently of the
synthetic renderer benchmark:

| Test | Behavior protected |
|---|---|
| `Messages.test_idle_skips_unchanged_frames_and_wakes_for_input_and_messages` | Drawing becomes quiet; input and relay changes wake it without losing a draft. |
| `Messages.test_held_input_and_resize_keep_rendering_active` | A held modifier remains active for 0.8 seconds; several width/height changes render active frames, preserve the draft, and do not send it; releasing interaction allows idle. |
| `Content.test_idle_viewer_retries_failed_asset_without_input` | After an image failure and a drawing-idle period, recovery occurs through the retry deadline without user input. |

The held-input scenario was run unchanged before and after the scheduling fix.
It failed its active-state assertion before the fix and passed after it. Its
semantic `window` target exposes logical dimensions and active/idle status only
in automation builds. That status tests scheduling policy; it does not by itself
prove a high frame rate, which is why the separate interval benchmark matters.

Native tests additionally cover ordered short clicks, key repeat and release,
held-input clearing on focus loss, fractional wheel input, coalesced worker
wakeups, visible caret and notice deadlines, message-status grace expiry, and
image retry behavior. Deadline tests inspect the real draw path's chosen
deadline instead of relying on long sleeps.

For focused GUI work, resolve zrct from `build.zig.zon` and follow that
dependency's `SKILL.md`. Typical commands are:

```sh
zig build test-zrct -Dautomation=true -Doptimize=ReleaseSafe \
    -Dopenssl-prefix=.tools/openssl-3.5 \
    -- --filter held_input_and_resize_keep_rendering_active

zig build test-zrct-content -Dautomation=true -Doptimize=ReleaseSafe \
    -Dopenssl-prefix=.tools/openssl-3.5 \
    -- --filter idle_viewer_retries_failed_asset_without_input

zig build test-gui-isolated test-zrct -Dautomation=true \
    -Doptimize=ReleaseSafe -Dopenssl-prefix=.tools/openssl-3.5
```

The final pacing validation at the time passed 147 native tests and 16 GUI
scenarios. These are historical counts, not expected totals for future revisions.
Evidence directories were:

| Run | Artifact directory |
|---|---|
| Held-input failure before the fix | `artifacts/20261002-100824-5a3c90/` |
| Same scenario passing after the fix | `artifacts/20261002-101013-3d5aa0/` |
| Sixteen GUI scenarios passing | `artifacts/20261002-101153-415289/` |
| Native suite reporting 147 passes | `artifacts/20261002-101231-b111d3/` |

Default isolated GUI tests use software OpenGL. They provide functional evidence
for the real loop, not the GPU timing numbers in this document. Test recordings
can help inspect a visual failure but belong outside performance measurements.

## Applying this design in another project

Start with explicit invariants, then choose platform APIs and timeouts:

1. Event processing and worker publication consumption continue without drawing.
2. A pending visible change survives every wait until a frame represents it.
3. Continuous interaction includes held input and short gaps between events.
4. Idle scenes have no recurring draw requirement unless a visible timer or
   diagnostic explicitly requests one.
5. Every visible time-dependent feature owns its next redraw deadline.
6. Drawing and presentation time count toward the frame interval; already slow
   frames incur no additional frame-timer delay.
7. Display cadence, UI scale, and framebuffer dimensions are distinct inputs.
8. Performance claims identify whether they describe CPU work, frame starts,
   GPU completion, presentation, or input latency.

Audit timed behavior before removing periodic redraws. Add a held-input and
focus-loss regression before tuning the interaction burst. Measure width resize,
height resize, scrolling, editing, idle-to-active transitions, and background
updates separately. Keep correctness failures and raw timing samples, then
repeat the comparison with a fixed executable on the target renderer.

Treat the 120 ms burst, 25 ms poll ceiling, four startup frames, and 120 Hz
fallback as documented policy choices. Carry over the ownership and scheduling
rules first, and choose those constants from the new application's event model,
background-service needs, and measurements.
