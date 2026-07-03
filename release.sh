#!/bin/bash

# Configuration
# Ensure we use the newer git from Homebrew if available, as older git versions (like 2.33)
# do not support gpg.format = ssh and will fail to parse ~/.gitconfig.
export PATH="/opt/homebrew/bin:$PATH"
PLIST_PATH="BrowSync/Resources/Info.plist"
VERSIONED_PLISTS=(
    "BrowSync/Resources/Info.plist"
    "SafariExtension/Info.plist"
)
PROJECT_YML="project.yml"
RESULT_DIR="./dist"

# Helper function to get current version
get_current_version() {
    grep -A 1 "CFBundleShortVersionString" "$PLIST_PATH" | grep "<string>" | sed -E 's/.*<string>(.*)<\/string>.*/\1/'
}

# Helper function to get current build
get_current_build() {
    grep -A 1 "CFBundleVersion" "$PLIST_PATH" | grep "<string>" | sed -E 's/.*<string>(.*)<\/string>.*/\1/'
}

update_plist_version() {
    local plist_path="$1"
    sed -i '' -E "/<key>CFBundleShortVersionString<\/key>/{n;s/<string>.*<\/string>/<string>$NEW_VERSION<\/string>/;}" "$plist_path"
    sed -i '' -E "/<key>CFBundleVersion<\/key>/{n;s/<string>.*<\/string>/<string>$NEW_BUILD<\/string>/;}" "$plist_path"
}

CURRENT_VERSION=$(get_current_version)
CURRENT_BUILD=$(get_current_build)

echo "----------------------------------------"
echo "Current Version: $CURRENT_VERSION"
echo "Current Build  : $CURRENT_BUILD"
echo "----------------------------------------"

SKIP_BUILD=false
NEW_VERSION_ARG=""

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--skip-build) SKIP_BUILD=true ;;
        *) NEW_VERSION_ARG="$1" ;;
    esac
    shift
done

if [ "$SKIP_BUILD" = "true" ]; then
    # When skipping build, default to current version/build if not specified
    if [ -z "$NEW_VERSION_ARG" ]; then
        NEW_VERSION="$CURRENT_VERSION"
    else
        NEW_VERSION="$NEW_VERSION_ARG"
    fi
    NEW_BUILD="$CURRENT_BUILD"
    echo "⏩ Skipping build step. Using current version $NEW_VERSION (Build $NEW_BUILD)."
else
    # When building, we need a new version (prompt if not provided)
    if [ -z "$NEW_VERSION_ARG" ]; then
        read -p "Enter NEW Version (Current: $CURRENT_VERSION, press Enter to keep current): " NEW_VERSION
    else
        NEW_VERSION="$NEW_VERSION_ARG"
    fi

    if [ -z "$NEW_VERSION" ]; then
        NEW_VERSION="$CURRENT_VERSION"
        echo "Using current version: $NEW_VERSION"
    fi

    # Determine NEW_BUILD (Always increment for new builds)
    NEW_BUILD=$((CURRENT_BUILD + 1))
    
    echo "🚀 Preparing local release $NEW_VERSION (Build $NEW_BUILD)..."

    # 1. Update Version Files
    for plist_path in "${VERSIONED_PLISTS[@]}"; do
        update_plist_version "$plist_path"
    done
    
    sed -i '' "s/CFBundleShortVersionString: .*/CFBundleShortVersionString: \"$NEW_VERSION\"/" "$PROJECT_YML"
    sed -i '' "s/CFBundleVersion: .*/CFBundleVersion: \"$NEW_BUILD\"/" "$PROJECT_YML"

    # Update Extension manifests
    sed -i '' -E "s/\"version\": \".*\"/\"version\": \"$NEW_VERSION\"/" "ChromiumExtension/manifest.json"
    sed -i '' -E "s/\"version\": \".*\"/\"version\": \"$NEW_VERSION\"/" "FirefoxExtension/manifest.json"
    sed -i '' -E "s/\"version\": \".*\"/\"version\": \"$NEW_VERSION\"/" "SafariExtension/Resources/manifest.json"

    echo "✅ Local configuration updated."
    # xcodegen > /dev/null (Removed: to allow manual Xcode settings to be preserved)

    # 2. Run Local Build
    chmod +x package.sh
    ./package.sh "$NEW_VERSION"

    if [ ! -f "${RESULT_DIR}/BrowSync.dmg" ]; then
        echo "❌ Local Build Failed: BrowSync.dmg not found in ${RESULT_DIR}"
        exit 1
    fi
