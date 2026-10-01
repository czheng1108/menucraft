#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${SKIP_BUILD:-0}" != "1" ]; then "$project_dir/scripts/build.sh"; fi
app_dir="${APP_OUTPUT_DIR:-$project_dir/dist/MenuCraft.app}"
architectures="$(lipo -archs "$app_dir/Contents/MacOS/MenuCraft")"
case "$architectures" in
  arm64) package_arch="arm64" ;;
  x86_64) package_arch="x86_64" ;;
  *) package_arch="universal" ;;
esac
stage_dir="$project_dir/.build/dmg-stage-$package_arch"
mkdir -p "$stage_dir"
rm -rf "$stage_dir/MenuCraft.app"
ditto "$app_dir" "$stage_dir/MenuCraft.app"
ln -sfn /Applications "$stage_dir/Applications"
cp "$project_dir/docs/INSTALL.txt" "$stage_dir/安装说明.txt"
if [ "${SIGNING_IDENTITY:--}" != "-" ]; then
  python3 - "$stage_dir/安装说明.txt" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = '本包使用本地临时签名，尚未经过 Apple 开发者签名与公证。\n如果 macOS 阻止打开，可在“系统设置 > 隐私与安全性”中使用“仍要打开”。\n不要关闭系统安全检查；只对来源明确的 MenuCraft 进行允许。'
new = '本包使用 Developer ID 签名。公证结果以下载发布页及 macOS 安全检查为准。\n首次使用时，Finder 扩展、辅助功能与目录权限仍按系统提示开启。'
if old not in text:
    raise SystemExit('Signed installer instructions need review: expected development-signing block is missing.')
path.write_text(text.replace(old, new))
PY
fi
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
dmg_file="$project_dir/dist/MenuCraft-$version-$package_arch.dmg"
hdiutil create -ov -volname "MenuCraft" -srcfolder "$stage_dir" -format UDZO -fs HFS+ "$dmg_file"
if [ "${SIGNING_IDENTITY:--}" != "-" ]; then
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$dmg_file"
  codesign --verify --strict "$dmg_file"
fi
hdiutil verify "$dmg_file"
(cd "$(dirname "$dmg_file")" && shasum -a 256 "$(basename "$dmg_file")") > "$dmg_file.sha256"
echo "Installer: $dmg_file"
