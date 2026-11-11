#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="${TMPDIR:-/tmp}/aircraft-release"
APP_DIR="$PROJECT_DIR/dist/Aircraft.app"
ICON_OUTPUT_DIR="$BUILD_DIR/icon-assets"

cd "$PROJECT_DIR"
CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/aircraft-clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/aircraft-swift-cache" \
swift build -c release --scratch-path "$BUILD_DIR"
PRODUCT_DIR=$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)

rm -rf -- "$ICON_OUTPUT_DIR"
mkdir -p "$ICON_OUTPUT_DIR"
xcrun actool "$PROJECT_DIR/Sources/aircraft.icon" \
    --compile "$ICON_OUTPUT_DIR" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon aircraft \
    --include-all-app-icons \
    --output-partial-info-plist "$ICON_OUTPUT_DIR/partial-info.plist"

[[ "$APP_DIR" == "$PROJECT_DIR/dist/Aircraft.app" ]] || exit 1
rm -rf -- "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PRODUCT_DIR/Aircraft" "$APP_DIR/Contents/MacOS/Aircraft"
cp "$PRODUCT_DIR/aircraft-mcp" "$APP_DIR/Contents/MacOS/aircraft-mcp"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ICON_OUTPUT_DIR/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
cp "$ICON_OUTPUT_DIR/aircraft.icns" "$APP_DIR/Contents/Resources/aircraft.icns"
cp "$PROJECT_DIR/Documentation/MODIFICATIONS.md" "$APP_DIR/Contents/Resources/Modifications.md"
mkdir -p "$APP_DIR/Contents/Resources/ModTemplates"
cp -R "$PROJECT_DIR/Examples/Mods/." "$APP_DIR/Contents/Resources/ModTemplates/"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "$APP_DIR"
