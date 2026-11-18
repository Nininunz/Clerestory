#!/bin/bash
#
# make-release.sh builds Clerestory release artifacts and updates the Sparkle appcast.
#
# Usage: ./Scripts/make-release.sh <VERSION> [BUILD] [--adhoc]
#   VERSION sets MARKETING_VERSION, such as 1.0.2.
#   BUILD sets CFBundleVersion for Sparkle. New releases default to the highest
#   published build plus one. Rebuilds can reuse the existing version's build.
#   --adhoc skips Developer ID signing and Apple notarization. Sparkle still signs
#   updates, and Gatekeeper may show an unidentified developer warning on first launch.
#
# Archive with Developer ID, verify app and nested signatures, then build the DMG.
# Sign, notarize, and staple the DMG before signing its final bytes for Sparkle.
#
# Upload export/Clerestory-<VERSION>.dmg to the matching GitHub Release tag
# v<VERSION> separately to make the appcast enclosure available.
#
# Environment variables
#   DEVELOPER_ID_APPLICATION is the full signing identity in Keychain, for example:
#                 Developer ID Application: Example Name (ABCDE12345)
#   DEVELOPMENT_TEAM_ID is the 10-character Apple Developer team ID.
#   NOTARY_PROFILE is the Keychain profile from xcrun notarytool store-credentials.
#   SPARKLE_BIN overrides the directory containing sign_update. The default
#   comes from Xcode's Sparkle package artifacts in DerivedData.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Optional machine-local signing configuration; credentials stay in Keychain.
if [ -f "$REPO_ROOT/Scripts/release-signing.local" ]; then
    source "$REPO_ROOT/Scripts/release-signing.local"
fi

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
    echo "用法：$0 <VERSION> [BUILD] [--adhoc]" >&2
    exit 1
fi
VERSION="$1"
BUILD_NUMBER="${2:-}"
RELEASE_MODE="developer-id"
if [ "${3:-}" = "--adhoc" ]; then
    RELEASE_MODE="adhoc"
elif [ -n "${3:-}" ]; then
    echo "error: 未知参数 ${3}；第三个参数只支持 --adhoc。" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION 必须是三段数字版本号（例如 1.0.2）。" >&2
    exit 1
fi
if [ -n "$BUILD_NUMBER" ] && [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "error: BUILD 必须是正整数。" >&2
    exit 1
fi

PROJECT="Clerestory.xcodeproj"
SCHEME="Clerestory"
ARCHIVE_PATH="export/Clerestory.xcarchive"
APP_PATH="export/Clerestory.app"
DMG_PATH="export/Clerestory-$VERSION.dmg"
APPCAST="docs/appcast.xml"
# Candidate builds keep unpublished update metadata out of the deployable feed.
if [ "${OPENYOINK_RELEASE_CANDIDATE:-0}" = "1" ]; then
    mkdir -p export
    cp "$APPCAST" export/appcast-candidate.xml
    APPCAST="export/appcast-candidate.xml"
fi
RELEASE_URL="https://github.com/Nininunz/Clerestory/releases/download/v$VERSION/Clerestory-$VERSION.dmg"

if ! command -v node >/dev/null 2>&1; then
    echo "error: README 徽章刷新需要 Node.js 18+。请先安装 Node.js。" >&2
    exit 1
fi

if [ "$RELEASE_MODE" = "developer-id" ]; then
    for required_name in DEVELOPER_ID_APPLICATION DEVELOPMENT_TEAM_ID NOTARY_PROFILE; do
        if [ -z "${!required_name:-}" ]; then
            echo "error: 缺少环境变量 ${required_name}。没有 Apple 证书时请显式使用：$0 $VERSION ${BUILD_NUMBER:-<BUILD>} --adhoc" >&2
            exit 1
        fi
    done
    if [[ ! "$DEVELOPMENT_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "error: DEVELOPMENT_TEAM_ID 必须是 10 位大写字母/数字。" >&2
        exit 1
    fi
    CODE_SIGN_IDENTITIES="$(security find-identity -v -p codesigning)"
    case "$CODE_SIGN_IDENTITIES" in
        *"$DEVELOPER_ID_APPLICATION"*) ;;
        *)
            echo "error: 钥匙串中未找到指定的 Developer ID Application 身份。" >&2
            exit 1
            ;;
    esac
else
    echo "==> 发布模式：ad hoc（免费、未公证；首次下载会触发 Gatekeeper 提示）"
fi

# Locate Sparkle's command-line tools.
if [ -z "${SPARKLE_BIN:-}" ]; then
    SPARKLE_BIN=
    for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/{Clerestory,Open-Yoink}-*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
        if [ -x "$candidate/sign_update" ]; then
            SPARKLE_BIN=$candidate
            break
        fi
    done
fi
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
if [ ! -x "$SIGN_UPDATE" ]; then
    echo "error: 未找到 sign_update（试过 SPARKLE_BIN=${SPARKLE_BIN}）。先跑 xcodebuild -resolvePackageDependencies，或设 SPARKLE_BIN。" >&2
    exit 1
fi
echo "==> sign_update: $SIGN_UPDATE"

# Refuse to publish with a different Keychain key than the one trusted by the app.
EXPECTED_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' OpenYoink/App/Info.plist)"
ACTUAL_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account com.nininunz.OpenYoink -p)"
if [ "$EXPECTED_PUBLIC_KEY" != "$ACTUAL_PUBLIC_KEY" ]; then
    echo "error: Fork Sparkle signing key does not match Info.plist." >&2
    exit 1
