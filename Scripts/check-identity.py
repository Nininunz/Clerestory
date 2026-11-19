#!/usr/bin/env python3
"""Check release ownership without downloading updates or accessing private keys."""
import base64
import pathlib
import plistlib
import re
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parent.parent
info = plistlib.loads((root / "Clerestory/App/Info.plist").read_bytes())
feed_url = "https://nininunz.github.io/Clerestory/appcast.xml"
assert info["SUFeedURL"] == feed_url
assert len(base64.b64decode(info["SUPublicEDKey"], validate=True)) == 32
assert info["SUPublicEDKey"] != "fjAcTFLXwbNHK8rgG6ecCzWjZIDZc/BKo0AFAYVW968="

project = (root / "Clerestory.xcodeproj/project.pbxproj").read_text()
identifiers = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", project)
assert set(identifiers) == {
    "com.nininunz.Clerestory",
    "com.nininunz.ClerestoryTests",
    "com.nininunz.ClerestoryUITests",
    "com.nininunz.ClerestoryUITestDragSource",
}
feed = ET.parse(root / "docs/appcast.xml")
assert feed.findtext("./channel/link") == feed_url
for enclosure in feed.findall("./channel/item/enclosure"):
    assert enclosure.attrib["url"].startswith("https://github.com/Nininunz/Clerestory/releases/download/")

for file in ["Clerestory/Services/UpdateController.swift", "Clerestory/Services/SupportController.swift",
             "Scripts/make-release.sh", "Scripts/verify-update-feed.sh"]:
    contents = (root / file).read_text()
    assert "MuQY1818" not in contents and "muqy1818.github.io" not in contents, file
release = (root / "Scripts/make-release.sh").read_text()
assert '"$SIGN_UPDATE" --account com.nininunz.OpenYoink' in release
assert '"$SPARKLE_BIN/generate_keys" --account com.nininunz.OpenYoink -p' in release
assert (root / "Clerestory/Resources/Clerestory-LICENSE.txt").read_bytes() == (root / "LICENSE").read_bytes()
print("App identity, signing-account selection, and update ownership checks passed.")
