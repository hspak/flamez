#!/usr/bin/env python3
"""Interleave immutable -Drender-benchmark=true binaries on deterministic sessions."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fixture(repository, slices, packed):
    session = json.loads((repository / "src/testdata/session-v1-minimal.json").read_text())
    template = session["processes"][0]
    duration = 16_000_000_000
    session.update(elapsed_ns=duration, host_cpu_count=32, processes=[])
    session["metadata"]["argv"] = [["ninja", "-j32"]]

    def process(parent, start, end, name, count):
        item = copy.deepcopy(template)
        index = len(session["processes"])
        item.update(pid=1000 + index, parent=parent, start_ns=start, end_ns=end)
        item["execs"][0].update(start_ns=start, end_ns=end, name=name)
        step = (end - start) // max(count, 1)
        item["slices"] = [[start + i * step, start + (i + 1) * step,
                           step // (2 if i % 2 else 1)] for i in range(count)]
        item["cpu_time_ns"] = sum(row[2] for row in item["slices"])
        session["processes"].append(item)
        return index

    process(None, 0, duration, "ninja", 0)
    for _ in range(32):
        parent = process(0, 0, duration, "vulkan-shaders", 0)
        for child in range(16):
            start = child * duration // 16 if packed else 0
            end = (child + 1) * duration // 16 if packed else duration
            process(parent, start, end, "glslc", slices)
    return session


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", action="append", required=True, help="label=/absolute/path")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeat", type=int, default=5)
    parser.add_argument("--case", action="append", choices=("typical", "dense", "packed"))
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    repository = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True, exist_ok=False)
    executables = dict(entry.split("=", 1) for entry in args.executable)
    hashes = {label: fingerprint(Path(path)) for label, path in executables.items()}
    fixtures = {}
    for name, slices, packed in (("typical", 128, False), ("dense", 512, False), ("packed", 0, True)):
        if args.case and name not in args.case:
            continue
        path = args.output / f"{name}.json"
        path.write_text(json.dumps(fixture(repository, slices, packed), separators=(",", ":")))
        fixtures[name] = path
    result = dict(executables=executables, hashes=hashes,
                  host=platform.uname()._asdict(), affinity=sorted(os.sched_getaffinity(0)),
                  fixtures={name: fingerprint(path) for name, path in fixtures.items()},
                  policy="120 warmup, 600 measured frames; vsync/pacing off; OS cache shared; serial alternating order",
                  runs=[])
    pattern = re.compile(r"info\(render_benchmark\): (\w+) frames=(\d+) mean_ns=(\d+) p50_ns=(\d+) p95_ns=(\d+)")
    env = dict(os.environ, SDL_RENDER_DRIVER="vulkan")
    env.pop("FLAMEZ_SCREENSHOT", None)
    for iteration in range(args.repeat):
        labels = list(executables)
        if iteration % 2:
            labels.reverse()
        for case, path in fixtures.items():
            for label in labels:
                executable = Path(executables[label])
                if fingerprint(executable) != hashes[label]:
                    raise RuntimeError(f"Executable changed: {executable}")
                run = subprocess.run([str(executable), "--import", str(path.resolve())],
                                     env=env, capture_output=True, text=True, timeout=60)
                log = args.output / f"{iteration}-{case}-{label}.log"
                log.write_text(run.stdout + run.stderr)
                if run.returncode or "renderer: vulkan" not in run.stderr:
                    raise RuntimeError(f"Benchmark failed: {log}")
                if fingerprint(executable) != hashes[label]:
                    raise RuntimeError(f"Executable changed during measurement: {executable}")
                metrics = {name: dict(frames=int(frames), mean_ns=int(mean), p50_ns=int(p50), p95_ns=int(p95))
                           for name, frames, mean, p50, p95 in pattern.findall(run.stderr)}
                if set(metrics) != {"wall", "cpu", "prepare", "present"}:
                    raise RuntimeError(f"Missing frame measurements: {log}")
                result["runs"].append(dict(iteration=iteration, case=case, label=label, metrics=metrics))
                (args.output / "result.json").write_text(json.dumps(result, indent=2))
                print(f"{iteration} {case} {label}: " + " ".join(
                    f"{name}={metric['mean_ns']/1000:.1f}us" for name, metric in metrics.items()), flush=True)
    for case in fixtures:
        for label in executables:
            rows = [row["metrics"] for row in result["runs"] if row["case"] == case and row["label"] == label]
            print(f"median {case} {label}: " + " ".join(
                f"{name}={statistics.median(row[name]['mean_ns'] for row in rows)/1000:.1f}us"
                for name in ("wall", "cpu", "prepare", "present")))


if __name__ == "__main__":
    main()
