#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /private/tmp/PhotoJotViewerChecks.XXXXXX)
xcrun swiftc PhotoJot/SMBRecovery.swift -parse-as-library -target arm64-apple-macos15.0 -disable-sandbox \
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
  PhotoJot/Viewer/FullPhotoCore.swift PhotoJot/Viewer/FullPhotoImages.swift PhotoJot/Viewer/MediaViewerSource.swift \
  PhotoJot/Viewer/RangePlaybackPolicy.swift PhotoJot/Viewer/MediaPlaybackResource.swift PhotoJot/Viewer/PhotoResolution.swift PhotoJot/Viewer/MediaViewerController.swift \
  Tests/Fixtures/VideoThumbnailFixture.swift Tests/ViewerChecks.swift -o "$check_dir/checks"
"$check_dir/checks" "$check_dir/files"
