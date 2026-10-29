#!/bin/sh
# Build TeX Split and install it as ~/Applications/TeX Split.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/TeX Split.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TeXSplit "$APP/Contents/MacOS/TeXSplit"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "installed $APP"
