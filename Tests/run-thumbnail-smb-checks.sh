#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /private/tmp/PhotoJotThumbnailSMB.XXXXXX)
xcrun swiftc -emit-library -emit-module -module-name SMBClient \
  -target arm64-apple-macos15.0 -module-cache-path "$check_dir/modules" \
  Tests/Fixtures/ThumbnailSMBClient.swift -emit-module-path "$check_dir/SMBClient.swiftmodule" -o "$check_dir/libSMBClient.dylib"
xcrun swiftc -parse-as-library -D DEBUG -I "$check_dir" -L "$check_dir" -lSMBClient -Xlinker -rpath -Xlinker "$check_dir" -target arm64-apple-macos15.0 -disable-sandbox \
  -module-cache-path "$check_dir/modules" \
  PhotoJot/SMBConnectionSettings.swift PhotoJot/IndexModels.swift PhotoJot/MediaRepository.swift \
  PhotoJot/Metadata/LimitedExifParser.swift PhotoJot/Metadata/LimitedHEIFParser.swift \
  PhotoJot/Metadata/LimitedVideoParser.swift PhotoJot/Metadata/DisplayDateResolver.swift \
  PhotoJot/Metadata/MetadataCore.swift PhotoJot/Metadata/MetadataRepository.swift \
  PhotoJot/Timeline/TimelineDate.swift PhotoJot/Timeline/TimelineRepository.swift PhotoJot/Timeline/TimelineController.swift \
  PhotoJot/Metadata/MetadataProgress.swift PhotoJot/Update/UpdateCheckpoint.swift PhotoJot/Update/LibraryUpdateController.swift PhotoJot/Settings/ConnectionSettingsController.swift PhotoJot/Thumbnails/ThumbnailKey.swift PhotoJot/Thumbnails/ThumbnailCache.swift \
  PhotoJot/Thumbnails/ThumbnailService.swift PhotoJot/Thumbnails/ThumbnailSession.swift PhotoJot/Thumbnails/ThumbnailMemoryCache.swift \
  PhotoJot/Thumbnails/ThumbnailRepository.swift PhotoJot/Thumbnails/PhotoThumbnailGenerator.swift PhotoJot/Thumbnails/VideoThumbnailGenerator.swift \
  PhotoJot/Thumbnails/RangeThumbnailCore.swift PhotoJot/Thumbnails/RangeThumbnailLoader.swift \
  PhotoJot/Thumbnails/JPEGThumbnailLocator.swift PhotoJot/Thumbnails/ThumbnailImages.swift \
  PhotoJot/SMBAccessCoordinator.swift PhotoJot/SMBOperationGate.swift PhotoJot/Metadata/SMBMetadataSource.swift Tests/Fixtures/VideoThumbnailFixture.swift Tests/ThumbnailSMBChecks.swift -o "$check_dir/checks"
"$check_dir/checks" "$check_dir/files"
