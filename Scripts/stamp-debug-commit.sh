#!/bin/sh
set -eu

mkdir -p "$DERIVED_FILE_DIR"
stamp="$DERIVED_FILE_DIR/SourceCommit.txt"
commit=
if [ "$CONFIGURATION" = Debug ] && [ -e "$SRCROOT/.git" ]; then
    commit=$(/usr/bin/git -C "$SRCROOT" rev-parse --short=7 HEAD 2>/dev/null) || commit=
fi
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$commit" ]; then
    exit 0
fi
printf '%s' "$commit" > "$stamp"
