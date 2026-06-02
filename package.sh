#!/bin/bash

# Configuration
PROJECT_NAME="BrowSync"
SCHEME="BrowSync"
BUNDLE_ID="com.ct106.browsync"
TEAM_ID="U2NEAJ73J2"
APP_NAME="${PROJECT_NAME}.app"
RESULT_DIR="./dist"
ARCHIVE_PATH="${RESULT_DIR}/${PROJECT_NAME}.xcarchive"
EXPORT_PATH="${RESULT_DIR}/exported"
DMG_NAME="${PROJECT_NAME}.dmg"
DMG_PATH="${RESULT_DIR}/${DMG_NAME}"
VERSION="$1"

# --- Check for Notarization Credentials ---
APPLE_ID="${APPLE_ID}"
APPLE_PASSWORD="${APPLE_PASSWORD}"
SPARKLE_BIN_PATH="./Sparkle/bin"

if [ ! -x "${SPARKLE_BIN_PATH}/generate_appcast" ]; then
    echo "⬇️ Sparkle tools not found at ${SPARKLE_BIN_PATH}. Downloading..."
    mkdir -p Sparkle_tmp
    
    SPARKLE_URL=$(curl -s https://api.github.com/repos/sparkle-project/Sparkle/releases/latest | grep "browser_download_url" | grep "tar.xz" | head -n 1 | cut -d '"' -f 4)
    
    if [ -z "$SPARKLE_URL" ]; then
        echo "❌ Error: Failed to find Sparkle download URL."
        exit 1
    fi
    
    curl -L "$SPARKLE_URL" -o sparkle_dist.tar.xz
    tar -xf sparkle_dist.tar.xz -C Sparkle_tmp
    
    mkdir -p Sparkle
    cp -R Sparkle_tmp/bin Sparkle/
    
    rm -rf Sparkle_tmp sparkle_dist.tar.xz
    echo "✅ Sparkle tools installed to ./Sparkle/bin"
fi

set -e

echo "🚀 Starting packaging process..."

rm -rf "${RESULT_DIR}"
mkdir -p "${RESULT_DIR}"

echo "📦 Archiving the app..."
xcodebuild archive \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    ENABLE_HARDENED_RUNTIME=YES

echo "📤 Exporting the archive..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "${EXPORT_PATH}" \
    -allowProvisioningUpdates

EXPORTED_APP="${EXPORT_PATH}/${APP_NAME}"

if [ ! -d "${EXPORTED_APP}" ]; then
    echo "❌ Exported app not found at ${EXPORTED_APP}"
    exit 1
fi

if [ -n "$APPLE_ID" ] && [ -n "$APPLE_PASSWORD" ]; then
    echo "🔐 Notarizing the .app bundle directly..."
    rm -f "${RESULT_DIR}/BrowSync_app.zip"
    /usr/bin/ditto -c -k --keepParent "${EXPORTED_APP}" "${RESULT_DIR}/BrowSync_app.zip"
    
    xcrun notarytool submit "${RESULT_DIR}/BrowSync_app.zip" \
        --apple-id "${APPLE_ID}" \
        --password "${APPLE_PASSWORD}" \
        --team-id "${TEAM_ID}" \
        --wait
    
    echo "🖋️ Stapling notarization ticket to the .app..."
    xcrun stapler staple "${EXPORTED_APP}"
    rm -f "${RESULT_DIR}/BrowSync_app.zip"
fi

echo "💿 Creating DMG..."
TMP_DMG_DIR="${RESULT_DIR}/dmg_tmp"
mkdir -p "${TMP_DMG_DIR}"
cp -R "${EXPORTED_APP}" "${TMP_DMG_DIR}/"
ln -s /Applications "${TMP_DMG_DIR}/Applications"

hdiutil create -volname "${PROJECT_NAME}" -srcfolder "${TMP_DMG_DIR}" -ov -format UDZO "${DMG_PATH}"
rm -rf "${TMP_DMG_DIR}"

if [ -n "$APPLE_ID" ] && [ -n "$APPLE_PASSWORD" ]; then
    echo "🔐 Submitting for notarization..."
    xcrun notarytool submit "${DMG_PATH}" \
        --apple-id "${APPLE_ID}" \
        --password "${APPLE_PASSWORD}" \
        --team-id "${TEAM_ID}" \
        --wait

    echo "🖋️ Stapling notarization ticket..."
    xcrun stapler staple "${DMG_PATH}"
    
    echo "✅ Notarization and stapling complete!"
else
    echo "⚠️ Notarization skipped because APPLE_ID and APPLE_PASSWORD are not set."
fi

if [ -x "${SPARKLE_BIN_PATH}/generate_appcast" ]; then
    if [ -n "$VERSION" ]; then
        DOWNLOAD_URL_PREFIX="https://github.com/chentao1006/browsync/releases/download/v${VERSION}/"
        echo "📡 Generating Sparkle appcast with prefix ${DOWNLOAD_URL_PREFIX} to project root..."
        "${SPARKLE_BIN_PATH}/generate_appcast" -o appcast.xml --download-url-prefix "${DOWNLOAD_URL_PREFIX}" "${RESULT_DIR}"
    else
        echo "📡 Generating Sparkle appcast to project root..."
        "${SPARKLE_BIN_PATH}/generate_appcast" -o appcast.xml "${RESULT_DIR}"
    fi
    echo "✅ appcast.xml generated in project root."
else
    echo "❌ Sparkle generate_appcast tool still missing at ${SPARKLE_BIN_PATH}."
    exit 1
fi

echo "🎉 All done! Your DMG is at: ${DMG_PATH}"
