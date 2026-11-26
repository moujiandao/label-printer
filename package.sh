#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
app="${1:-"$PWD/build/Label Printer.app"}"
destination="${2:-"$PWD/build/Label-Printer-macOS.dmg"}"

if [[ $# -gt 2 || "$destination" != *.dmg ]]; then
    printf '%s\n' 'Usage: bash package.sh [app bundle] [destination.dmg]' >&2
    exit 1
fi
if [[ -e "$destination" || -L "$destination" ]]; then
    printf 'Choose a new output path. Already exists: %s\n' "$destination" >&2
    exit 1
fi
if [[ ! -f "$app/Contents/Info.plist" ]]; then
    printf 'Build Label Printer with bash build.sh or pass the app bundle path. Missing: %s\n' "$app" >&2
    exit 1
fi
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")"
if [[ "$bundle_id" != local.labeldesk.pl70e ]]; then
    printf 'Expected a Label Printer app bundle. Got: %s\n' "$bundle_id" >&2
    exit 1
fi
codesign --verify --strict "$app"

output_dir="$(dirname "$destination")"
mkdir -p "$output_dir"
staging="$(mktemp -d "$output_dir/.label-printer-package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

payload="$staging/payload"
image="$staging/Label-Printer-macOS.dmg"
mkdir "$payload"
ditto "$app" "$payload/Label Printer.app"
ln -s /Applications "$payload/Applications"
hdiutil create -quiet -volname 'Label Printer' -fs HFS+ -format UDZO -srcfolder "$payload" "$image"
hdiutil verify -quiet "$image"
mv -nh "$image" "$destination"
if [[ -e "$image" || ! -f "$destination" ]]; then
    printf 'Could not publish the disk image at: %s\n' "$destination" >&2
    exit 1
fi
printf 'Packaged %s\n' "$destination"
