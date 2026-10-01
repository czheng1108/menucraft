#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_only=0
if [ "${1:-}" = "--check-only" ]; then check_only=1; shift; fi
if [ "$#" != "1" ]; then
  echo "Usage: NOTARY_PROFILE=<keychain-profile> $0 [--check-only] <MenuCraft.dmg>" >&2
  exit 2
fi
dmg_file="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
if [[ "$dmg_file" != *.dmg ]] || [ ! -f "$dmg_file" ]; then
  echo "A saved MenuCraft DMG is required." >&2; exit 2
fi
if [ "$check_only" = "0" ] && [ -z "${NOTARY_PROFILE:-}" ]; then
  echo "Set NOTARY_PROFILE to credentials already stored by notarytool in Keychain." >&2
  exit 2
fi
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null

# Inspect the actual distribution, including every nested executable.
signature="$(codesign -d --verbose=4 "$dmg_file" 2>&1)" || {
  echo "DMG must be signed with Developer ID Application before notarization." >&2; exit 1;
}
[[ "$signature" == *"Authority=Developer ID Application:"* ]] || {
  echo "DMG must be signed with Developer ID Application before notarization." >&2; exit 1;
}
codesign --verify --strict "$dmg_file"
hdiutil verify "$dmg_file"
mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/menucraft-notary.XXXXXX")"
mounted=0
cleanup() {
  if [ "$mounted" = "1" ]; then
    hdiutil detach "$mount_dir" >/dev/null || return
    mounted=0
  fi
  rmdir "$mount_dir"
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$dmg_file" >/dev/null
mounted=1
app_dir="$mount_dir/MenuCraft.app"
app_team=""
for component in "$app_dir" "$app_dir/Contents/Helpers/MenuCraft.app" \
  "$app_dir/Contents/PlugIns/MenuCraftFinder.appex" "$app_dir/Contents/Resources/Tools/7zz"; do
  codesign --verify --strict "$component"
  signature="$(codesign -d --verbose=4 "$component" 2>&1)"
  [[ "$signature" == *"Authority=Developer ID Application:"* && \
     "$signature" == *"(runtime)"* && "$signature" == *$'\nTimestamp='* ]] || {
    echo "Missing Developer ID, hardened runtime or secure timestamp: $component" >&2; exit 1;
  }
  team="$(printf '%s\n' "$signature" | sed -n 's/^TeamIdentifier=//p')"
  [ -n "$team" ] && [ "$team" != "not set" ] || { echo "Missing signing team." >&2; exit 1; }
  if [ -z "$app_team" ]; then app_team="$team"; fi
  [ "$team" = "$app_team" ] || { echo "Nested code must use the same signing team." >&2; exit 1; }
  entitlements="$(codesign -d --entitlements :- "$component" 2>/dev/null)"
  if [ -n "$entitlements" ]; then
    printf '%s' "$entitlements" | python3 -c 'import plistlib,sys; p=plistlib.loads(sys.stdin.buffer.read()); sys.exit(1 if p.get("com.apple.security.get-task-allow") else 0)' || {
      echo "Debug get-task-allow entitlement must be removed: $component" >&2; exit 1;
    }
  fi
done
dmg_team="$(codesign -d --verbose=4 "$dmg_file" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ "$dmg_team" = "$app_team" ] || { echo "DMG and app signing teams differ." >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app_dir/Contents/Info.plist")"
for info in "$app_dir/Contents/Helpers/MenuCraft.app/Contents/Info.plist" \
  "$app_dir/Contents/PlugIns/MenuCraftFinder.appex/Contents/Info.plist"; do
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$info")" = "$version" ] && \
    [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$info")" = "$build" ] || {
    echo "Nested bundle versions differ." >&2; exit 1;
  }
done
codesign --verify --deep --strict "$app_dir"
cleanup
trap - EXIT
echo "Distribution preflight passed: MenuCraft $version / build $build."
if [ "$check_only" = "1" ]; then exit 0; fi

mkdir -p "$project_dir/.build/notarization"
log_dir="$(mktemp -d "$project_dir/.build/notarization/submission.XXXXXX")"
submit_exit=0
xcrun notarytool submit "$dmg_file" --keychain-profile "$NOTARY_PROFILE" \
  --wait --timeout "${NOTARY_TIMEOUT:-30m}" --output-format json > "$log_dir/submission.json" || submit_exit=$?
read_field() {
  python3 - "$log_dir/submission.json" "$1" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get(sys.argv[2], ""))
except (OSError, ValueError):
    print("")
PY
}
submission_id="$(read_field id)"
status="$(read_field status)"
if [ -n "$submission_id" ]; then
  echo "Submission: $submission_id; status: ${status:-unknown}"
  xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" "$log_dir/apple-log.json" || true
fi
if [ "$submit_exit" != "0" ] || [ "$status" != "Accepted" ]; then
  echo "Notarization has not completed successfully. Saved receipt: $log_dir/submission.json" >&2
  if [ -n "$submission_id" ]; then
    echo "If still In Progress, use notarytool wait/info with this submission ID; do not upload the same file again." >&2
  fi
  exit 1
fi
rm -f "$dmg_file.sha256"
xcrun stapler staple "$dmg_file"
xcrun stapler validate "$dmg_file"
hdiutil verify "$dmg_file"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_file"
# Stapling changes the DMG bytes; generate the final checksum only afterwards.
(cd "$(dirname "$dmg_file")" && shasum -a 256 "$(basename "$dmg_file")") > "$dmg_file.sha256"
echo "Notarized and verified: $dmg_file"
echo "Apple receipt and logs: $log_dir"
