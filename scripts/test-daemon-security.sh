#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/browsync-daemon-security.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
swiftc \
  "$repo_root/BrowSync/Core/DaemonConnectionPolicy.swift" \
  "$repo_root/BrowSyncTests/DaemonConnectionPolicyTests.swift" \
  -module-cache-path "$test_dir/module-cache" \
  -o "$test_dir/tests"
"$test_dir/tests"
