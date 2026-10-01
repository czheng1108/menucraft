#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/.build"
app_dir="${APP_OUTPUT_DIR:-$project_dir/dist/MenuCraft.app}"
extension_dir="$app_dir/Contents/PlugIns/MenuCraftFinder.appex"
settings_dir="$app_dir/Contents/Helpers/MenuCraft.app"
sdk_dir="$(xcrun --show-sdk-path)"
architectures="${ARCHS:-arm64 x86_64}"
signing_identity="${SIGNING_IDENTITY:--}"
release_version="$(cat "$project_dir/VERSION")"
release_build="$(cat "$project_dir/BUILD_NUMBER")"
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$release_build" =~ ^[0-9]+$ ]] || {
  echo "VERSION or BUILD_NUMBER is invalid." >&2; exit 1;
}
# Remove the previous generated helper so upgrades do not retain a second identity.
rm -rf "$app_dir/Contents/Helpers/MenuCraftSettings.app"
mkdir -p "$build_dir" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/Tools" "$app_dir/Contents/Resources/ThirdParty" "$extension_dir/Contents/MacOS" "$settings_dir/Contents/MacOS" "$settings_dir/Contents/Resources"
engine_binaries=()
for architecture in $architectures; do
  lipo "$project_dir/ThirdParty/7zip/7zz" -thin "$architecture" -output "$build_dir/7zz-$architecture"
  engine_binaries+=("$build_dir/7zz-$architecture")
done
lipo -create "${engine_binaries[@]}" -output "$app_dir/Contents/Resources/Tools/7zz"
cp "$project_dir/ThirdParty/7zip/License.txt" "$app_dir/Contents/Resources/ThirdParty/7zip-LICENSE.txt"
cp "$project_dir/ThirdParty/7zip/source/7z2603-src.tar.xz" "$app_dir/Contents/Resources/ThirdParty/"
cp "$project_dir/ThirdParty/ScrollReverser/LICENSE" "$app_dir/Contents/Resources/ThirdParty/ScrollReverser-LICENSE.txt"
cp "$project_dir/ThirdParty/ScrollReverser/NOTICE" "$app_dir/Contents/Resources/ThirdParty/ScrollReverser-NOTICE.txt"
cp "$project_dir/ThirdParty/README.md" "$app_dir/Contents/Resources/ThirdParty/README.md"
cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/MenuCraft-LICENSE.txt"
cp "$project_dir/NOTICE" "$app_dir/Contents/Resources/MenuCraft-NOTICE.txt"
cp "$project_dir/Resources/App-Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/Extension-Info.plist" "$extension_dir/Contents/Info.plist"
cp "$project_dir/Resources/Settings-Info.plist" "$settings_dir/Contents/Info.plist"
for info in "$app_dir/Contents/Info.plist" "$extension_dir/Contents/Info.plist" "$settings_dir/Contents/Info.plist"; do
  /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $release_version" "$info"
  /usr/libexec/PlistBuddy -c "Set CFBundleVersion $release_build" "$info"
done
for architecture in $architectures; do
  if [ "${REUSE_BINARIES:-0}" != "1" ]; then
    echo "Building resident core ($architecture)…"
    clang -fobjc-arc -O2 -target "$architecture-apple-macosx13.0" -isysroot "$sdk_dir" -c "$project_dir/Sources/Scroll/MCScrollEngine.m" -o "$build_dir/MCScrollEngine-$architecture.o"
    swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library -module-name MenuCraft \
      -target "$architecture-apple-macosx13.0" -sdk "$sdk_dir" \
      -import-objc-header "$project_dir/Sources/Scroll/Bridge.h" "$build_dir/MCScrollEngine-$architecture.o" \
      "$project_dir"/Sources/Core/*.swift "$project_dir"/Sources/Shared/*.swift "$project_dir"/Sources/Runtime/*.swift "$project_dir"/Sources/Agent/*.swift \
      -framework AppKit -framework Combine -framework FinderSync -framework ServiceManagement -framework ApplicationServices -framework IOKit \
      -o "$build_dir/MenuCraft-$architecture"
    echo "Building on-demand settings ($architecture)…"
    swiftc -swift-version 5 -Osize -whole-module-optimization -parse-as-library -module-name MenuCraftSettings \
      -target "$architecture-apple-macosx13.0" -sdk "$sdk_dir" \
      "$project_dir"/Sources/Core/*.swift "$project_dir"/Sources/Shared/*.swift "$project_dir"/Sources/Runtime/*.swift \
      "$project_dir"/Sources/Settings/*.swift "$project_dir/Sources/App/Views.swift" "$project_dir/Sources/App/FeatureViews.swift" "$project_dir/Sources/App/SettingsComponents.swift" \
      -framework AppKit -framework SwiftUI -framework FinderSync -o "$build_dir/MenuCraftSettings-$architecture"
    echo "Building Finder extension ($architecture)…"
    swiftc -swift-version 5 -Osize -whole-module-optimization -parse-as-library -application-extension -module-name MenuCraftFinder \
      -target "$architecture-apple-macosx13.0" -sdk "$sdk_dir" \
      "$project_dir/Sources/Core/Models.swift" "$project_dir/Sources/Core/FeatureConfiguration.swift" "$project_dir"/Sources/Shared/*.swift "$project_dir"/Sources/FinderExtension/*.swift \
      -framework AppKit -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain -o "$build_dir/MenuCraftFinder-$architecture"
    for name in MenuCraft MenuCraftSettings MenuCraftFinder; do strip -S -x "$build_dir/$name-$architecture"; done
  fi
done
for component in MenuCraft MenuCraftSettings MenuCraftFinder; do
  binaries=()
  for architecture in $architectures; do binaries+=("$build_dir/$component-$architecture"); done
  case "$component" in
    MenuCraft) target="$app_dir/Contents/MacOS/MenuCraft" ;;
    MenuCraftSettings) target="$settings_dir/Contents/MacOS/MenuCraft" ;;
    MenuCraftFinder) target="$extension_dir/Contents/MacOS/MenuCraftFinder" ;;
  esac
  lipo -create "${binaries[@]}" -output "$target"
done
swift "$project_dir/scripts/make-icon.swift" "$build_dir/AppIcon.iconset"
python3 "$project_dir/scripts/optimize-icon.py" "$build_dir/AppIcon.iconset"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
# Each bundle has a valid icon resource; hard links share its disk allocation.
rm -f "$settings_dir/Contents/Resources/AppIcon.icns"
ln "$app_dir/Contents/Resources/AppIcon.icns" "$settings_dir/Contents/Resources/AppIcon.icns"
if [ "$signing_identity" = "-" ]; then
  codesign --force --sign - "$app_dir/Contents/Resources/Tools/7zz"
  codesign --force --sign - "$settings_dir"
  codesign --force --sign - --entitlements "$project_dir/Resources/Extension.entitlements" "$extension_dir"
  codesign --force --sign - --entitlements "$project_dir/Resources/App.entitlements" "$app_dir"
else
  codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_dir/Contents/Resources/Tools/7zz"
  codesign --force --options runtime --timestamp --sign "$signing_identity" "$settings_dir"
  codesign --force --options runtime --timestamp --sign "$signing_identity" --entitlements "$project_dir/Resources/Extension.entitlements" "$extension_dir"
  codesign --force --options runtime --timestamp --sign "$signing_identity" --entitlements "$project_dir/Resources/App.entitlements" "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
echo "Built: $app_dir"