fi


# Sparkle only offers an update when its build number increases. Default new versions
# to the highest listed build plus one and reject lower or equal explicit builds.
# An existing release version can be rebuilt with its original build number.
MAX_BUILD="$(grep -o '<sparkle:version>[0-9]*' "$APPCAST" 2>/dev/null | grep -o '[0-9]*' | sort -n | tail -1 || true)"
MAX_BUILD="${MAX_BUILD:-51}"
EXISTING_VERSION_BUILD="$(python3 - "$APPCAST" "$VERSION" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

appcast_path, requested_version = sys.argv[1:3]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
try:
    root = ET.parse(appcast_path).getroot()
except (FileNotFoundError, ET.ParseError):
    raise SystemExit(0)
for item in root.findall("./channel/item"):
    short_version = item.find("sparkle:shortVersionString", ns)
    build = item.find("sparkle:version", ns)
    if short_version is not None and short_version.text == requested_version and build is not None:
        print(build.text or "")
        break
PYEOF
)"
if [ -z "${BUILD_NUMBER}" ]; then
    if [ -n "$EXISTING_VERSION_BUILD" ]; then
        BUILD_NUMBER="$EXISTING_VERSION_BUILD"
        echo "==> 重建现有 ${VERSION} item：沿用 build ${BUILD_NUMBER}"
    else
        BUILD_NUMBER=$((MAX_BUILD + 1))
        echo "==> 自动 build number：${BUILD_NUMBER}（appcast 最大 ${MAX_BUILD} + 1）"
    fi
elif [ "${BUILD_NUMBER}" -le "${MAX_BUILD}" ] && [ "$BUILD_NUMBER" != "$EXISTING_VERSION_BUILD" ]; then
    echo "error: BUILD=${BUILD_NUMBER} 不大于 appcast 最大 sparkle:version ${MAX_BUILD} —— 老用户将收不到更新。请传更大值，或省略第二个参数自动递增。" >&2
    exit 1
elif [ "$BUILD_NUMBER" = "$EXISTING_VERSION_BUILD" ]; then
    echo "==> 重建现有 ${VERSION} item：沿用 build ${BUILD_NUMBER}"
fi

# ---- 1. Archive ----
# Always pass the resolved build number explicitly.
VERSION_ARGS=(
    MARKETING_VERSION="$VERSION"
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}"
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    CODE_SIGN_STYLE=Manual
)
if [ "$RELEASE_MODE" = "developer-id" ]; then
    VERSION_ARGS+=(
        CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID"
        OTHER_CODE_SIGN_FLAGS=--timestamp
    )
else
    VERSION_ARGS+=(
        CODE_SIGN_IDENTITY=-
        DEVELOPMENT_TEAM=
        AD_HOC_CODE_SIGNING_ALLOWED=YES
        ENABLE_HARDENED_RUNTIME=NO
    )
fi
echo "==> archive（Release, ${VERSION} (${BUILD_NUMBER})）"
rm -rf "$ARCHIVE_PATH"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    "${VERSION_ARGS[@]}" \
    archive

