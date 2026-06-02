#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${BREW_BIN:-}" ]; then
    BREW_BIN="$BREW_BIN"
elif [ -x "/opt/homebrew/bin/brew" ]; then
    BREW_BIN="/opt/homebrew/bin/brew"
else
    BREW_BIN="$(command -v brew || true)"
fi
GH_BIN="${GH_BIN:-$(command -v gh || true)}"

APP_NAME="${APP_NAME:-BrowSync}"
CASK_TOKEN="${CASK_TOKEN:-browsync}"
BUNDLE_ID="${BUNDLE_ID:-com.ct106.browsync}"
TAP_OWNER="${TAP_OWNER:-chentao1006}"
TAP_REPO="${TAP_REPO:-homebrew-tap}"
TAP_NAME="${TAP_NAME:-tap}"
SOURCE_REPO="${SOURCE_REPO:-chentao1006/browsync}"
DMG_ASSET_NAME="${DMG_ASSET_NAME:-BrowSync.dmg}"
if [ -n "$BREW_BIN" ]; then
    HOMEBREW_REPO="$("$BREW_BIN" --repository 2>/dev/null || true)"
else
    HOMEBREW_REPO=""
fi
DEFAULT_TAP_DIR="${HOMEBREW_REPO}/Library/Taps/${TAP_OWNER}/homebrew-${TAP_NAME}"
if [ -z "$HOMEBREW_REPO" ]; then
    DEFAULT_TAP_DIR="${ROOT_DIR}/../${TAP_REPO}"
fi
TAP_DIR="${TAP_DIR:-$DEFAULT_TAP_DIR}"
RUN_BREW_STYLE="${RUN_BREW_STYLE:-1}"
RUN_BREW_AUDIT="${RUN_BREW_AUDIT:-0}"
SKIP_BREW_PUSH="${SKIP_BREW_PUSH:-0}"

usage() {
    cat <<EOF
Usage: $0 <dmg-path> <version>
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

DMG_PATH="${1:-}"
VERSION="${2:-}"

if [ -z "$DMG_PATH" ] || [ -z "$VERSION" ]; then
    usage
    exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "Error: DMG not found: $DMG_PATH"
    exit 1
fi

if [ -z "$BREW_BIN" ]; then
    echo "Error: brew not found."
    exit 1
fi

TAG_NAME="v${VERSION}"
DOWNLOAD_URL="https://github.com/${SOURCE_REPO}/releases/download/${TAG_NAME}/${DMG_ASSET_NAME}"
SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
TAP_REMOTE="${TAP_REMOTE:-https://github.com/${TAP_OWNER}/${TAP_REPO}.git}"

echo "================================================="
echo "  Updating Homebrew tap"
echo "================================================="

ensure_remote_repo() {
    if git ls-remote "$TAP_REMOTE" HEAD >/dev/null 2>&1; then return; fi
    "$GH_BIN" repo create "${TAP_OWNER}/${TAP_REPO}" --public --description "Homebrew tap for apps by ${TAP_OWNER}" --clone=false
}

set_tap_origin() {
    if git -C "$TAP_DIR" remote get-url origin >/dev/null 2>&1; then
        git -C "$TAP_DIR" remote set-url origin "$TAP_REMOTE"
    else
        git -C "$TAP_DIR" remote add origin "$TAP_REMOTE"
    fi
}

ensure_tap_repo() {
    if [ -d "$TAP_DIR/.git" ]; then
        git -C "$TAP_DIR" checkout main || git -C "$TAP_DIR" checkout -B main
        if [ "$SKIP_BREW_PUSH" != "1" ]; then
            ensure_remote_repo
            set_tap_origin
            git -C "$TAP_DIR" fetch origin || true
            git -C "$TAP_DIR" pull --ff-only origin main || true
        fi
        return
    fi
    if git ls-remote "$TAP_REMOTE" HEAD >/dev/null 2>&1; then
        git clone "$TAP_REMOTE" "$TAP_DIR"
        return
    fi
    ensure_remote_repo
    git clone "$TAP_REMOTE" "$TAP_DIR"
}

ensure_local_brew_tap() {
    local current_tap_dir
    current_tap_dir="$("$BREW_BIN" --repo "${TAP_OWNER}/${TAP_NAME}" 2>/dev/null || true)"
    if [ "$current_tap_dir" = "$TAP_DIR" ]; then return; fi
    if "$BREW_BIN" tap | grep -qx "${TAP_OWNER}/${TAP_NAME}"; then
        "$BREW_BIN" untap "${TAP_OWNER}/${TAP_NAME}"
    fi
    "$BREW_BIN" tap "${TAP_OWNER}/${TAP_NAME}" "$TAP_DIR"
}

write_tap_files() {
    mkdir -p "$TAP_DIR/Casks"
    cat >"$TAP_DIR/Casks/${CASK_TOKEN}.rb" <<EOF
cask "$CASK_TOKEN" do
  version "$VERSION"
  sha256 "$SHA256"

  url "$DOWNLOAD_URL"
  name "$APP_NAME"
  desc "Unified browsing experience across multiple browsers"
  homepage "https://github.com/$SOURCE_REPO"

  depends_on macos: :sonoma

  app "$APP_NAME.app"

  zap trash: [
    "~/Library/Application Support/$APP_NAME",
    "~/Library/Caches/$BUNDLE_ID",
    "~/Library/HTTPStorages/$BUNDLE_ID",
    "~/Library/Preferences/$BUNDLE_ID.plist",
    "~/Library/Saved Application State/$BUNDLE_ID.savedState",
  ]
end
EOF

    # Since there are multiple casks, we should really append or keep the README generic if it's there.
    # The original script just overwrites it. I will keep it simple.
}

run_brew_checks() {
    if [ "$RUN_BREW_STYLE" != "1" ] && [ "$RUN_BREW_AUDIT" != "1" ]; then return; fi
    ensure_local_brew_tap
    if [ "$RUN_BREW_STYLE" = "1" ]; then "$BREW_BIN" style --cask "${TAP_OWNER}/${TAP_NAME}/${CASK_TOKEN}"; fi
    if [ "$RUN_BREW_AUDIT" = "1" ]; then "$BREW_BIN" audit --cask --new "${TAP_OWNER}/${TAP_NAME}/${CASK_TOKEN}" || true; fi
}

commit_and_push() {
    git -C "$TAP_DIR" add "Casks/${CASK_TOKEN}.rb"
    if git -C "$TAP_DIR" diff --cached --quiet; then
        echo "No Homebrew tap changes to commit."
    else
        git -C "$TAP_DIR" commit -m "Update ${CASK_TOKEN} to ${VERSION}"
    fi
    if [ "$SKIP_BREW_PUSH" = "1" ]; then return; fi
    ensure_remote_repo
    set_tap_origin
    git -C "$TAP_DIR" push origin main
}

ensure_tap_repo
write_tap_files
run_brew_checks
commit_and_push
