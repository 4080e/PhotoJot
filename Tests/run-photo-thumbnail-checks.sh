#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /private/tmp/PhotoJotPhotoThumbnail.XXXXXX)
xcrun swiftc -parse-as-library -D DEBUG -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos15.0 -module-cache-path "$check_dir/modules" \
  PhotoJot/Thumbnails/ThumbnailKey.swift PhotoJot/Thumbnails/ThumbnailCache.swift \
  PhotoJot/Thumbnails/JPEGThumbnailLocator.swift PhotoJot/Thumbnails/ThumbnailImages.swift \
  PhotoJot/Thumbnails/PhotoThumbnailGenerator.swift Tests/PhotoThumbnailChecks.swift -o "$check_dir/checks"
"$check_dir/checks" "$check_dir/files"
