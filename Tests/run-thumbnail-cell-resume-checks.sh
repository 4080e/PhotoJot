#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /private/tmp/PhotoJotThumbnailResumeChecks.XXXXXX)
mkdir -p "$check_dir/ThumbnailResumeChecks.app"
xcrun swiftc -parse-as-library -target arm64-apple-ios18.6-simulator -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -module-cache-path "$check_dir/modules" \
  PhotoJot/Thumbnails/ThumbnailKey.swift PhotoJot/Thumbnails/TimelineThumbnailCell.swift Tests/ThumbnailCellResumeChecks.swift -o "$check_dir/ThumbnailResumeChecks.app/ThumbnailResumeChecks"
cat > "$check_dir/ThumbnailResumeChecks.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.photojot.ThumbnailResumeChecks</string>
<key>CFBundleExecutable</key><string>ThumbnailResumeChecks</string>
<key>CFBundleName</key><string>ThumbnailResumeChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>18.6</string>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$check_dir/ThumbnailResumeChecks.app"
xcrun simctl install "$1" "$check_dir/ThumbnailResumeChecks.app"
xcrun simctl launch --console "$1" dev.photojot.ThumbnailResumeChecks > "$check_dir/result.log" 2>&1
cat "$check_dir/result.log"
grep -q "PASS: thumbnail cell resume" "$check_dir/result.log"
