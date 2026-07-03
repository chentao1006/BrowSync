#!/bin/bash

# Stop on error
set -e

# Project root directory
PROJECT_ROOT="."
BUILD_DIR="${PROJECT_ROOT}/build"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"
APP_NAME="BrowSync.app"
BUILT_APP_PATH="${DERIVED_DATA_DIR}/Build/Products/Release/${APP_NAME}"
BUNDLE_ID="com.ct106.browsync"
INSTALL_PATH="/Applications/${APP_NAME}"

echo "🚀 Starting build for ${APP_NAME}..."

# 1. Clean old build files
if [ -d "${BUILD_DIR}" ]; then
    echo "🧹 Cleaning old build directory... (Skipped for debugging)"
    # rm -rf "${BUILD_DIR}"
fi

# 2. Run compilation
echo "🏗️ Compiling Release version..."
xcodebuild -project "${PROJECT_ROOT}/BrowSync.xcodeproj" \
           -scheme "BrowSync" \
           -configuration "Release" \
           -destination "platform=macOS,arch=arm64" \
           -derivedDataPath "${DERIVED_DATA_DIR}" \
           SWIFT_ACTIVE_COMPILATION_CONDITIONS="\$(inherited) LOCAL_PRO_TEST" \
           build > /dev/null

if [ $? -eq 0 ]; then
    echo "✅ Compilation successful!"
else
    echo "❌ Compilation failed, please check errors."
    exit 1
fi

# 3. Check generated App
if [ ! -d "${BUILT_APP_PATH}" ]; then
    echo "❌ ${APP_NAME} not found in build directory"
    exit 1
fi

# 4. Move to /Applications
echo "📦 Installing to system Applications folder (${INSTALL_PATH})..."

# Terminate running instance if any
echo "🛑 Stopping any running instance of BrowSync..."
pkill -x "BrowSync" || true

# Wait for process to disappear
MAX_RETRIES=10
RETRY=0
while pgrep -x "BrowSync" > /dev/null && [ $RETRY -lt $MAX_RETRIES ]; do
    echo "⏳ Waiting for BrowSync to stop... ($RETRY/$MAX_RETRIES)"
    sleep 0.5
    RETRY=$((RETRY+1))
done

# If already exists, remove first
if [ -d "${INSTALL_PATH}" ]; then
    echo "♻️ Replacing old version..."
    rm -rf "${INSTALL_PATH}"
fi

# Reset accessibility permissions if needed (BrowSync might not need it, but good to have)
# echo "🔐 Resetting Accessibility permissions..."
# tccutil reset Accessibility "${BUNDLE_ID}" || true

cp -R "${BUILT_APP_PATH}" "${INSTALL_PATH}"

# Clear quarantine and fix permissions for local testing
xattr -cr "${INSTALL_PATH}"

echo "🚀 Launching ${APP_NAME}..."
# Give Launch Services a moment to register the new bundle
sleep 1
echo "📝 Registering with LaunchServices..."
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "${INSTALL_PATH}"
echo "🔌 Enabling Safari Extension..."
pluginkit -e use -i "com.ct106.browsync.extension" || true
open "${INSTALL_PATH}"

echo "🎉 Installation complete!"

# Clean up the built apps to prevent LaunchServices from registering duplicates in Safari
echo "🧹 Cleaning up all built apps in build directories to prevent duplicate Safari extensions..."
find "${PROJECT_ROOT}/build" -type d -name "${APP_NAME}" -exec rm -rf {} + 2>/dev/null || true
find ~/Library/Developer/Xcode/DerivedData/BrowSync-* -type d -name "${APP_NAME}" -exec rm -rf {} + 2>/dev/null || true
