#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /private/tmp/PhotoJotViewerPagerChecks.XXXXXX)
mkdir -p "$check_dir/ViewerPagerChecks.app"
xcrun swiftc -parse-as-library -target arm64-apple-ios18.6-simulator -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -module-cache-path "$check_dir/modules" \
  PhotoJot/SMBConnectionSettings.swift PhotoJot/IndexModels.swift PhotoJot/MediaRepository.swift \
  PhotoJot/Metadata/LimitedExifParser.swift PhotoJot/Metadata/LimitedHEIFParser.swift \
  PhotoJot/Metadata/LimitedVideoParser.swift PhotoJot/Metadata/DisplayDateResolver.swift \
  PhotoJot/Metadata/MetadataCore.swift PhotoJot/Metadata/MetadataRepository.swift \
  PhotoJot/Timeline/TimelineDate.swift PhotoJot/Timeline/TimelineRepository.swift \
  PhotoJot/Metadata/MetadataProgress.swift PhotoJot/Update/UpdateCheckpoint.swift PhotoJot/Update/LibraryUpdateController.swift PhotoJot/Settings/ConnectionSettingsController.swift PhotoJot/Thumbnails/ThumbnailKey.swift PhotoJot/Thumbnails/ThumbnailCache.swift \
  PhotoJot/Thumbnails/ThumbnailService.swift PhotoJot/Thumbnails/ThumbnailSession.swift PhotoJot/Thumbnails/ThumbnailMemoryCache.swift \
  PhotoJot/Thumbnails/ThumbnailRepository.swift PhotoJot/Thumbnails/PhotoThumbnailGenerator.swift PhotoJot/Thumbnails/VideoThumbnailGenerator.swift \
  PhotoJot/Thumbnails/RangeThumbnailCore.swift PhotoJot/Thumbnails/RangeThumbnailLoader.swift \
  PhotoJot/Thumbnails/JPEGThumbnailLocator.swift PhotoJot/Thumbnails/ThumbnailImages.swift \
  PhotoJot/Timeline/TimelineController.swift PhotoJot/Viewer/ViewerSession.swift PhotoJot/Viewer/ViewerPagerView.swift Tests/ViewerPagerChecks.swift -o "$check_dir/ViewerPagerChecks.app/ViewerPagerChecks"
cat > "$check_dir/ViewerPagerChecks.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.photojot.ViewerPagerChecks</string>
<key>CFBundleExecutable</key><string>ViewerPagerChecks</string>
<key>CFBundleName</key><string>ViewerPagerChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>18.6</string>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$check_dir/ViewerPagerChecks.app"
xcrun simctl install "$1" "$check_dir/ViewerPagerChecks.app"
xcrun simctl launch --console "$1" dev.photojot.ViewerPagerChecks > "$check_dir/result.log" 2>&1
cat "$check_dir/result.log"
grep -q "PASS: Viewer UIKit paging" "$check_dir/result.log"
