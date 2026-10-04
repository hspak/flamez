#!/usr/bin/env python3
"""Run over SSH: prepare an Apple-silicon builder and stream a validated archive."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile


ZIG_VERSION = "0.16.0"


def run(*args, **kwargs):
    # stdout belongs exclusively to the archive consumed by the Linux host.
    subprocess.run([str(arg) for arg in args], check=True, stdout=sys.stderr, **kwargs)


def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def prepare_zig(repository):
    name = f"zig-aarch64-macos-{ZIG_VERSION}"
    cache = Path.home() / "Library/Caches/flamez-release"
    candidates = [repository / ".tools" / name / "zig", cache / name / "zig"]
    installed = shutil.which("zig")
    if installed:
        candidates.append(Path(installed))
    for zig in candidates:
        if zig.is_file() and output(zig, "version") == ZIG_VERSION:
            return zig

    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="download-", dir=cache) as temporary:
        work = Path(temporary)
        index = work / "index.json"
        run("curl", "--fail", "--location", "--retry", "3", "--output", index,
            "https://ziglang.org/download/index.json")
        release = json.loads(index.read_text())[ZIG_VERSION]["aarch64-macos"]
        url = release["tarball"]
        if not url.startswith("https://ziglang.org/download/"):
            raise ValueError("unexpected Zig download URL")
        archive = work / "zig.tar.xz"
        run("curl", "--fail", "--location", "--retry", "3", "--output", archive, url)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != release["shasum"]:
            raise ValueError("Zig download checksum mismatch")
        run("tar", "-xJf", archive, "-C", work)
        if output(work / name / "zig", "version") != ZIG_VERSION:
            raise ValueError("downloaded Zig version mismatch")
        destination = cache / name
        if destination.exists():
            raise ValueError(f"invalid cached Zig installation; remove {destination} and retry")
        (work / name).rename(destination)
    return cache / name / "zig"


def prepare_dependencies():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("the SSH builder must be an Apple-silicon Mac running natively")
    try:
        sdk = Path(output("xcrun", "--sdk", "macosx", "--show-sdk-path"))
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("install/select Xcode Command Line Tools on the Mac with xcode-select first") from error
    if not (sdk / "usr/include").is_dir():
        raise ValueError(f"selected macOS SDK has no headers: {sdk}")
    brew = Path("/opt/homebrew/bin/brew")
    if not brew.is_file():
        raise ValueError("install Apple-silicon Homebrew at /opt/homebrew on the Mac first")
    if output(brew, "--prefix") != "/opt/homebrew":
        raise ValueError("packaging requires Homebrew's /opt/homebrew prefix")
    os.environ["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:" + os.environ.get("PATH", "")
    missing = []
    for formula in ("sdl3", "freetype", "libpng", "pkgconf"):
        result = subprocess.run([str(brew), "list", "--versions", formula],
                                stdout=subprocess.PIPE, stderr=sys.stderr, text=True)
        if result.returncode or not result.stdout.strip():
            missing.append(formula)
    if missing:
        run(brew, "install", *missing)
    if subprocess.run(["pkg-config", "--atleast-version=3.4.0", "sdl3"]).returncode:
        run(brew, "upgrade", "sdl3")
    run("pkg-config", "--atleast-version=3.4.0", "sdl3")
    run("pkg-config", "--exists", "freetype2", "libpng")
    for tool in ("git", "curl", "tar", "lipo", "otool", "install_name_tool", "codesign"):
        if not shutil.which(tool):
            raise ValueError(f"required Mac command not found: {tool}")


def build(repository, origin, version, revision, minimum):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("expected an X.Y.Z version")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("expected a full source commit")
    if minimum and not re.fullmatch(r"[0-9]+\.0", minimum):
        raise ValueError("minimum macOS must use MAJOR.0, matching a Homebrew release")
    prepare_dependencies()
    minimum = minimum or output("sw_vers", "-productVersion").split(".")[0] + ".0"
    repository = Path(repository).expanduser()
    if not repository.is_absolute():
        repository = Path.home() / repository
    zig = prepare_zig(repository)
    with tempfile.TemporaryDirectory(prefix="flamez-release-") as temporary:
        work = Path(temporary)
        source = work / "source"
        if (repository / ".git").exists():
            run("git", "clone", "--shared", "--no-checkout", "--", repository, source)
        else:
            run("git", "clone", "--no-checkout", "--", origin, source)
        run("git", "-C", source, "fetch", "--no-tags", "--", origin, revision)
        run("git", "-C", source, "checkout", "--detach", revision)
        run(zig, "build", "test", "-Dgui-prefix=/opt/homebrew", cwd=source)
        archive = work / f"flamez-{version}-aarch64-macos.tar.gz"
        packager = source / "tools/package_macos.py"
        run(sys.executable, packager, "--version", version, "--minimum-macos", minimum,
            "--zig", zig, "--output", archive)
        run(sys.executable, packager, "--version", version, "--verify", archive,
            "--release-commit", revision)
        with archive.open("rb") as package:
            shutil.copyfileobj(package, sys.stdout.buffer)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", help="optional existing checkout supplying cached tools/objects")
    parser.add_argument("origin")
    parser.add_argument("version")
    parser.add_argument("revision")
    parser.add_argument("minimum", nargs="?", default="")
    args = parser.parse_args()
    try:
        build(args.repository, args.origin, args.version, args.revision, args.minimum)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"release_macos.py: {error}\n")


if __name__ == "__main__":
    main()
