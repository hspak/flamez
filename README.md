# Flamez

Flamez is a live process-lifetime and CPU-activity flamegraph for builds and
other commands. It spawns a command in its own process group, follows
descendants, and keeps every process anchored to the wall-clock interval in
which it ran. Red slices show where each process's threads consumed CPU.

## Feaures
- Live sub-process following
- Exec process following, tracks all args
- Process thread CPU usage tracking
- Import/export trace data

## Usage
```sh
# General usage
flamez <your target program> [target program args]

# Run headless
flamez -o trace-data-output.json <your target program> [target program args]

# Load trace export
flamez -i trace-data-output.json
```

## Releasing

Run `./release.sh <version> --macos-host <host>` from a clean, pushed source
checkout on Linux with Zig 0.16.0. The AUR and Homebrew tap checkouts default
to `../../aur/flamez` and `../homebrew-tap`; override them with `FLAMEZ_AUR_DIR`
and `FLAMEZ_TAP_DIR`. Add `--check` to build and validate without publishing.

After an interrupted release, rerun the command. Matching tags and draft
releases are reused, including the uploaded macOS archive, so a retry keeps
the same Homebrew checksum. A Mac host is optional when the draft already
contains that archive. Unchanged package recipes do not create another commit;
a release commit left by a failed push is checked and pushed again.

If release tooling has since been committed and pushed, use
`./release.sh <version> --resume` to release the existing tag's source instead
of HEAD. Supply a Mac host or `--macos-archive <path>` if the draft has no
archive yet. The script rejects conflicting tags, published releases, dirty
checkouts, and unrelated unpublished commits. Failed runs retain their
temporary directory for inspection; the path is printed on failure.

Test release tooling with `python3 -B -m unittest discover -s tests -p 'test_*.py'`.
