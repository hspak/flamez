"""Packaging rejects misleading deployment targets and changed release payloads."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "package_macos", Path(__file__).resolve().parents[1] / "tools/package_macos.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class DeploymentTargets(unittest.TestCase):
    def inspect(self, dylib_minimum, requested):
        library = "/opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib"

        def command(*args):
            if args[0] == "lipo":
                return "arm64"
            if args[1] == "-l":
                minimum = dylib_minimum if str(args[2]) == library else "13.0"
                return f"cmd LC_BUILD_VERSION\n minos {minimum}\n sdk 27.0"
            return f"{args[2]}:\n\t{library} (compatibility version 401.0.0)\n"

        with patch.object(package, "command", side_effect=command):
            return package.inspect_binary("/tmp/flamez", requested)

    def test_linked_library_cannot_raise_advertised_minimum(self):
        with self.assertRaisesRegex(ValueError, "requires macOS 27.0, above 13.0"):
            self.inspect("27.0", "13.0")

    def test_matching_target_accepts_recursive_dylib_identity(self):
        self.assertEqual(len(self.inspect("27.0", "27.0")), 2)


class ArchiveIntegrity(unittest.TestCase):
    def archive(self, path, binary=b"executable", extra=None):
        root = "flamez-0.2.0-aarch64-macos"
        manifest = dict(version="0.2.0", architecture="arm64", minimum_macos="27.0",
                        runtime_dependencies=list(package.DEPENDENCIES),
                        executable_sha256=hashlib.sha256(b"executable").hexdigest())
        files = {"bin/flamez": binary, "share/flamez/macos-package.json": json.dumps(manifest).encode()}
        for name in ("Inter", "RobotoMono", "Clay", "zclay"):
            files[f"share/flamez/licenses/{name}-LICENSE.txt"] = b"notice"
        for name in ("flamez-analysis-v1.md", "flamez-analysis-v1.schema.json"):
            files[f"share/flamez/{name}"] = b"schema"
        if extra:
            files[extra] = b"unexpected"
        with tarfile.open(path, "w:gz") as archive:
            for name, content in files.items():
                info = tarfile.TarInfo(f"{root}/{name}")
                info.size = len(content)
                archive.addfile(info, io.BytesIO(content))

    def test_verification_rejects_changed_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "package.tar.gz"
            self.archive(path)
            self.assertEqual(package.verify(path, "0.2.0")["minimum_macos"], "27.0")
            self.archive(path, binary=b"different executable")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                package.verify(path, "0.2.0")

    def test_verification_rejects_paths_outside_package(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "package.tar.gz"
            self.archive(path, extra="../escape")
            with self.assertRaisesRegex(ValueError, "unsupported archive member"):
                package.verify(path, "0.2.0")


if __name__ == "__main__":
    unittest.main()
