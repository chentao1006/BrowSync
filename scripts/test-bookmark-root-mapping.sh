#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_binary="${TMPDIR:-/tmp}/browsync-bookmark-root-mapping-tests"
module_cache="${TMPDIR:-/tmp}/browsync-bookmark-root-mapping-module-cache"

swiftc \
  "$repo_root/BrowSync/Models/Browser.swift" \
  "$repo_root/BrowSync/Models/SyncModels.swift" \
  "$repo_root/BrowSyncTests/BookmarkRootMappingTests.swift" \
  -module-cache-path "$module_cache" \
  -o "$test_binary"

"$test_binary"
