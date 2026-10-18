#!/bin/sh
# The Chromium and Firefox extensions are packaged separately, so each ships
# its own copy of the bookmark dry-run module. They must stay identical.
set -e
cd "$(dirname "$0")/.."
if ! cmp -s ChromiumExtension/background/bookmark-plan.js FirefoxExtension/background/bookmark-plan.js; then
  echo "bookmark-plan.js differs between ChromiumExtension and FirefoxExtension" >&2
  exit 1
fi
echo "bookmark-plan.js copies are identical"
