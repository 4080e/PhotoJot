#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /private/tmp/PhotoJotViewerCore.XXXXXX)
xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 -module-cache-path "$check_dir/modules" \
 PhotoJot/Viewer/FullPhotoCore.swift PhotoJot/Viewer/FullPhotoImages.swift \
 PhotoJot/Thumbnails/PhotoThumbnailGenerator.swift PhotoJot/Thumbnails/JPEGThumbnailLocator.swift \
 PhotoJot/Thumbnails/ThumbnailImages.swift Tests/FullPhotoChecks.swift -o "$check_dir/photo"
"$check_dir/photo"
xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 -module-cache-path "$check_dir/modules" \
 PhotoJot/Thumbnails/RangeThumbnailCore.swift PhotoJot/Thumbnails/RangeThumbnailLoader.swift \
 PhotoJot/Viewer/RangePlaybackPolicy.swift Tests/RangePlaybackLoaderChecks.swift -o "$check_dir/video"
"$check_dir/video"
