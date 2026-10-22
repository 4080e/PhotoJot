#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /private/tmp/PhotoJotConnectionChecks.XXXXXX)
xcrun swiftc PhotoJot/SMBRecovery.swift -parse-as-library -target arm64-apple-macos15.0 -disable-sandbox \
  -module-cache-path "$check_dir/modules" \
  PhotoJot/SMBConnectionSettings.swift PhotoJot/IndexModels.swift PhotoJot/MediaRepository.swift \
  PhotoJot/Metadata/LimitedExifParser.swift PhotoJot/Metadata/LimitedHEIFParser.swift \
  PhotoJot/Metadata/LimitedVideoParser.swift PhotoJot/Metadata/DisplayDateResolver.swift \
  PhotoJot/Metadata/MetadataCore.swift PhotoJot/Metadata/MetadataRepository.swift \
  PhotoJot/Timeline/TimelineDate.swift PhotoJot/Timeline/TimelineRepository.swift PhotoJot/Timeline/TimelineController.swift \
  PhotoJot/Metadata/MetadataProgress.swift PhotoJot/Update/UpdateCheckpoint.swift PhotoJot/Update/LibraryUpdateController.swift PhotoJot/Settings/ConnectionSettingsController.swift Tests/ConnectionFlowChecks.swift -o "$check_dir/checks"
"$check_dir/checks" "$check_dir/index.store"
