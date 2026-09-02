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

## Building

```sh
zig build
zig build -Dfps-counter=true  # enable builtin FPS counter
zig build -Dmsaa=true         # enable MSAAx4
```
