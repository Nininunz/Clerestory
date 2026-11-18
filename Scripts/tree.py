#!/usr/bin/env python3
"""Print the checkout layout, respecting Git's ignore rules."""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", default=".", help="file or directory relative to the repository root")
    parser.add_argument("--depth", type=int, help="maximum levels below the selected path (minimum 1)")
    args = parser.parse_args()
    if args.depth is not None and args.depth < 1:
        parser.error("--depth must be at least 1")

    root = Path(__file__).resolve().parent.parent
    scope = PurePosixPath(os.path.normpath(args.path))
    if scope.is_absolute() or scope.parts[:1] == ("..",):
        parser.error("path must be relative to the repository root and stay inside it")

    result = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root,
        stdout=subprocess.PIPE,
    )
    if result.returncode:
        return result.returncode

    paths = set()
    for entry in result.stdout.split(b"\0"):
        if not entry:
            continue
        path = PurePosixPath(os.fsdecode(entry))
        if os.path.lexists(root / path):
            paths.add(path)
            paths.update(parent for parent in path.parents if parent.parts)

    if scope.parts and scope not in paths:
        parser.error(f"path has no visible entries: {scope.as_posix()!r}")

    for path in sorted(paths):
        if path != scope and scope not in path.parents:
            continue
        if args.depth is not None and len(path.parts) - len(scope.parts) > args.depth:
            continue
        name = path.as_posix()
        print(name if name.isprintable() else json.dumps(name))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
