"""Exercise releases with local Git remotes and fake build, SSH, and GitHub tools."""
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
pkgdesc="Release test fixture"
arch=("x86_64")
license=("MIT")
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
    if '--verifysource' in sys.argv and os.environ.get('TEST_REAL_MAKEPKG'):
        os.execv(os.environ['TEST_REAL_MAKEPKG'], ['makepkg', *sys.argv[1:]])
    if package.exists() and not any(flag in sys.argv for flag in
                                    ('--force', '--nobuild', '--noarchive', '--source')):
        sys.exit('A package has already been built. (use -f to overwrite)')
    if '--verifysource' in sys.argv:
        source = Path(os.environ.get('SRCDEST', '.')) / '0.2.0.tar.gz'
        import hashlib
        assert hashlib.sha256(source.read_bytes()).hexdigest() in Path('PKGBUILD').read_text()
        sys.exit(0)
    if os.environ.get('TEST_BUILT_SOURCE'):
        Path(os.environ['TEST_BUILT_SOURCE']).write_bytes(Path('0.2.0.tar.gz').read_bytes())
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

    def prepare_publishing(self):
        for repo in (self.repo, self.aur, self.tap):
            remote = self.root / f"{repo.name}.git"
            self.git(repo, "init", "--bare", str(remote))
            self.git(repo, "remote", "set-url", "origin", str(remote))
            self.git(repo, "push", "-u", "origin", "main")
        self.env["TEST_SOURCE"] = str(self.repo)
        self.env["TEST_REAL_GIT"] = shutil.which("git")
        self.env["TEST_GITHUB"] = str(self.root / "github.json")
        self.env["TEST_BUILT_SOURCE"] = str(self.root / "built-source.tar.gz")
        self.executable("git", '''#!/usr/bin/env python3
import os, sys
if sys.argv[1:] == ['-C', os.environ['TEST_SOURCE'], 'remote', 'get-url', 'origin']:
    print('https://github.com/hspak/flamez.git')
else:
    os.execv(os.environ['TEST_REAL_GIT'], ['git', *sys.argv[1:]])
''')
        self.executable("gh", '''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['TEST_LOG'], 'a') as log:
    log.write(json.dumps(['gh', *args]) + '\\n')
path = Path(os.environ['TEST_GITHUB'])
release = json.loads(path.read_text()) if path.exists() else None
assets = path.parent / 'assets'
assets.mkdir(exist_ok=True)
if args[:2] == ['auth', 'status']:
    pass
elif args[:2] == ['repo', 'view']:
    print('hspak/flamez')
elif args[0] == 'api':
    if os.environ.get('TEST_QUERY_FAILURE'):
        sys.exit('GitHub unavailable')
    if release:
        print('draft' if release['draft'] else 'published')
elif args[:2] == ['release', 'view']:
    assert release
    print('\\n'.join(p.name for p in assets.iterdir()))
elif args[:2] == ['release', 'download']:
    shutil.copyfile(assets / args[args.index('--pattern') + 1],
                    args[args.index('--output') + 1])
elif args[:2] == ['release', 'create']:
    assert release is None, 'release already exists'
    path.write_text(json.dumps({'draft': True}))
    shutil.copyfile(args[args.index('--notes-file') + 1], path.parent / 'github-notes.md')
    for arg in args[3:]:
        if arg.startswith('--'):
            break
        if Path(arg).is_file():
            shutil.copyfile(arg, assets / Path(arg).name)
elif args[:2] == ['release', 'upload']:
    assert release['draft'], 'cannot replace published assets'
    for arg in args[3:]:
        if Path(arg).is_file():
            shutil.copyfile(arg, assets / Path(arg).name)
elif args[:2] == ['release', 'edit']:
    if os.environ.get('TEST_PUBLISH_FAILURE'):
        sys.exit('publication interrupted')
    release['draft'] = False
    path.write_text(json.dumps(release))
else:
    sys.exit(f'unexpected gh call: {args}')
''')
        self.executable("curl", '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
if os.environ.get('TEST_DOWNLOAD_FAILURE'):
    sys.exit('download interrupted')
Path(sys.argv[sys.argv.index('--output') + 1]).write_bytes(b'GitHub source archive')
''')

    def publish(self, *args):
        return subprocess.run(["bash", str(self.repo / "release.sh"), "0.2.0", *args],
                              env=self.env, capture_output=True, text=True)

    def assert_published(self):
        self.assertFalse(json.loads((self.root / "github.json").read_text())["draft"])
        for repo in (self.aur, self.tap):
            self.assertEqual(self.git(repo, "status", "--porcelain"), "")
            self.assertEqual(self.git(repo, "rev-parse", "HEAD"),
                             self.git(repo, "rev-parse", "@{upstream}"))
        self.assertIn('pkgver=0.2.0', (self.aur / 'PKGBUILD').read_text())
        checksum = hashlib.sha256((self.root / "assets" /
                                  "flamez-0.2.0-aarch64-macos.tar.gz").read_bytes()).hexdigest()
        self.assertIn(checksum, (self.tap / "Formula/flamez.rb").read_text())

    def test_publish_verifies_sources_after_building_package(self):
        self.prepare_publishing()
        result = self.publish("--macos-archive", str(self.archive))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_published()

    def test_retry_reuses_tag_and_draft_archive(self):
        self.prepare_publishing()
        self.env["TEST_DOWNLOAD_FAILURE"] = "1"
        result = self.publish("--macos-archive", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("download interrupted", result.stderr)
        self.env.pop("TEST_DOWNLOAD_FAILURE")
        self.executable("ssh", "#!/bin/sh\nexit 99\n")
        result = self.publish("--macos-host", "builder")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_published()

    def test_publish_with_real_makepkg_source_verification(self):
        makepkg = shutil.which("makepkg")
        if not makepkg or os.getuid() == 0 or platform.machine() != "x86_64":
            self.skipTest("requires makepkg on an x86_64 host without root")
        self.prepare_publishing()
        self.env["TEST_REAL_MAKEPKG"] = makepkg
        result = self.publish("--macos-archive", str(self.archive))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_published()

    def test_retry_after_publication_failure_skips_unchanged_commits(self):
        self.prepare_publishing()
        self.env["TEST_PUBLISH_FAILURE"] = "1"
        result = self.publish("--macos-archive", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("publication interrupted", result.stderr)
        revisions = [self.git(repo, "rev-parse", "HEAD") for repo in (self.aur, self.tap)]
        self.env.pop("TEST_PUBLISH_FAILURE")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_published()
        self.assertEqual(revisions, [self.git(repo, "rev-parse", "HEAD")
                                     for repo in (self.aur, self.tap)])

    def assert_retry_pushes_pending_commit(self, repo):
        self.prepare_publishing()
        hook = self.root / f"{repo.name}.git/hooks/pre-receive"
        hook.write_text("#!/bin/sh\necho 'push interrupted' >&2\nexit 1\n")
        hook.chmod(0o755)
        result = self.publish("--macos-archive", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("push interrupted", result.stderr)
        pending = self.git(repo, "rev-parse", "HEAD")
        self.assertNotEqual(pending, self.git(repo, "rev-parse", "@{upstream}"))
        hook.unlink()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(pending, self.git(repo, "rev-parse", "HEAD"))
        self.assert_published()

    def test_retry_pushes_pending_aur_commit(self):
        self.assert_retry_pushes_pending_commit(self.aur)

    def test_retry_pushes_pending_tap_commit(self):
        self.assert_retry_pushes_pending_commit(self.tap)

    def test_matching_remote_annotated_tag_is_reused(self):
        self.prepare_publishing()
        self.git(self.repo, "tag", "-a", "0.2.0", "-m", "existing release tag")
        tag = self.git(self.repo, "rev-parse", "refs/tags/0.2.0")
        self.git(self.repo, "push", "origin", "refs/tags/0.2.0")
        self.git(self.repo, "tag", "-d", "0.2.0")
        result = self.publish("--macos-archive", str(self.archive))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_published()
        self.assertEqual(self.git(self.repo, "ls-remote", "--tags", "origin",
                                  "refs/tags/0.2.0").split()[0], tag.strip())

    def test_local_tag_is_reused_after_tag_push_failure(self):
        self.prepare_publishing()
        self.git(self.repo, "tag", "0.2.0")
        result = self.publish("--macos-archive", str(self.archive))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_published()

    def test_conflicting_tags_stop_before_building(self):
        self.prepare_publishing()
        self.git(self.repo, "commit", "--allow-empty", "-m", "unrelated commit")
        self.git(self.repo, "tag", "0.2.0")
        self.git(self.repo, "reset", "--hard", "HEAD^")
        for remote in (False, True):
            with self.subTest(remote=remote):
                if remote:
                    self.git(self.repo, "push", "origin", "refs/tags/0.2.0")
                    self.git(self.repo, "tag", "-d", "0.2.0")
                result = self.publish("--macos-archive", str(self.archive))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("does not point to", result.stderr)
                self.assertNotIn("Installing missing", result.stdout)
                self.assertFalse((self.root / "github.json").exists())

    def test_release_query_failure_stops_before_building(self):
        self.prepare_publishing()
        self.env["TEST_QUERY_FAILURE"] = "1"
        result = self.publish("--macos-archive", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not query GitHub releases", result.stderr)
        self.assertNotIn("Installing missing", result.stdout)
        self.assertEqual(self.git(self.repo, "tag", "--list"), "")

    def test_published_release_is_not_modified(self):
        self.prepare_publishing()
        result = self.publish("--macos-archive", str(self.archive))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        revisions = [self.git(repo, "rev-parse", "HEAD") for repo in (self.aur, self.tap)]
        self.make_archive("0" * 40)
        result = self.publish("--macos-archive", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already published", result.stderr)
        self.assertNotIn("Installing missing", result.stdout)
        self.assertEqual(revisions, [self.git(repo, "rev-parse", "HEAD")
                                     for repo in (self.aur, self.tap)])
        self.assert_published()

    def assert_resume_uses_tagged_source(self, remote_only):
        self.prepare_publishing()
        self.git(self.repo, "tag", "0.2.0")
        self.git(self.repo, "push", "origin", "refs/tags/0.2.0")
        if remote_only:
            self.git(self.repo, "tag", "-d", "0.2.0")
        (self.repo / "build.zig.zon").write_text('.{ .version = "0.3.0" }\n')
        self.git(self.repo, "add", "build.zig.zon")
        self.git(self.repo, "commit", "-m", "tooling: fix release retries")
        self.git(self.repo, "push")
        result = self.publish("--resume", "--macos-archive", str(self.archive))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_published()
        with tarfile.open(self.root / "assets/flamez-0.2.0-aarch64-macos.tar.gz") as archive:
            manifest = json.load(archive.extractfile(
                "flamez-0.2.0-aarch64-macos/share/flamez/macos-package.json"))
        self.assertEqual(manifest["source_commit"], self.revision)
        with tarfile.open(self.root / "built-source.tar.gz") as archive:
            version = archive.extractfile("flamez-0.2.0/build.zig.zon").read()
        self.assertIn(b'.version = "0.2.0"', version)
        notes = (self.root / "github-notes.md").read_text()
        self.assertNotIn("tooling: fix release retries", notes)
        self.assertIn(self.revision, notes)

    def test_resume_uses_tagged_source_after_tooling_commit(self):
        self.assert_resume_uses_tagged_source(remote_only=False)

    def test_resume_fetches_tag_when_missing_locally(self):
        self.assert_resume_uses_tagged_source(remote_only=True)

    def test_resume_requires_existing_tag(self):
        self.prepare_publishing()
        result = self.publish("--resume", "--macos-archive", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--resume requires an existing tag", result.stderr)
        self.assertFalse((self.root / "github.json").exists())

    def test_retry_rejects_changed_draft_archive(self):
        self.prepare_publishing()
        self.env["TEST_DOWNLOAD_FAILURE"] = "1"
        result = self.publish("--macos-archive", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("download interrupted", result.stderr)
        self.env.pop("TEST_DOWNLOAD_FAILURE")
        self.make_archive("0" * 40)
        result = self.publish("--macos-archive", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from the draft asset", result.stderr)
        self.assertNotIn("Installing missing", result.stdout)
        self.assertTrue(json.loads((self.root / "github.json").read_text())["draft"])

    def test_pending_release_commit_cannot_include_unrelated_changes(self):
        self.prepare_publishing()
        (self.aur / "unrelated").write_text("do not publish this")
        self.git(self.aur, "add", "unrelated")
        self.git(self.aur, "commit", "-m", "Publish version 0.2.0")
        result = self.publish("--macos-archive", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changes unrelated file", result.stderr)
        self.assertFalse((self.root / "github.json").exists())

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
