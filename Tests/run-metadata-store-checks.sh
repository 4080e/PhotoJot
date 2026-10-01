#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /private/tmp/PhotoJotMetadataStoreChecks.XXXXXX)
xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 -disable-sandbox \
  -module-name PhotoJotMigrationChecks -module-cache-path "$check_dir/modules" \
  Tests/Fixtures/Stage2IndexModels.swift Tests/Fixtures/Stage2StoreWriter.swift -o "$check_dir/writer"
"$check_dir/writer" "$check_dir/index.store"
xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 -disable-sandbox \
  -module-name PhotoJotMigrationChecks -module-cache-path "$check_dir/modules" \
  PhotoJot/SMBConnectionSettings.swift PhotoJot/IndexModels.swift PhotoJot/MediaRepository.swift \
  PhotoJot/Metadata/LimitedExifParser.swift PhotoJot/Metadata/LimitedHEIFParser.swift \
  PhotoJot/Metadata/LimitedVideoParser.swift PhotoJot/Metadata/DisplayDateResolver.swift \
  PhotoJot/Metadata/MetadataCore.swift PhotoJot/Metadata/MetadataRepository.swift \
  Tests/MetadataStoreChecks.swift -o "$check_dir/checks"
"$check_dir/checks" "$check_dir/index.store"
