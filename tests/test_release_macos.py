"""Mac setup installs missing dependencies and validates downloaded toolchains."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "release_macos", Path(__file__).resolve().parents[1] / "tools/release_macos.py")
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


class MacPrerequisites(unittest.TestCase):
    def test_installs_missing_formulas_and_upgrades_unsupported_sdl(self):
        def command(args, **kwargs):
            if args[1:3] == ["list", "--versions"]:
                installed = args[-1] in ("sdl3", "freetype")
                return subprocess.CompletedProcess(args, 0 if installed else 1,
                                                   stdout="installed" if installed else "")
            return subprocess.CompletedProcess(args, 1)

        with patch.object(remote.platform, "system", return_value="Darwin"), \
                patch.object(remote.platform, "machine", return_value="arm64"), \
                patch.object(remote.Path, "is_file", return_value=True), \
                patch.object(remote.Path, "is_dir", return_value=True), \
                patch.object(remote, "output", side_effect=["/SDK", "/opt/homebrew"]), \
                patch.object(remote.subprocess, "run", side_effect=command), \
                patch.object(remote.shutil, "which", return_value="/usr/bin/tool"), \
                patch.object(remote, "run") as run, patch.dict(os.environ):
            remote.prepare_dependencies()
        commands = [tuple(map(str, call.args)) for call in run.call_args_list]
        self.assertIn(("/opt/homebrew/bin/brew", "install", "libpng", "pkgconf"), commands)
        self.assertIn(("/opt/homebrew/bin/brew", "upgrade", "sdl3"), commands)
        self.assertLess(commands.index(("/opt/homebrew/bin/brew", "upgrade", "sdl3")),
                        commands.index(("pkg-config", "--atleast-version=3.4.0", "sdl3")))

    def test_rejects_an_intel_builder_before_installing_anything(self):
        with patch.object(remote.platform, "system", return_value="Darwin"), \
                patch.object(remote.platform, "machine", return_value="x86_64"), \
                patch.object(remote, "run") as run:
            with self.assertRaisesRegex(ValueError, "Apple-silicon"):
                remote.prepare_dependencies()
        run.assert_not_called()

    def test_missing_sdk_reports_one_time_setup(self):
        with patch.object(remote.platform, "system", return_value="Darwin"), \
                patch.object(remote.platform, "machine", return_value="arm64"), \
                patch.object(remote, "output", side_effect=subprocess.CalledProcessError(1, "xcrun")), \
                patch.object(remote, "run") as run:
            with self.assertRaisesRegex(ValueError, "xcode-select"):
                remote.prepare_dependencies()
        run.assert_not_called()

    def test_download_is_verified_before_installation_and_reused(self):
        self.download_zig(corrupt=False)

    def test_corrupt_download_is_never_extracted(self):
        self.download_zig(corrupt=True)

    def download_zig(self, corrupt):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            cache = home / "Library/Caches/flamez-release"
            name = "zig-aarch64-macos-0.16.0"
            payload = b"official archive"
            commands = []

            def run(*args):
                commands.append(args)
                if args[0] == "curl":
                    destination = args[args.index("--output") + 1]
                    if args[-1].endswith("index.json"):
                        destination.write_text(json.dumps({"0.16.0": {"aarch64-macos": {
                            "tarball": f"https://ziglang.org/download/0.16.0/{name}.tar.xz",
                            "shasum": hashlib.sha256(payload).hexdigest(),
                        }}}))
                    else:
                        destination.write_bytes(b"corrupted" if corrupt else payload)
                elif args[0] == "tar":
                    zig = args[-1] / name / "zig"
                    zig.parent.mkdir()
                    zig.write_bytes(b"executable")

            with patch.object(remote.Path, "home", return_value=home), \
                    patch.object(remote.shutil, "which", return_value=None), \
                    patch.object(remote, "run", side_effect=run), \
                    patch.object(remote, "output", return_value="0.16.0"):
                if corrupt:
                    with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                        remote.prepare_zig(home / "source")
                    self.assertNotIn("tar", [command[0] for command in commands])
                    self.assertFalse((cache / name).exists())
                else:
                    zig = remote.prepare_zig(home / "source")
                    self.assertEqual(zig.read_bytes(), b"executable")
                    commands.clear()
                    self.assertEqual(remote.prepare_zig(home / "source"), zig)
                    self.assertEqual(commands, [])


if __name__ == "__main__":
    unittest.main()
