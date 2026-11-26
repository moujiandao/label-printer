#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
staging="$(mktemp -d "${TMPDIR:-/tmp}/label-printer-test.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

swiftc -swift-version 6 -warnings-as-errors -O \
    Sources/PrinterProfile.swift Sources/LabelImage.swift Sources/LabelEditor.swift Tests/OfflineChecks.swift \
    -o "$staging/offline-checks"
"$staging/offline-checks"
