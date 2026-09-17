#!/usr/bin/env python3
"""Build and verify a reproducible, unmodified C/Objective-C SDK package."""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import tarfile
import tempfile


def selected_files(sdk):
    roots = ["usr/include", "usr/lib", "System/Library/Frameworks"]
    files = {
        "SDKSettings.json",
        "SDKSettings.plist",
        "System/Library/CoreServices/SystemVersion.plist",
    }
    for root in roots:
        for directory, directories, names in os.walk(sdk / root, followlinks=True):
            # Swift modules and framework resources are not inputs to Flamez's
            # C/Objective-C compilation. Headers and stubs remain byte-for-byte.
            directories[:] = sorted(d for d in directories if d not in {"Modules", "Resources"})
            for name in sorted(names):
                path = Path(directory) / name
                relative = path.relative_to(sdk).as_posix()
                if root == "usr/lib" and not name.endswith(".tbd"):
                    continue
                if path.is_file():
                    files.add(relative)
    return sorted(files)


def sdk_manifest(sdk):
    settings = json.loads((sdk / "SDKSettings.json").read_bytes())
    version = plistlib.loads((sdk / "System/Library/CoreServices/SystemVersion.plist").read_bytes())
    if int(settings["Version"].split(".")[0]) < 27:
        raise ValueError("SDK 27 or newer is required")
    header = (sdk / "usr/include/EndpointSecurity/ESClient.h").read_text()
    if "es_new_descendants_client" not in header:
        raise ValueError("SDK lacks the descendant Endpoint Security declaration")
    entries = []
    paths = selected_files(sdk)
    for name in paths:
        path = sdk / name
        if not path.resolve(strict=True).is_relative_to(sdk):
            raise ValueError(f"SDK link escapes its root: {name}")
        # Realize SDK aliases, including the macOS 27 Cryptex framework links,
        # so the package works on hosts without symlink support.
        entries.append({"path": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    return {
        "schema": 1,
        "version": settings["Version"],
        "build": version["ProductBuildVersion"],
        "canonical_name": settings["CanonicalName"],
        "files": entries,
    }


def manifest_bytes(manifest):
    return (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()


def package(sdk, output):
    manifest = sdk_manifest(sdk)
    prefix = f"macos-sdk-{manifest['version']}-{manifest['build']}"
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as temporary:
        temp_path = Path(temporary.name)
        try:
            with gzip.GzipFile(filename="", mode="wb", fileobj=temporary, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as archive:
                    for entry in manifest["files"] + [{"path": "sdk-manifest.json"}]:
                        name = entry["path"]
                        info = tarfile.TarInfo(f"{prefix}/{name}")
                        info.mode = 0o644
                        data = manifest_bytes(manifest) if name == "sdk-manifest.json" else (sdk / name).read_bytes()
                        info.size = len(data)
                        archive.addfile(info, io.BytesIO(data))
            temporary.flush()
            os.fsync(temporary.fileno())
            os.replace(temp_path, output)
        finally:
            temp_path.unlink(missing_ok=True)
    verify(sdk, output)
    print(f"archive={output}")
    print(f"sha256={hashlib.sha256(output.read_bytes()).hexdigest()}")


def verify(sdk, archive_path):
    expected = sdk_manifest(sdk)
    prefix = f"macos-sdk-{expected['version']}-{expected['build']}/"
    entries = {entry["path"]: entry for entry in expected["files"]}
    seen = set()
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive:
            if not member.name.startswith(prefix):
                raise ValueError(f"unexpected archive root: {member.name}")
            name = member.name[len(prefix):]
            if name in seen:
                raise ValueError(f"duplicate archive member: {name}")
            seen.add(name)
            if name == "sdk-manifest.json":
                if not member.isfile() or archive.extractfile(member).read() != manifest_bytes(expected):
                    raise ValueError("SDK provenance does not match the installed SDK")
                continue
            entry = entries.get(name)
            if entry is None:
                raise ValueError(f"unexpected SDK file: {name}")
            if not member.isfile() or hashlib.sha256(archive.extractfile(member).read()).hexdigest() != entry["sha256"]:
                raise ValueError(f"changed SDK file: {name}")
    if seen != set(entries) | {"sdk-manifest.json"}:
        raise ValueError("archive is missing SDK inputs")
    print(f"verified SDK {expected['version']} ({expected['build']}): {len(entries)} unchanged files")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--output", type=Path)
    mode.add_argument("--verify", type=Path)
    args = parser.parse_args()
    sdk = args.sdk.resolve(strict=True)
    if args.verify:
        verify(sdk, args.verify)
    else:
        package(sdk, args.output)


if __name__ == "__main__":
    main()
