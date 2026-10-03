#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /private/tmp/PhotoJotViewportChecks.XXXXXX)
mkdir -p "$check_dir/ViewportChecks.app"
xcrun swiftc -parse-as-library -target arm64-apple-ios18.6-simulator -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -module-cache-path "$check_dir/modules" \
  PhotoJot/SMBConnectionSettings.swift PhotoJot/IndexModels.swift PhotoJot/MediaRepository.swift \
  PhotoJot/Metadata/LimitedExifParser.swift PhotoJot/Metadata/LimitedHEIFParser.swift \
  PhotoJot/Metadata/LimitedVideoParser.swift PhotoJot/Metadata/DisplayDateResolver.swift \
  PhotoJot/Metadata/MetadataCore.swift PhotoJot/Metadata/MetadataRepository.swift \
  PhotoJot/Timeline/TimelineDate.swift PhotoJot/Timeline/TimelineRepository.swift \
  PhotoJot/Timeline/TimelineController.swift PhotoJot/Timeline/TimelineGridView.swift Tests/TimelineViewportChecks.swift -o "$check_dir/ViewportChecks.app/ViewportChecks"
cat > "$check_dir/ViewportChecks.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.photojot.ViewportChecks</string>
<key>CFBundleExecutable</key><string>ViewportChecks</string>
<key>CFBundleName</key><string>ViewportChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>18.6</string>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$check_dir/ViewportChecks.app"
xcrun simctl install "$1" "$check_dir/ViewportChecks.app"
xcrun simctl launch --console "$1" dev.photojot.ViewportChecks > "$check_dir/result.log" 2>&1
cat "$check_dir/result.log"
grep -q "PASS: UIKit measured anchor" "$check_dir/result.log"
