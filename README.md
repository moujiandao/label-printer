# Label Printer

Paste or drop an image, preview it on a 4 × 6 label, and print from your Mac. Label Printer uses 100 × 150 mm stock and supports macOS 14 or later on Apple silicon and Intel.

## Install

1. Download [Label-Printer-macOS.dmg](https://github.com/moujiandao/label-printer/releases/latest/download/Label-Printer-macOS.dmg) and open it.
2. Drag **Label Printer** onto the **Applications** shortcut in the window.
3. Open **Label Printer** from Applications. To pin it to the Dock, Control-click its Dock icon and choose **Options → Keep in Dock**.

The [ZIP download](https://github.com/moujiandao/label-printer/releases/latest/download/Label-Printer-macOS.zip) is also available. If macOS blocks the locally signed download, use the source build below.

## Choose your printer

| Connection | Setup |
| --- | --- |
| **Direct Bluetooth LE** | In the app, click **Add Bluetooth Printer…**. Choose your device, then select the documented Bluetooth write endpoint, **TSPL** or **ZPL**, and the printer resolution. The Nelko PL70e-BT preset fills in the endpoint and language when it finds them. **Save Printer** remembers the device. Label Printer retries the connection when you open or return to the app, or when your Mac wakes. |
| **Wi-Fi, USB, or driver-backed Bluetooth** | Add the printer in **System Settings → Printers & Scanners**. In the app, click **System Print…**, choose your printer, and set its paper size to **100 × 150 mm** or the equivalent **4 × 6** preset. |

Direct Bluetooth requires a printer that accepts TSPL or ZPL through a writable Bluetooth LE characteristic. TSPL jobs use gap-sensed stock with a 2 mm gap. Turn on Bluetooth on your Mac, power on the printer nearby, and allow access when macOS asks. If your model uses a proprietary protocol or Bluetooth Classic, check whether its vendor offers a macOS driver and use **System Print…** if the printer appears there.

### Connect a Wi-Fi printer

1. Use the printer’s setup menu or manufacturer’s app to join your Wi-Fi network.
2. On your Mac, click **Wi-Fi** in the menu bar or Control Center. Confirm the network name matches the one selected on the printer. Avoid guest networks that isolate devices from each other.
3. Open **System Settings → Printers & Scanners → Add Printer, Scanner, or Fax**. Select the printer and click **Add**. If it supports AirPrint, choose **AirPrint** when offered.
4. Open a label in Label Printer and select the printer using **System Print…**. If it still doesn’t appear, check the printer’s network status and follow the vendor’s Mac setup guide.

Wi-Fi setup applies to network printing. Direct Bluetooth uses the Bluetooth connection. [Apple’s printer setup guide](https://support.apple.com/guide/mac-help/add-and-manage-printers-mh14004/mac)

## Print a label

1. Drop an image onto the preview or press **⌘V** or **Ctrl+V**.
2. Adjust the crop or select **Fit entire image** if an edge contains text or a barcode. Rotate as needed.
3. Click **Print Label** for a saved Bluetooth printer, or **System Print…** for a printer added to macOS. **Save PNG…** exports the preview for another printing app.

## Build from source

Download **Code → Download ZIP** from GitHub and unzip it, or clone the repository. Install Apple’s Command Line Tools with `xcode-select --install` if you don’t have Swift 6. From the extracted folder or local checkout, run:

```sh
bash build.sh
open "build/Label Printer.app"
```

Run `bash test.sh` for offline tests.

### Build the installer

Build the app from the commit you plan to release, then run `bash package.sh`. It creates `build/Label-Printer-macOS.dmg` with the app and an Applications shortcut. Mount the disk image and check the version and Finder icon of the app inside it before uploading it to GitHub. To package an existing app bundle, pass its path as the first argument.

The source build uses local signing. For a notarized public download, use a Developer ID-signed app and follow [Apple’s distribution guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

## Privacy and license

Label Printer has no accounts, analytics, or uploads. It uses the clipboard when you paste and stores the selected printer settings locally. Images are passed to the printer after you choose a print action.

Label Printer is open source under the [MIT License](LICENSE). Contributions are welcome. For a printer compatibility report, include the model, connection method, macOS version, and any steps to reproduce using a synthetic label. Label Printer is an independent project. Printer names identify compatibility presets and do not imply vendor endorsement.
