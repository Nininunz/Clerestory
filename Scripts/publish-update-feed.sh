#!/bin/bash
# Publish the merged appcast to the account-owned Pages site.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

pages_file="repos/Nininunz/nininunz.github.io/contents/OpenYoink/appcast.xml"
feed_url="https://nininunz.github.io/OpenYoink/appcast.xml"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

git fetch origin main
git show FETCH_HEAD:docs/appcast.xml > "$work_dir/appcast.xml"
gh api "$pages_file?ref=main" > "$work_dir/remote.json"

python3 - "$work_dir" <<'PY'
from pathlib import Path
import base64
import json
import sys
import xml.etree.ElementTree as ET

work = Path(sys.argv[1])
remote = json.loads((work / "remote.json").read_text())
previous = base64.b64decode(remote["content"])
candidate = (work / "appcast.xml").read_bytes()
if previous == candidate:
    print("The account Pages repository already has this appcast.")
    sys.exit(0)

def latest_build(data):
    namespaces = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    root = ET.fromstring(data)
    return int(root.findtext("./channel/item/sparkle:version", namespaces=namespaces))

build = latest_build(candidate)
if build <= latest_build(previous):
    raise SystemExit("Refusing to replace the published appcast with an older or equal build.")

payload = {
    "message": f"Publish Clerestory update build {build}",
    "content": base64.b64encode(candidate).decode("ascii"),
    "sha": remote["sha"],
    "branch": "main",
}
(work / "payload.json").write_text(json.dumps(payload))
PY

if [[ -f "$work_dir/payload.json" ]]; then
    Scripts/verify-update-feed.sh "$work_dir/appcast.xml"
    gh api --method PUT "$pages_file" --input "$work_dir/payload.json" --jq '.commit.html_url'
fi

# Check the deployed bytes because the Pages build can lag behind the commit.
for attempt in {1..24}; do
    if curl --fail --silent --show-error --max-time 10 \
        "$feed_url?verify=$(git hash-object "$work_dir/appcast.xml")-$attempt" \
        -o "$work_dir/live.xml" && cmp -s "$work_dir/appcast.xml" "$work_dir/live.xml"; then
        echo "Verified deployed appcast at $feed_url"
        exit 0
    fi
    sleep 5
done

echo "The account Pages commit exists, but the matching feed was not observed yet." >&2
exit 1
