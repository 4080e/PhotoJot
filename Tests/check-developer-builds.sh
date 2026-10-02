#!/bin/sh
set -eu
# 署名なしでも検査可能。Debug/ReleaseのiOS app実行ファイルを渡す。
debug_binary="$1"
release_binary="$2"
check_dir=$(mktemp -d /private/tmp/PhotoJotDeveloperBuildChecks.XXXXXX)
xcrun nm "$debug_binary" > "$check_dir/debug-symbols"
xcrun nm "$release_binary" > "$check_dir/release-symbols"
strings "$debug_binary" > "$check_dir/debug-strings"
strings "$release_binary" > "$check_dir/release-strings"
for symbol in DeveloperToolsView DeveloperMediaDetailsView; do
    rg -q "$symbol" "$check_dir/debug-symbols"
    if rg -q "$symbol" "$check_dir/release-symbols"; then
        echo "FAIL: $symbol exists in Release"
        exit 1
    fi
done
rg -q 'Developer Tools' "$check_dir/debug-strings"
if rg -q 'Developer Tools' "$check_dir/release-strings"; then
    echo 'FAIL: Developer Tools entry exists in Release'
    exit 1
fi
echo 'PASS: Debug developer views and entry present; Release developer views and entry absent'
