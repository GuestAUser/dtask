#!/usr/bin/env python3
"""Package a native executable with only its license and example themes."""

import gzip
import hashlib
from pathlib import Path
import platform
import re
import subprocess
import sys
import tarfile

def main() -> None:
    if len(sys.argv) not in (3, 4):
        raise SystemExit("Usage: package-release.py VERSION PLATFORM [BINARY]")

    version, target = sys.argv[1:3]
    if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version) is None:
        raise SystemExit("Version must have the form v1.2.3")

    systems = {
        "linux-x86_64": ("Linux", "x86_64"),
        "macos-arm64": ("Darwin", "arm64"),
        "freebsd-x86_64": ("FreeBSD", "amd64"),
    }
    if systems.get(target) != (platform.system(), platform.machine()):
        raise SystemExit("The package target must match the native build host")

    root = Path(__file__).resolve().parents[1]
    binary = Path(sys.argv[3]).resolve() if len(sys.argv) == 4 else root / "bin/dtask"
    result = subprocess.run(
        [str(binary), "--version"], check=True, capture_output=True, text=True,
    )
    if result.stdout.strip() != f"dtask {version[1:]}":
        raise SystemExit("The executable version does not match the release")

    timestamp = int(subprocess.check_output(
        ["git", "show", "-s", "--format=%ct", "HEAD"], cwd=root, text=True,
    ))
    name = f"dtask-{version}-{target}"
    destination = root / "dist"
    destination.mkdir(exist_ok=True)
    archive = destination / f"{name}.tar.gz"
    files = [(binary, "dtask"), (root / "LICENSE", "LICENSE")]
    files.extend((path, f"themes/{path.name}") for path in sorted((root / "themes").glob("*.json")))

    with archive.open("xb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=timestamp) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as package:
                for source, relative in files:
                    entry = tarfile.TarInfo(f"{name}/{relative}")
                    entry.size = source.stat().st_size
                    entry.mode = 0o755 if relative == "dtask" else 0o644
                    entry.mtime = timestamp
                    with source.open("rb") as content:
                        package.addfile(entry, content)

    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    print(f"{checksum}  {archive.name}")

if __name__ == "__main__":
    main()