fi

# 3. Git Operations
git add .
# Check if there are changes to commit
if git diff-index --quiet HEAD --; then
    echo "ℹ️ No changes to commit."
else
    git commit -m "chore: release version $NEW_VERSION build $NEW_BUILD"
fi

# Check if tag already exists and handle accordingly (gh release delete handles it later, but git tag might fail)
if git rev-parse "v$NEW_VERSION" >/dev/null 2>&1; then
    echo "ℹ️ Tag v$NEW_VERSION already exists locally, will overwrite if needed during release."
    git tag -d "v$NEW_VERSION" >/dev/null 2>&1
fi
git tag -m "Release v$NEW_VERSION" "v$NEW_VERSION"



echo "📦 Code committed and tagged locally."

# 4. Push and Upload to GitHub
BRANCH=$(git symbolic-ref --short HEAD)
git push origin "$BRANCH"
git push origin "v$NEW_VERSION"

# Use GitHub CLI to create release and upload assets
if command -v gh >/dev/null 2>&1; then
    echo "📡 Creating GitHub Release and uploading assets..."
    echo "📦 Packaging Chromium Extension..."
    cd ChromiumExtension
    zip -r "../${RESULT_DIR}/ChromiumExtension-v${NEW_VERSION}.zip" * -x "*.DS_Store" -x "*.git*" > /dev/null
    cd ..

    echo "📦 Packaging Firefox Extension..."
    cd FirefoxExtension
    zip -r "../${RESULT_DIR}/FirefoxExtension-v${NEW_VERSION}.zip" * -x "*.DS_Store" -x "*.git*" > /dev/null
    cd ..
    
    # DMG is the primary asset
    ASSETS=("${RESULT_DIR}/BrowSync.dmg")
    
    # If re-releasing the same version, we need to delete the old one first
    echo "🧹 Removing existing release and tag if they exist..."
    gh release delete "v$NEW_VERSION" --yes 2>/dev/null || true
    git push origin --delete "v$NEW_VERSION" 2>/dev/null || true
    git tag -d "v$NEW_VERSION" 2>/dev/null || true

    gh release create "v$NEW_VERSION" \
        "${ASSETS[@]}" \
        --title "Release v$NEW_VERSION" \
        --notes "Automatic local release of version $NEW_VERSION (Build $NEW_BUILD)"
    
    if [ $? -eq 0 ]; then
        echo "🎉 Release completed successfully!"
        if [ "${SKIP_HOMEBREW_RELEASE:-0}" = "1" ]; then
            echo "⏭️  Skipping Homebrew release because SKIP_HOMEBREW_RELEASE=1."
        else
            echo "🍺 Updating Homebrew tap..."
            chmod +x release-to-brew.sh
            if ./release-to-brew.sh "${RESULT_DIR}/BrowSync.dmg" "$NEW_VERSION"; then
                echo "🍺 Homebrew tap updated successfully!"
            else
                echo "❌ Error: Homebrew tap update failed. GitHub Release was created, but the cask may need to be updated manually."
                exit 1
            fi
        fi
    else
        echo "❌ Error: GitHub Release failed to create. Please check the error above."
    fi
else
    echo "⚠️  Note: GitHub CLI (gh) not found or not authenticated. Please upload ${RESULT_DIR}/BrowSync.dmg and appcast.xml manually to the GitHub release page."
fi
