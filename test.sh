#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
staging="$(mktemp -d "${TMPDIR:-/tmp}/label-printer-test.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

swiftc -swift-version 6 -warnings-as-errors -O \
    Sources/PrinterProfile.swift Sources/PrinterConnection.swift \
    Sources/LabelImage.swift Sources/LabelDocument.swift Sources/LabelEditor.swift \
    Sources/SystemPrinting.swift Tests/OfflineChecks.swift \
    -o "$staging/offline-checks"
"$staging/offline-checks"
