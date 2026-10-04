"""Exercise the runner's macOS defaults without a GPU or benchmark build."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "benchmark_render", Path(__file__).resolve().parents[1] / "tools/benchmark_render.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class NativeRenderer(unittest.TestCase):
    def test_macos_runner_uses_metal_without_linux_affinity_api(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "benchmark"
            executable.write_text("""#!/usr/bin/env python3
import os
import sys
assert os.environ['SDL_RENDER_DRIVER'] == 'metal'
print('info(graphics): SDL 3.4.16, renderer: metal', file=sys.stderr)
for metric in ('wall', 'cpu', 'prepare', 'present'):
    print(f'info(render_benchmark): {metric} frames=600 mean_ns=20 p50_ns=10 p95_ns=30', file=sys.stderr)
""")
            executable.chmod(0o755)
            arguments = ["benchmark_render.py", "--executable", f"native={executable}",
                         "--output", str(root / "results"), "--repeat", "1", "--case", "typical"]
            with patch("sys.argv", arguments), patch.object(benchmark.platform, "system", return_value="Darwin"):
                # Darwin has no sched_getaffinity, including when this test runs on Linux.
                affinity = getattr(os, "sched_getaffinity", None)
                try:
                    if affinity is not None:
                        del os.sched_getaffinity
                    benchmark.main()
                finally:
                    if affinity is not None:
                        os.sched_getaffinity = affinity
            result = benchmark.json.loads((root / "results/result.json").read_text())
            self.assertEqual(result["renderer"], "metal")
            self.assertIsNone(result["affinity"])
            self.assertEqual(result["runs"][0]["metrics"]["wall"]["frames"], 600)


if __name__ == "__main__":
    unittest.main()
