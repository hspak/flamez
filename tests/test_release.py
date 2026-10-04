"""Exercise release preparation with real Git repositories and fake build/SSH tools."""
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ReleasePreparation(unittest.TestCase):
    def setUp(self):
        if platform.system() != "Linux":
            self.skipTest("the publishing script requires a Linux release host")
        for tool in ("bash", "git", "ruby", "file"):
            if not shutil.which(tool):
                self.skipTest(f"requires {tool}")
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "source"
        self.aur = self.root / "aur"
        self.tap = self.root / "tap"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        FLAMEZ_AUR_DIR=str(self.aur), FLAMEZ_TAP_DIR=str(self.tap),
                        TMPDIR=str(self.root), PYTHONDONTWRITEBYTECODE="1")
        for key in ("FLAMEZ_MACOS_HOST", "FLAMEZ_MACOS_ARCHIVE", "FLAMEZ_MINIMUM_MACOS"):
            self.env.pop(key, None)
        self.env["FLAMEZ_MACOS_REPO"] = "code/flamez with 'quotes'"
        self.repo.mkdir()
        (self.repo / "tools").mkdir()
        (self.repo / "tests").mkdir()
        for name in ("release.sh", "tools/package_macos.py", "tools/release_macos.py",
                     "tests/test_package_macos.py"):
            shutil.copyfile(ROOT / name, self.repo / name)
        (self.repo / "build.zig.zon").write_text('.{ .version = "0.2.0" }\n')
        self.aur.mkdir()
        (self.aur / "PKGBUILD").write_text('''pkgname=flamez
pkgver=0.1.0
pkgrel=2
depends=("glibc" "libbpf")
makedepends=("zig" "clang" "git" "libcap")
source=("https://github.com/hspak/flamez/archive/refs/tags/$pkgver.tar.gz")
sha256sums=("old")
build() {
  cd "flamez-$pkgver"
  zig build --release=safe -Dmsaa=false
}
check() {
  cd "flamez-$pkgver"
  zig build test -Dmsaa=false
}
package() {
  cd "flamez-$pkgver"
  install -Dm755 zig-out/bin/flamez "$pkgdir/usr/bin/flamez"
}
''')
        (self.aur / ".SRCINFO").write_text("original metadata\n")
        (self.tap / "Formula").mkdir(parents=True)
        (self.tap / "Formula/flamez.rb").write_text('''class Flamez < Formula
  version "0.1.0"
  url "https://example.com/old.tar.gz"
  sha256 "old"
  depends_on macos: :ventura
  def install
    prefix.install "bin", "share"
  end
end
''')
        for repo in (self.repo, self.aur, self.tap):
            self.git(repo, "init", "-b", "main")
            self.git(repo, "config", "user.name", "Release Test")
            self.git(repo, "config", "user.email", "test@example.invalid")
            self.git(repo, "add", ".")
            self.git(repo, "commit", "-m", "fixture: initialize")
            self.git(repo, "remote", "add", "origin", "git@github.com:hspak/flamez.git")
            self.git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
            self.git(repo, "branch", "--set-upstream-to=origin/main")
        self.revision = self.git(self.repo, "rev-parse", "HEAD").strip()
        self.archive = self.root / "macos.tar.gz"
        self.make_archive(self.revision)
        self.env["TEST_ARCHIVE"] = str(self.archive)
        self.env["TEST_LOG"] = str(self.root / "commands.jsonl")
        self.executable("zig", '#!/bin/sh\necho 0.16.0\n')
        self.executable("ssh", '''#!/usr/bin/env python3
import json, os, shlex, sys
from pathlib import Path
with open(os.environ['TEST_LOG'], 'a') as log:
    log.write(json.dumps(['ssh', *sys.argv[1:]]) + '\\n')
arguments = shlex.split(sys.argv[-1])
assert arguments[2] == "code/flamez with 'quotes'"
assert arguments[3] == 'https://github.com/hspak/flamez'
assert 'def prepare_dependencies' in sys.stdin.read()
sys.stdout.buffer.write(Path(os.environ['TEST_ARCHIVE']).read_bytes())
''')
        self.executable("makepkg", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open(os.environ['TEST_LOG'], 'a') as log:
    log.write(json.dumps(['makepkg', *sys.argv[1:]]) + '\\n')
package = Path.cwd() / 'flamez-0.2.0-1-x86_64.pkg.tar.zst'
if '--printsrcinfo' in sys.argv:
    print('pkgbase = flamez\\n\\tpkgver = 0.2.0')
elif '--packagelist' in sys.argv:
    print(package)
else:
    package.write_bytes(b'checked package')
''')

    def executable(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def git(self, repo, *args):
        return subprocess.check_output(["git", "-C", str(repo), *args],
                                       env=self.env, stderr=subprocess.PIPE, text=True)

    def make_archive(self, revision):
        binary = struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 2, 0, 0, 0, 0) + b"flamez 0.2.0"
        manifest = dict(version="0.2.0", architecture="arm64", minimum_macos="27.0",
                        runtime_dependencies=["sdl3", "freetype", "libpng"],
                        source_commit=revision, source_dirty=False,
                        executable_sha256=hashlib.sha256(binary).hexdigest())
        files = {"bin/flamez": binary, "share/flamez/macos-package.json": json.dumps(manifest).encode()}
        for name in ("Inter", "RobotoMono", "Clay", "zclay"):
            files[f"share/flamez/licenses/{name}-LICENSE.txt"] = b"notice"
        for name in ("flamez-analysis-v1.md", "flamez-analysis-v1.schema.json"):
            files[f"share/flamez/{name}"] = b"schema"
        with tarfile.open(self.archive, "w:gz") as bundle:
            for name, content in files.items():
                entry = tarfile.TarInfo(f"flamez-0.2.0-aarch64-macos/{name}")
                entry.size = len(content)
                bundle.addfile(entry, io.BytesIO(content))

    def release(self, *args):
        return subprocess.run(["bash", str(self.repo / "release.sh"), "0.2.0", "--check", *args],
                              env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def test_ssh_check_migrates_recipes_without_changing_repositories(self):
        result = self.release("--macos-host", "builder", "--minimum-macos", "27.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        output = self.repo / "zig-out/release"
        self.assertEqual((output / "flamez-0.2.0-aarch64-macos.tar.gz").read_bytes(),
                         self.archive.read_bytes())
        recipe = (output / "PKGBUILD").read_text()
        self.assertNotIn("-Dmsaa", recipe)
        # Ask Bash for the effective recipe, including arrays and function bodies.
        effective = subprocess.check_output(["bash", "-c",
            'source "$1"; declare -p depends makedepends; declare -f build check package',
            "test", str(output / "PKGBUILD")], text=True)
        for dependency in ("sdl3>=3.4.0", "freetype2", "libpng", "pkgconf", "vulkan-icd-loader"):
            self.assertIn(f'"{dependency}"', effective)
        self.assertIn('-Dversion="$pkgver"', effective)
        self.assertIn('cp -R "zig-out/share/flamez/licenses"', effective)
        formula = (output / "flamez.rb").read_text()
        self.assertIn("depends_on macos: :golden_gate", formula)
        self.assertIn('depends_on "sdl3"', formula)
        self.assertIn("https://github.com/hspak/flamez/releases/download/0.2.0/", formula)
        for repo in (self.repo, self.aur, self.tap):
            self.assertEqual(self.git(repo, "diff", "HEAD"), "")
            self.assertEqual(self.git(repo, "tag", "--list"), "")
        commands = [json.loads(line) for line in (self.root / "commands.jsonl").read_text().splitlines()]
        self.assertIn(["makepkg", "--syncdeps", "--force", "--cleanbuild", "--check", "--noconfirm"], commands)

    def test_supplied_archive_avoids_ssh(self):
        self.git(self.repo, "tag", "0.2.0")
        self.executable("ssh", "#!/bin/sh\nexit 99\n")
        result = self.release("--macos-archive", str(self.archive))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.repo, "tag", "--list").strip(), "0.2.0")

    def test_wrong_source_archive_stops_before_linux_build(self):
        self.make_archive("0" * 40)
        result = self.release("--macos-archive", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("macOS archive failed validation", result.stderr)
        self.assertFalse((self.root / "commands.jsonl").exists())

    def test_ssh_failure_stops_before_linux_build(self):
        self.executable("ssh", "#!/bin/sh\necho incomplete\nexit 42\n")
        result = self.release("--macos-host", "builder")
        self.assertEqual(result.returncode, 42)
        self.assertFalse((self.root / "commands.jsonl").exists())
        self.assertEqual(self.git(self.repo, "tag", "--list"), "")


if __name__ == "__main__":
    unittest.main()
