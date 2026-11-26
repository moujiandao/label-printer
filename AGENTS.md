# Label Printer

## What This Is

Label Printer is a native SwiftUI application for preparing and printing 4 × 6 shipping labels on macOS.

## Architecture

SwiftUI and AppKit handle image input, cropping, preview, and the system print dialog. CoreBluetooth handles direct BLE printer discovery and transport. Printer profiles select the TSPL or ZPL encoding.

## Key Conventions

Application code lives in `Sources/`. Offline checks live in `Tests/`. Run `bash test.sh` and `bash build.sh` on macOS.

## Non-Obvious Decisions

Preserve the app bundle identifier across updates so saved printer profiles remain available. Build a universal app for Apple silicon and Intel on macOS 14 or newer.

## Common Tasks

- Build locally with `bash build.sh`.
- Create the release disk image with `bash package.sh` after building.
- Verify the finished image by mounting it and checking the app and Applications link.

## Do Not

- Commit generated app bundles or release images.
- Use real shipping labels, printer identifiers, or credentials as test fixtures.
- Send a physical print job during offline verification.
