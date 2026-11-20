#!/usr/bin/env python3
"""Fail if release files contain details from the build machine.

Usage: Scripts/check-release-contents.py <file-or-directory>...

Checks every file for:
- code coverage instrumentation, which also embeds full source paths;
- the home folder path (which includes the account name) or the checkout path.

Run it on stripped, exported release files. An unstripped `xcodebuild build`
keeps debug-map entries with source paths, so it always fails this check.
"""
import os
import sys
from pathlib import Path

home = str(Path.home()).encode() + b"/"
checkout = str(Path(__file__).resolve().parent.parent).encode()
needles = {
    home: "a path in the home folder",
    checkout: "the checkout path",
    b"__llvm_prf_cnts": "code coverage instrumentation",
}

if len(sys.argv) < 2:
    sys.exit(__doc__)

problems = []
checked = 0
for root in sys.argv[1:]:
    if os.path.isfile(root):
        paths = [root]
    elif os.path.isdir(root):
        paths = [os.path.join(d, f) for d, _, files in os.walk(root) for f in files]
    else:
        sys.exit(f"error: {root} does not exist")
    for path in paths:
        if os.path.islink(path):
            continue
        with open(path, "rb") as f:
            data = f.read()
        checked += 1
        for needle, description in needles.items():
            if needle in data:
                problems.append(f"{path} contains {description}")

for problem in problems:
    print(f"error: {problem}", file=sys.stderr)
if problems:
    sys.exit(1)
print(f"No build-machine details in {checked} files.")
