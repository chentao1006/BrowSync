#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="BrowSync"
SCHEME="BrowSync"
APP_NAME="${PROJECT_NAME}.app"
BUILD_DIR="${PROJECT_ROOT}/build/debug"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"
BUILT_APP_PATH="${DERIVED_DATA_DIR}/Build/Products/Debug/${APP_NAME}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
EXCLUSIVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --exclusive)
            EXCLUSIVE=true
            ;;
        -h|--help)
            echo "Usage: ./debug.sh [--exclusive]"
            echo ""
            echo "Builds and launches the local Debug app without installing to /Applications."
            echo "--exclusive unregisters other BrowSync app copies first to reduce duplicate Safari extensions."
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Run ./debug.sh --help for usage."
            exit 1
            ;;
    esac
    shift
done

echo "Stopping running BrowSync..."
pkill -x "${PROJECT_NAME}" 2>/dev/null || true

if [[ "${EXCLUSIVE}" == "true" ]]; then
    echo "Unregistering other BrowSync app copies from Launch Services..."
    while IFS= read -r app_path; do
        if [[ -d "${app_path}" ]]; then
            "${LSREGISTER}" -u "${app_path}" 2>/dev/null || true
        fi
    done < <(
        find /Applications "${HOME}/Library/Developer/Xcode/DerivedData" \
            -name "${APP_NAME}" \
            -type d \
            -prune \
            2>/dev/null
    )
else
    if [[ -d "/Applications/${APP_NAME}" ]]; then
        echo "Note: /Applications/${APP_NAME} exists. Safari may show duplicate extensions."
        echo "Run ./debug.sh --exclusive to unregister other BrowSync copies before launching Debug."
    fi
fi

echo "Syncing Safari extension resources..."
cp "${PROJECT_ROOT}/ChromiumExtension/popup/"* "${PROJECT_ROOT}/BrowSyncExtension/Resources/"
cp "${PROJECT_ROOT}/ChromiumExtension/background/service-worker.js" "${PROJECT_ROOT}/BrowSyncExtension/Resources/background.js"
cp "${PROJECT_ROOT}/ChromiumExtension/content/content-script.js" "${PROJECT_ROOT}/BrowSyncExtension/Resources/content.js"
cp -a "${PROJECT_ROOT}/ChromiumExtension/icons" "${PROJECT_ROOT}/BrowSyncExtension/Resources/"

# Fix icon path for Safari Extension (Xcode flattens the icons folder)
sed -i '' 's|\.\./icons/icon48\.png|icon48.png|g' "${PROJECT_ROOT}/BrowSyncExtension/Resources/popup.html"

echo "Building Debug app..."
xcodebuild \
    -project "${PROJECT_ROOT}/${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "${DERIVED_DATA_DIR}" \
    build

if [[ ! -d "${BUILT_APP_PATH}" ]]; then
    echo "Debug app not found at ${BUILT_APP_PATH}"
    exit 1
fi

echo "Clearing quarantine and registering Debug app..."
xattr -cr "${BUILT_APP_PATH}" 2>/dev/null || true
"${LSREGISTER}" -f -R -trusted "${BUILT_APP_PATH}" 2>/dev/null || true

echo "Launching ${BUILT_APP_PATH}..."
open "${BUILT_APP_PATH}"

echo "Done."
