#!/usr/bin/env python3
"""Build a validated Apple-silicon archive using Homebrew-managed GUI libraries."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile


REPOSITORY = Path(__file__).resolve().parents[1]
DEPENDENCIES = ("sdl3", "freetype", "libpng")


def command(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def version_tuple(version):
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", version):
        raise ValueError(f"invalid macOS version: {version}")
    parts = tuple(map(int, version.split(".")))
    return parts + (0,) * (3 - len(parts))


def inspect_binary(path, minimum, seen=None):
    """Reject undeclared dylibs and deployment targets newer than the package."""
    seen = {} if seen is None else seen
    path = Path(path)
    if str(path) in seen:
        return seen
    if command("lipo", "-archs", path) != "arm64":
        raise ValueError(f"expected an arm64-only binary: {path}")
    load_commands = command("otool", "-l", path)
    match = re.search(r"\bminos ([\d.]+)", load_commands)
    if match is None:
        match = re.search(r"LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)", load_commands)
    if match is None or version_tuple(match[1]) > version_tuple(minimum):
        raise ValueError(f"{path} requires macOS {match[1] if match else 'unknown'}, above {minimum}")
    libraries = [line.strip().split(" (compatibility version", 1)[0]
                 for line in command("otool", "-L", path).splitlines()[1:]]
    seen[str(path)] = dict(minimum_macos=match[1], libraries=libraries)
    for library in libraries:
        if library.startswith(("/usr/lib/", "/System/Library/")):
            continue
        if not any(library.startswith(f"/opt/homebrew/opt/{name}/lib/") for name in DEPENDENCIES):
            raise ValueError(f"undeclared dependency in {path}: {library}")
        inspect_binary(library, minimum, seen)
    return seen


def verify(archive, version):
    """Portable verification before release.sh touches tags or package repositories."""
    root = f"flamez-{version}-aarch64-macos"
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        names = [entry.name for entry in members]
        if len(names) != len(set(names)):
            raise ValueError("duplicate archive member")
        for entry in members:
            if (not entry.isfile() and not entry.isdir()) or ".." in Path(entry.name).parts:
                raise ValueError(f"unsupported archive member: {entry.name}")
            if entry.name != root and not entry.name.startswith(root + "/"):
                raise ValueError(f"unexpected archive root: {entry.name}")
        manifest = json.load(bundle.extractfile(f"{root}/share/flamez/macos-package.json"))
        if (manifest["version"] != version or manifest["architecture"] != "arm64"
                or manifest["runtime_dependencies"] != list(DEPENDENCIES)):
            raise ValueError("package metadata mismatch")
        version_tuple(manifest["minimum_macos"])
        payload = bundle.extractfile(f"{root}/bin/flamez").read()
        if hashlib.sha256(payload).hexdigest() != manifest["executable_sha256"]:
            raise ValueError("executable checksum mismatch")
        for name in ("Inter", "RobotoMono", "Clay", "zclay"):
            bundle.getmember(f"{root}/share/flamez/licenses/{name}-LICENSE.txt")
        for name in ("flamez-analysis-v1.md", "flamez-analysis-v1.schema.json"):
            bundle.getmember(f"{root}/share/flamez/{name}")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--minimum-macos", help="required for builds; every linked dylib must support this version")
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify", type=Path, help="verify an existing archive without macOS tools")
    parser.add_argument("--release-commit", help="require a clean package built from this source commit")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        parser.error("version must use X.Y.Z")
    if args.verify:
        manifest = verify(args.verify, args.version)
        if args.release_commit and (manifest["source_commit"] != args.release_commit or manifest["source_dirty"]):
            parser.error("release archive must come from the clean source commit being published")
        print(json.dumps(manifest, indent=2))
        return
    if not args.minimum_macos or not args.output:
        parser.error("building requires --minimum-macos and --output")
    version_tuple(args.minimum_macos)
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("build on an Apple-silicon Mac, then transfer the archive to the release host")
    if command(args.zig, "version") != "0.16.0":
        parser.error("Zig 0.16.0 is required")
    if args.output.exists():
        parser.error("output already exists")
    with tempfile.TemporaryDirectory(prefix="flamez-package-") as temporary:
        package = Path(temporary) / f"flamez-{args.version}-aarch64-macos"
        subprocess.run([args.zig, "build", "--prefix", str(package),
                        f"-Dtarget=aarch64-macos.{args.minimum_macos}", "-Doptimize=ReleaseSafe",
                        f"-Dversion={args.version}", "-Dgui-prefix=/opt/homebrew"],
                       cwd=REPOSITORY, check=True)
        binary = package / "bin/flamez"
        linkage = inspect_binary(binary, args.minimum_macos)
        if command(binary, "--version") != f"flamez {args.version}":
            raise ValueError("packaged executable version mismatch")
        # Absolute Homebrew install names need no build-machine SDK search paths.
        rpaths = re.findall(r"LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", command("otool", "-l", binary))
        for path in rpaths:
            subprocess.run(["install_name_tool", "-delete_rpath", path, str(binary)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
        fixture = Path(temporary) / "session.json"
        shutil.copyfile(REPOSITORY / "src/testdata/session-v1-exec-history.json", fixture)
        subprocess.run([str(binary), "--analyze", str(fixture)],
                       cwd=temporary, stdout=subprocess.DEVNULL, check=True)
        dirty = subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], cwd=REPOSITORY).returncode
        if dirty not in (0, 1):
            raise ValueError("could not inspect source status")
        manifest = dict(version=args.version, architecture="arm64", minimum_macos=args.minimum_macos,
                        runtime_dependencies=list(DEPENDENCIES), linkage=linkage,
                        source_commit=command("git", "-C", REPOSITORY, "rev-parse", "HEAD"), source_dirty=bool(dirty),
                        executable_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
        (package / "share/flamez/macos-package.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for name in ("README.md", "MACOS_SDL.md", "LICENSE"):
            shutil.copyfile(REPOSITORY / name, package / name)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(args.output, "x:gz") as archive:
            archive.add(package, arcname=package.name)
    verify(args.output, args.version)
    print(f"archive={args.output}")
    print(f"sha256={hashlib.sha256(args.output.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
