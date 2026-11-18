#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/clerestory-shelf-volume.XXXXXX")
volume="ClerestoryShelfSafety-${work_dir##*.}"
mountpoint="/Volumes/$volume"
image="$work_dir/disposable.dmg"

cleanup() {
    if mount | grep -Fq " on $mountpoint ("; then
        if ! hdiutil detach "$mountpoint" >/dev/null; then
            printf 'Could not eject the disposable volume. Image retained at %s\n' "$image" >&2
            return 1
        fi
    fi
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

cat > "$work_dir/Probe.swift" <<'SWIFT'
import Foundation

@main
struct ShelfVolumeProbe {
    static func require(_ condition: Bool, _ message: String) {
        guard !condition else { return }
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        let snapshot = URL(fileURLWithPath: arguments[2])
        let original = URL(fileURLWithPath: arguments[3]).appendingPathComponent("sample.txt")
        let bookmarks = BookmarkService()
        let contents = Data("Disposable Shelf volume fixture\n".utf8)

        if arguments[1] == "seed" {
            try contents.write(to: original)
            let item = ShelfItem(
                kind: .file,
                path: original.path,
                bookmark: try bookmarks.createBookmark(for: original),
                displayName: original.lastPathComponent
            )
            try JSONEncoder().encode(item).write(to: snapshot)
            return
        }

        let stored = try JSONDecoder().decode(ShelfItem.self, from: Data(contentsOf: snapshot))
        let refreshed = ItemAvailabilityResolver.refresh(stored, bookmarkService: bookmarks)
        if arguments[1] == "offline" {
            require(refreshed.item.availability == .externalFileOffline, "ejected original should be unavailable")
            require(!refreshed.requiresPersistence, "offline check should preserve the saved reference")
            return
        }

        require(refreshed.item.availability == .available, "reconnected original should be available")
        require(refreshed.item.id == stored.id, "reconnect should preserve the Shelf item")
        let url = try bookmarks.resolveFileURL(original, bookmark: refreshed.item.bookmark)
        let recovered = try bookmarks.withSecurityScopedAccess(to: url) { try Data(contentsOf: url) }
        require(recovered == contents, "reconnected original should contain the same bytes")
    }
}
SWIFT

xcrun swiftc -module-cache-path "$work_dir/module-cache" \
    Clerestory/Model/ItemAvailability.swift Clerestory/Model/ItemKind.swift \
    Clerestory/Model/ShelfItem.swift Clerestory/Model/SourceAppInfo.swift \
    Clerestory/Services/BookmarkService.swift "$work_dir/Probe.swift" -o "$work_dir/probe"

hdiutil create -quiet -size 100m -fs APFS -volname "$volume" "$image"
hdiutil attach -quiet -nobrowse "$image"
"$work_dir/probe" seed "$work_dir/shelf.json" "$mountpoint"
hdiutil detach -quiet "$mountpoint"
"$work_dir/probe" offline "$work_dir/shelf.json" "$mountpoint"
if mount | grep -Fq " on $mountpoint ("; then
    printf '%s\n' 'FAIL: availability refresh remounted the ejected volume' >&2
    exit 1
fi
printf '%s\n' 'PASS: the ejected original stays unavailable in a fresh process'

hdiutil attach -quiet -nobrowse "$image"
"$work_dir/probe" online "$work_dir/shelf.json" "$mountpoint"
printf '%s\n' 'PASS: reattaching restores access to the same saved original'
