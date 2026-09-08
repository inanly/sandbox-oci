#!/usr/bin/env python3
"""Apply the filesystem and package mutations used by the OCI fixture."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


WORKSPACE = Path("/workspace")
EXPECTED = WORKSPACE / "expected.json"


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def metadata(path: Path) -> dict[str, object]:
    stat = path.lstat()
    if path.is_symlink():
        kind = "symlink"
        content_hash = hashlib.sha256(os.readlink(path).encode()).hexdigest()
        target: str | None = os.readlink(path)
    elif path.is_file():
        kind = "file"
        content_hash = digest(path)
        target = None
    elif path.is_dir():
        kind = "directory"
        content_hash = None
        target = None
    else:
        raise RuntimeError(f"unsupported fixture entry: {path}")
    return {
        "type": kind,
        "sha256": content_hash,
        "mode": stat.st_mode & 0o7777,
        "uid": stat.st_uid,
        "gid": stat.st_gid,
        "symlink": target,
    }


def main() -> None:
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "--no-cache-dir", "numpy==2.2.6"],
        check=True,
    )

    (WORKSPACE / "test.txt").write_text("created by mutate.py\n", encoding="utf-8")
    (WORKSPACE / "modify.txt").write_text("modified by mutate.py\n", encoding="utf-8")
    (WORKSPACE / "delete.txt").unlink()
    shutil.rmtree(WORKSPACE / "dir-delete")
    os.chmod(WORKSPACE / "run.sh", 0o751)

    new_link = WORKSPACE / "new-link"
    if new_link.exists() or new_link.is_symlink():
        new_link.unlink()
    new_link.symlink_to("test.txt")
    os.chown(WORKSPACE / "test.txt", 1234, 1234)

    entries = ["modify.txt", "run.sh", "base-link", "test.txt", "new-link"]
    expected = {
        "paths": {name: metadata(WORKSPACE / name) for name in entries},
        "absent": ["delete.txt", "dir-delete"],
        "numpy_version": "2.2.6",
    }
    EXPECTED.write_text(json.dumps(expected, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