# Export and verify the Xcode-signed app.
echo "==> 导出 $APP_PATH"
rm -rf "$APP_PATH"
ditto "$ARCHIVE_PATH/Products/Applications/Clerestory.app" "$APP_PATH"

# Sign every nested component explicitly for the selected release mode.
# Ad hoc builds sign the app and nested Sparkle components consistently. Ad hoc
# signatures have no team ID for library validation, so disable hardened runtime
# to let dyld load Sparkle.framework. Preserve each component's identifier and
# entitlements, including those of Sparkle helpers and XPC services.
if [ "$RELEASE_MODE" = "adhoc" ]; then
    # Sign nested components from the leaves inward. Using --deep to sign can copy
    # the app's entitlements to Installer and Updater and prevent installation, as
    # observed in 1.0.1.
    SPARKLE_ROOT="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
    MEDIA_ROOT="$APP_PATH/Contents/Resources/MediaRemoteAdapterResources.bundle"
    for component in \
        "$MEDIA_ROOT/Contents/Resources/MediaRemoteAdapterTestClient" \
        "$MEDIA_ROOT/Contents/Resources/MediaRemoteAdapter.framework" \
        "$MEDIA_ROOT" \
        "$SPARKLE_ROOT/XPCServices/Installer.xpc" \
        "$SPARKLE_ROOT/XPCServices/Downloader.xpc" \
        "$SPARKLE_ROOT/Autoupdate" \
        "$SPARKLE_ROOT/Updater.app" \
        "$APP_PATH/Contents/Frameworks/Sparkle.framework" \
        "$APP_PATH"; do
        codesign --force --sign - \
            --preserve-metadata=identifier,entitlements \
            "$component"
    done
else
    # Xcode signs the embedded framework but may leave prebuilt nested helpers
    # ad-hoc signed. Sign from the inside out, retaining each helper's own
    # identifier and entitlements; never propagate the main app's sandbox.
    SPARKLE_ROOT="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
    MEDIA_ROOT="$APP_PATH/Contents/Resources/MediaRemoteAdapterResources.bundle"
    for component in \
        "$MEDIA_ROOT/Contents/Resources/MediaRemoteAdapterTestClient" \
        "$MEDIA_ROOT/Contents/Resources/MediaRemoteAdapter.framework" \
        "$MEDIA_ROOT" \
        "$SPARKLE_ROOT/XPCServices/Installer.xpc" \
        "$SPARKLE_ROOT/XPCServices/Downloader.xpc" \
        "$SPARKLE_ROOT/Autoupdate" \
        "$SPARKLE_ROOT/Updater.app" \
        "$APP_PATH/Contents/Frameworks/Sparkle.framework" \
        "$APP_PATH"; do
        codesign --force --sign "$DEVELOPER_ID_APPLICATION" \
            --options runtime --timestamp \
            --preserve-metadata=identifier,entitlements "$component"
    done
fi
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
echo "    shortVersionString=$SHORT_VERSION  bundleVersion=$BUNDLE_VERSION"
if [ "$SHORT_VERSION" != "$VERSION" ] || [ "$BUNDLE_VERSION" != "$BUILD_NUMBER" ]; then
    echo "error: 归档内版本与请求不一致（期望 $VERSION ($BUILD_NUMBER)），拒绝发布。" >&2
    exit 1
fi

./Scripts/verify-distribution.sh "$APP_PATH" "$RELEASE_MODE" "$VERSION" "$BUILD_NUMBER"

if [ "$RELEASE_MODE" = "developer-id" ]; then
    APP_SIGN_INFO="$(codesign -dvvv "$APP_PATH" 2>&1)"
    if ! printf '%s\n' "$APP_SIGN_INFO" | grep -Eq 'flags=.*runtime'; then
        echo "error: 导出的 app 未启用 Hardened Runtime，拒绝 Developer ID 发布。" >&2
        exit 1
    fi
    if ! printf '%s\n' "$APP_SIGN_INFO" | grep -Fq "TeamIdentifier=$DEVELOPMENT_TEAM_ID"; then
        echo "error: app 的 TeamIdentifier 与 DEVELOPMENT_TEAM_ID 不一致。" >&2
        exit 1
    fi
fi

# ---- 3. DMG ----
echo "==> 打 DMG"
./Scripts/make-dmg.sh "$APP_PATH"

