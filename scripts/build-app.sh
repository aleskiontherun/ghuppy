#!/usr/bin/env bash
# Builds a release Ghuppy.app into ./build. Pass --install to also copy it
# into /Applications, or --restart to install it and then quit and reopen the
# Ghuppy running from there, if one is.
set -euo pipefail

cd "$(dirname "$0")/.."
name=Ghuppy
bundle_id=me.vesnin.ghuppy
app="build/$name.app"
version=$(git describe --tags --always 2>/dev/null || echo 0.1.0)

swift build -c release --arch arm64
bin=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/$name" "$app/Contents/MacOS/$name"
# Compiles the Icon Composer icon: Assets.car holds the Liquid Glass icon
# macOS 26 renders, AppIcon.icns a flattened fallback for older systems.
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "build/icon-partial.plist" >/dev/null

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleExecutable</key><string>$name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${version#v}</string>
    <key>CFBundleVersion</key><string>${version#v}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally. Not notarized.
codesign --force --sign - "$app"
echo "Built $app"

installed="/Applications/$name.app"
if [[ "${1:-}" == "--install" || "${1:-}" == "--restart" ]]; then
    rm -rf "$installed"
    cp -R "$app" /Applications/
    echo "Installed $installed"
fi

executable="$installed/Contents/MacOS/$name"
if [[ "${1:-}" == "--restart" ]] && pgrep -aqf "^$executable"; then
    # Asks Ghuppy to quit, so it saves its tabs as usual, waits up to 30
    # seconds for it to go, then opens the new one. Ghuppy terminates the
    # process groups of its repository actions as it quits, so this runs in
    # a session of its own to outlive the action that started it.
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' /bin/sh -c '
        osascript -e "tell application id \"$1\" to quit" || exit
        for _ in $(seq 150); do
            pgrep -aqf "^$2" || exec open "$3"
            sleep 0.2
        done' sh "$bundle_id" "$executable" "$installed" </dev/null >/dev/null 2>&1 &
    echo "Restarting $name"
fi
