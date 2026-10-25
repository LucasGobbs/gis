#!/bin/sh
# package_macos_cpp.sh [version]
#
# Builds the app (CMake at the repo root) and assembles builds/apple/gis-cpp.app
# plus a zip. Mirrors tools/package_macos.sh layout: the app resolves
# assets/, src/shaders and vendor/slang relative to Contents/Resources/app.
#
# Prereqs (brew): qt, sdl3, qscintilla2, cmake; goose submodule in vendor/goose.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

VERSION="0.1.0"
for arg in "$@"; do VERSION="$arg"; done

APP_NAME="gis-cpp"
OUT="builds/apple"
BUNDLE="$OUT/$APP_NAME.app"
CONTENTS="$BUNDLE/Contents"
APP_RSC="$CONTENTS/Resources/app"
GOOSE_DIR="${GOOSE_DIR:-vendor/goose}"
SLANG_DIR="vendor/slang"
ARCH=$(uname -m)
ZIP="gis-cpp-$VERSION-macos-$ARCH.zip"

# 1. Scene artifacts (slangc -> msl + refl.json); same command as make shaders.
make shaders

# 2. Configure + build the app (Release).
cmake -B builds/dev -S . \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt
cmake --build builds/dev

# 3. Bundle skeleton + payload.
rm -rf "$BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$APP_RSC/src/generated/scenes" "$APP_RSC/exports" \
	"$APP_RSC/vendor/slang" "$APP_RSC/assets"
cp builds/dev/gis_host "$APP_RSC/"
cp "$GOOSE_DIR/goose-build" "$APP_RSC/"
rm -rf "$APP_RSC/assets" && cp -R assets "$APP_RSC/assets"
mkdir -p "$APP_RSC/src/shaders"
cp -R src/shaders/common.slang src/shaders/space.slang src/shaders/camera.slang \
	src/shaders/noise.slang src/shaders/sdf.slang src/shaders/scenes "$APP_RSC/src/shaders/"
cp -R "$SLANG_DIR/bin" "$APP_RSC/vendor/slang/bin"
cp src/generated/scenes/manifest.json "$APP_RSC/src/generated/scenes/" 2>/dev/null || true
# Prebuilt scene artifacts so the bundle's first launch renders without a
# rebuild; the in-app watcher rebuilds on change.
cp src/generated/scenes/*.msl src/generated/scenes/*.refl.json \
	"$APP_RSC/src/generated/scenes/" 2>/dev/null || true
cp src/generated/blit.vert.msl src/generated/blit.frag.msl \
	src/generated/blit.vert.msl.refl.json src/generated/blit.frag.msl.refl.json \
	"$APP_RSC/src/generated/" 2>/dev/null || true


# 4. Dylibs stay linked to Homebrew (prereq of the port, same layout as the
# Odin build which also runs against brew SDL3). Bundling Qt duplicates
# classes against brew's (libqscintilla2 pulls brew Qt), so we keep brew
# linkage for the dev-machine zip; macdeployqt runs as a follow-up for a
# fully self-contained bundle when needed.
echo "note: dylibs resolve from Homebrew (brew install qt sdl3 qscintilla2)"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>gis cpp</string>
	<key>CFBundleExecutable</key><string>gis_host</string>
	<key>CFBundleIdentifier</key><string>com.gobbi.gis.cpp</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 6. Launcher: anchors the cwd at Resources/app (asset resolution).
cat > "$CONTENTS/MacOS/gis-cpp" <<LAUNCHER
#!/bin/sh
cd "\$(dirname "\$0")/../Resources/app"
exec ./gis_host "\$@"
LAUNCHER
chmod +x "$CONTENTS/MacOS/gis-cpp"

# 7. Zip.
cd "$OUT"
rm -f "$ZIP"
zip -qr "$ZIP" "$APP_NAME.app"
echo "packaged: $BUNDLE and $ZIP"
