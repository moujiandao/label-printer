#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
destination="${1:-"$PWD/build/Label Printer.app"}"
if [[ -e "$destination" ]]; then
    printf 'Choose a new output path. Already exists: %s\n' "$destination" >&2
    exit 1
fi

staging="$(mktemp -d "${TMPDIR:-/tmp}/label-printer-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Label Printer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$(dirname "$destination")"
cp Info.plist "$app/Contents/"
cp LICENSE "$app/Contents/Resources/"
plutil -lint "$app/Contents/Info.plist"

for architecture in arm64 x86_64; do
    swiftc -swift-version 6 -warnings-as-errors -O -target "$architecture-apple-macosx14.0" \
        Sources/*.swift -o "$staging/$architecture"
done
lipo -create "$staging/arm64" "$staging/x86_64" -output "$app/Contents/MacOS/LabelPrinter"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
mv "$app" "$destination"
printf 'Built %s\n' "$destination"
