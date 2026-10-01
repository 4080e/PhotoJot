#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /private/tmp/PhotoJotStage3Checks.XXXXXX)
for check in LimitedMetadataChecks VideoMetadataChecks DisplayDateChecks MetadataCoreChecks; do
  xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 -disable-sandbox \
    -module-cache-path "$check_dir/modules" \
    PhotoJot/Metadata/LimitedExifParser.swift PhotoJot/Metadata/LimitedHEIFParser.swift \
    PhotoJot/Metadata/LimitedVideoParser.swift PhotoJot/Metadata/DisplayDateResolver.swift \
    PhotoJot/Metadata/MetadataCore.swift "Tests/$check.swift" -o "$check_dir/$check"
  "$check_dir/$check"
done
