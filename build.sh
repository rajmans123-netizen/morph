#!/bin/zsh
# Build Morph.app (universal: Apple silicon + Intel), ad-hoc signed, into build/
set -e
cd "${0:A:h}"
APP=build/Morph.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 Sources/main.swift -o build/Morph-$arch
done
lipo -create build/Morph-arm64 build/Morph-x86_64 -output $APP/Contents/MacOS/Morph && rm build/Morph-arm64 build/Morph-x86_64
[ -f assets/Morph.icns ] && cp assets/Morph.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Morph</string>
  <key>CFBundleDisplayName</key><string>Morph</string>
  <key>CFBundleIdentifier</key><string>com.rajtries.morph</string>
  <key>CFBundleExecutable</key><string>Morph</string>
  <key>CFBundleIconFile</key><string>Morph</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Raj Tries · built with Claude</string>
</dict></plist>
PL
codesign --force --deep -s - $APP
echo "built $APP"
