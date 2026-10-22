#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /private/tmp/PhotoJotVideoThumbnail.XXXXXX)
xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 -module-cache-path "$check_dir/modules" \
  PhotoJot/Thumbnails/RangeThumbnailCore.swift Tests/RangeThumbnailChecks.swift -o "$check_dir/core"
"$check_dir/core"
xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 -module-cache-path "$check_dir/modules" \
  PhotoJot/Thumbnails/RangeThumbnailCore.swift PhotoJot/Thumbnails/RangeThumbnailLoader.swift \
  Tests/RangeThumbnailLoaderChecks.swift -o "$check_dir/loader"
"$check_dir/loader"
xcrun swiftc -parse-as-library -D DEBUG PhotoJot/Developer/SMBDiagnostics.swift -target arm64-apple-macos15.0 -module-cache-path "$check_dir/modules" \
  PhotoJot/Thumbnails/RangeThumbnailCore.swift PhotoJot/Thumbnails/RangeThumbnailLoader.swift \
  PhotoJot/Thumbnails/VideoThumbnailGenerator.swift PhotoJot/Thumbnails/PhotoThumbnailGenerator.swift \
  PhotoJot/Thumbnails/JPEGThumbnailLocator.swift PhotoJot/Thumbnails/ThumbnailImages.swift \
  PhotoJot/Thumbnails/ThumbnailKey.swift PhotoJot/Thumbnails/ThumbnailCache.swift \
  PhotoJot/Thumbnails/ThumbnailService.swift PhotoJot/Thumbnails/ThumbnailMemoryCache.swift \
  Tests/Fixtures/VideoThumbnailFixture.swift Tests/VideoThumbnailChecks.swift -o "$check_dir/video"
"$check_dir/video" "$check_dir/files"
