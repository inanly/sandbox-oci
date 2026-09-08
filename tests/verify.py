#!/usr/bin/env python3
"""Verify the expected state produced by mutate.py inside the fixture image."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys


WORKSPACE = Path("/workspace")


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


def main() -> int:
    failures: list[str] = []
    try:
        expected = json.loads((WORKSPACE / "expected.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"cannot read expected.json: {error}", file=sys.stderr)
        return 1

    for name, wanted in expected["paths"].items():
        path = WORKSPACE / name
        if not path.exists() and not path.is_symlink():
            failures.append(f"missing {name}")
            continue
        try:
            actual = metadata(path)
        except OSError as error:
            failures.append(f"cannot inspect {name}: {error}")
            continue
        if actual != wanted:
            failures.append(f"metadata mismatch for {name}: expected {wanted}, got {actual}")

    for name in expected["absent"]:
        path = WORKSPACE / name
        if path.exists() or path.is_symlink():
            failures.append(f"expected absent but found {name}")

    try:
        import numpy

        if numpy.__version__ != expected["numpy_version"]:
            failures.append(
                f"numpy version mismatch: expected {expected['numpy_version']}, got {numpy.__version__}"
            )
        if numpy.array([1, 2, 3]).sum() != 6:
            failures.append("numpy array sum was not 6")
    except Exception as error:
        failures.append(f"numpy check failed: {error}")

    if failures:
        print("fixture verification failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("fixture verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