# Sign, notarize, and staple the DMG for Developer ID distribution.
if [ "$RELEASE_MODE" = "developer-id" ]; then
    echo "==> Developer ID 签名 DMG"
    codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG_PATH"
    NOTARY_PROFILE="$NOTARY_PROFILE" ./Scripts/notarize.sh "$DMG_PATH"
else
    echo "==> 跳过 Apple 公证（ad hoc 模式）"
fi

# Create the EdDSA signature after notarization and stapling finalize the DMG bytes.
echo "==> sign_update"
SIGN_OUTPUT="$("$SIGN_UPDATE" --account com.nininunz.OpenYoink "$DMG_PATH")"
echo "    $SIGN_OUTPUT"
# Expected output includes sparkle:edSignature and length attributes.
ED_SIGNATURE="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
DMG_LENGTH="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
if [ -z "$ED_SIGNATURE" ] || [ -z "$DMG_LENGTH" ]; then
    echo "error: 无法从 sign_update 输出解析签名/长度" >&2
    exit 1
fi

PUB_DATE="$(LC_TIME=C date '+%a, %d %b %Y %H:%M:%S %z')"

# Update the appcast, replacing any existing entry with the same marketing version.
# Leave sparkle:channel off the item. The app uses the default channel, which
# filters out explicitly tagged entries. This prevented update discovery in 1.0.1.
echo "==> 更新 $APPCAST"
python3 - "$APPCAST" "$VERSION" "$SHORT_VERSION" "$BUNDLE_VERSION" "$RELEASE_URL" "$ED_SIGNATURE" "$DMG_LENGTH" "$PUB_DATE" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

(appcast_path, version, short_version, bundle_version,
 url, ed_signature, dmg_length, pub_date) = sys.argv[1:9]

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

tree = ET.parse(appcast_path, parser=ET.XMLParser(target=ET.TreeBuilder(insert_comments=True)))
channel = tree.getroot().find("channel")

# Remove any previous entry for this marketing version.
for item in list(channel.findall("item")):
    svs = item.find(f"{{{SPARKLE}}}shortVersionString")
    if svs is not None and svs.text == short_version:
        channel.remove(item)
        print(f"    替换已存在的 {short_version} item")

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Version {short_version}"
ET.SubElement(item, "pubDate").text = pub_date
ET.SubElement(item, f"{{{SPARKLE}}}version").text = bundle_version
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = short_version
ET.SubElement(item, "enclosure", {
    "url": url,
    f"{{{SPARKLE}}}edSignature": ed_signature,
    "length": dmg_length,
    "type": "application/octet-stream",
})

# Insert the new item before the first existing release entry.
insert_at = 0
for idx, child in enumerate(list(channel)):
    if child.tag == "item":
        insert_at = idx
        break
else:
    insert_at = len(list(channel))
channel.insert(insert_at, item)

ET.indent(tree, space="    ")
tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
print(f"    appcast 已更新：{short_version} ({bundle_version})")
PYEOF

# Refresh the local README badge snapshots.
echo "==> 更新 README 徽章"
if [ "${OPENYOINK_RELEASE_CANDIDATE:-0}" != "1" ]; then
    node "$REPO_ROOT/Scripts/update-readme-badges.mjs" --version "$SHORT_VERSION"
else
    echo "Candidate build: skipping public release badges."
fi

# Print Homebrew cask metadata for use after upload, when the download URL works.
# Use the hash of this exact notarized DMG. Rebuilding changes timestamped signatures
# and therefore the digest.
DMG_SHA="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
echo "==> Homebrew cask：version=$SHORT_VERSION  sha256=$DMG_SHA"
echo "    GitHub Release 上传成功后，用以上两个值更新 homebrew-tap。"

echo ""
echo "==> 完成"
echo "    DMG:     $DMG_PATH"
echo "    appcast: $APPCAST"
echo "    mode:    $RELEASE_MODE"
if [ "${OPENYOINK_RELEASE_CANDIDATE:-0}" = "1" ]; then
    echo "Local candidate only. Public feed and badges are unchanged; nothing was published."
else
    echo "    badges:  docs/badges/"
    echo "Review and commit the feed and badges only when the matching release is ready."
    echo "No GitHub release has been created by this script."
fi
