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

# Apple's notary upload occasionally times out on a flaky connection
# (HTTPClientError.deadlineExceeded during the S3 multipart upload) with
# nothing wrong with the submitted artifact. Retry a few times before
# treating it as a real failure.
notarize_submit() {
    local file_path="$1"
    local max_attempts=3
    local delay=30
    local attempt=1

    while [ "$attempt" -le "$max_attempts" ]; do
        echo "🔐 Submitting ${file_path} for notarization (attempt ${attempt}/${max_attempts})..."
        if xcrun notarytool submit "${file_path}" \
            --apple-id "${APPLE_ID}" \
            --password "${APPLE_PASSWORD}" \
            --team-id "${TEAM_ID}" \
            --wait; then
            return 0
        fi

        if [ "$attempt" -eq "$max_attempts" ]; then
            echo "❌ notarytool submit failed after ${max_attempts} attempts."
            return 1
        fi

        echo "⚠️ notarytool submit failed, retrying in ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

set -e

echo "🚀 Starting packaging process..."

mkdir -p "${RESULT_DIR}"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}" "${DMG_PATH}"

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
    
    notarize_submit "${RESULT_DIR}/BrowSync_app.zip"

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

# Extract the code signing identity used for the app
SIGN_IDENTITY=$(codesign -dvv "${EXPORTED_APP}" 2>&1 | grep "^Authority=Developer ID Application:" | head -n 1 | cut -d '=' -f 2)

if [ -n "$SIGN_IDENTITY" ]; then
    echo "🔐 Signing DMG with identity: $SIGN_IDENTITY"
    codesign --sign "$SIGN_IDENTITY" --timestamp "${DMG_PATH}"
else
    echo "⚠️ Could not determine Developer ID identity from the app. Skipping DMG signing."
fi

if [ -n "$APPLE_ID" ] && [ -n "$APPLE_PASSWORD" ]; then
    notarize_submit "${DMG_PATH}"

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

echo "🧹 Cleaning up exported app and archive..."
rm -rf "${EXPORT_PATH}" "${ARCHIVE_PATH}"

echo "🎉 All done! Your DMG is at: ${DMG_PATH}"
