#!/usr/bin/env python3
"""Download and unpack the CEF binary distribution this package builds against.

    python3 scripts/fetch_cef.py

Unpacks into Dependencies/cef_macosx64/ — the path Package.swift compiles the
C++ wrapper from and NucleantCEF loads the framework from at runtime. The
build is pinned (CEF_VERSION) and checked against the SHA-1 CEF publishes, so
every checkout builds against the same CEF. macOS x86-64 only for now.

Re-running with the distribution already in place does nothing; pass --force
to replace it.
"""

import argparse
import hashlib
import shutil
import sys
import tarfile
import urllib.parse
import urllib.request
from pathlib import Path

CEF_VERSION = "154.0.28+g564dd6c+chromium-154.0.8037.58"
PLATFORM = "macosx64"
ARCHIVE = f"cef_binary_{CEF_VERSION}_{PLATFORM}_minimal.tar.bz2"
SHA1 = "60bb4e9d525d40a8ee721c55557a9edd058873dc"
URL = "https://cef-builds.spotifycdn.com/" + urllib.parse.quote(ARCHIVE)

PACKAGE_ROOT = Path(__file__).resolve().parent.parent
DEPENDENCIES = PACKAGE_ROOT / "Dependencies"
DESTINATION = DEPENDENCIES / f"cef_{PLATFORM}"
DOWNLOADS = DEPENDENCIES / "downloads"


def sha1_of(path: Path) -> str:
    digest = hashlib.sha1()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(archive: Path) -> None:
    if archive.exists() and sha1_of(archive) == SHA1:
        print(f"using {archive.name} (already downloaded)")
        return
    print(f"downloading {URL}")
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    partial = archive.with_suffix(archive.suffix + ".part")
    with urllib.request.urlopen(URL) as response, partial.open("wb") as out:
        shutil.copyfileobj(response, out)
    actual = sha1_of(partial)
    if actual != SHA1:
        partial.unlink()
        sys.exit(f"checksum mismatch: expected {SHA1}, got {actual}")
    partial.rename(archive)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--force", action="store_true", help="replace an existing distribution")
    args = parser.parse_args()

    if DESTINATION.exists() and not args.force:
        print(f"{DESTINATION.relative_to(PACKAGE_ROOT)} already exists (--force to replace)")
        return

    archive = DOWNLOADS / ARCHIVE
    download(archive)

    print(f"unpacking into {DESTINATION.relative_to(PACKAGE_ROOT)}")
    staging = DEPENDENCIES / "unpacking"
    shutil.rmtree(staging, ignore_errors=True)
    with tarfile.open(archive) as tar:
        tar.extractall(staging, filter="data")
    # The archive holds one top-level directory named after the build.
    (unpacked,) = staging.iterdir()
    shutil.rmtree(DESTINATION, ignore_errors=True)
    unpacked.rename(DESTINATION)
    staging.rmdir()
    print("done")


if __name__ == "__main__":
    main()
