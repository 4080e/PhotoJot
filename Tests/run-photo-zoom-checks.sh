#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /private/tmp/PhotoJotPhotoZoomChecks.XXXXXX)
mkdir -p "$check_dir/PhotoZoomChecks.app"
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
  PhotoJot/Timeline/TimelineController.swift PhotoJot/Viewer/ViewerSession.swift PhotoJot/Viewer/ViewerPagerView.swift PhotoJot/Viewer/ViewerDismissGesture.swift PhotoJot/Viewer/FullPhotoCore.swift PhotoJot/Viewer/FullPhotoImages.swift PhotoJot/Viewer/MediaViewerSource.swift PhotoJot/Viewer/PhotoResolution.swift PhotoJot/Viewer/PhotoZoomView.swift Tests/PhotoZoomChecks.swift -o "$check_dir/PhotoZoomChecks.app/PhotoZoomChecks"
cat > "$check_dir/PhotoZoomChecks.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.photojot.PhotoZoomChecks</string>
<key>CFBundleExecutable</key><string>PhotoZoomChecks</string>
<key>CFBundleName</key><string>PhotoZoomChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>18.6</string>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$check_dir/PhotoZoomChecks.app"
xcrun simctl install "$1" "$check_dir/PhotoZoomChecks.app"
xcrun simctl launch --console "$1" dev.photojot.PhotoZoomChecks > "$check_dir/result.log" 2>&1
cat "$check_dir/result.log"
grep -q "PASS: photo zoom" "$check_dir/result.log"
