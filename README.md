# Label Printer

Paste a label image from your clipboard with **⌘V**, or drag and drop an image or PDF. Preview and print on **4 × 6** stock, with one label per PDF page.

Label Printer uses 100 × 150 mm stock and supports macOS 14 or later on Apple silicon and Intel.

## Install

1. Download [Label-Printer-macOS.dmg](https://github.com/moujiandao/label-printer/releases/latest/download/Label-Printer-macOS.dmg) and open it.
2. Drag **Label Printer** onto the **Applications** shortcut in the window.
3. Open **Label Printer** from Applications. To pin it to the Dock, Control-click its Dock icon and choose **Options → Keep in Dock**.

To update, quit Label Printer before dragging in the new copy, then choose **Replace** if Finder asks. The [ZIP download](https://github.com/moujiandao/label-printer/releases/latest/download/Label-Printer-macOS.zip) is also available.

### If macOS can’t verify Label Printer

The GitHub builds use ad hoc signing and have no Apple notarization, so macOS may block the first launch. If you downloaded the app from this project and verified it against the release’s SHA-256 checksum, you can approve this copy. [Label Printer releases](https://github.com/moujiandao/label-printer/releases/latest)

1. Try opening **Label Printer** from **Applications** and dismiss the alert.
2. Open **System Settings → Privacy & Security** and scroll down to **Security**.
3. Click **Open Anyway** for Label Printer, then confirm **Open**. Authenticate if prompted.

If **Open Anyway** is unavailable, see [Build from source](#build-from-source). [Apple Support’s opening instructions](https://support.apple.com/en-us/102445)

## Choose your printer

| Connection | Setup |
| --- | --- |
| **Direct Bluetooth LE** | In the app, click **Add Bluetooth Printer…**. Choose your device, then select the documented Bluetooth write endpoint, **TSPL** or **ZPL**, and the printer resolution. The Nelko PL70e-BT preset fills in the endpoint and language when it finds them. **Save Printer** remembers the device. Label Printer retries the connection when you open or return to the app, or when your Mac wakes. |
| **Wi-Fi, USB, or driver-backed Bluetooth** | Add the printer in **System Settings → Printers & Scanners**. In the app, click **System Print…**, choose your printer, and set its paper size to **100 × 150 mm** or the equivalent **4 × 6** preset. |

Direct Bluetooth requires a printer that accepts TSPL or ZPL through a writable Bluetooth LE characteristic. TSPL jobs use gap-sensed stock with a 2 mm gap. Turn on Bluetooth on your Mac, power on the printer nearby, and allow access when macOS asks. If your model uses a proprietary protocol or Bluetooth Classic, check whether its vendor offers a macOS driver and use **System Print…** if the printer appears there.

If your saved device is missing from the Bluetooth scan, choose **Use Saved Printer** to retry it directly. **Reconnect Printer** in the sidebar refreshes the Bluetooth connection and keeps your label preview.

### Connect a Wi-Fi printer

1. Use the printer’s setup menu or manufacturer’s app to join your Wi-Fi network.
2. On your Mac, click **Wi-Fi** in the menu bar or Control Center. Confirm the network name matches the one selected on the printer. Avoid guest networks that isolate devices from each other.
3. Open **System Settings → Printers & Scanners → Add Printer, Scanner, or Fax**. Select the printer and click **Add**. If it supports AirPrint, choose **AirPrint** when offered.
4. Open a label in Label Printer and select the printer using **System Print…**. If it still doesn’t appear, check the printer’s network status and follow the vendor’s Mac setup guide.

Wi-Fi setup applies to network printing. Direct Bluetooth uses the Bluetooth connection. [Apple’s printer setup guide](https://support.apple.com/guide/mac-help/add-and-manage-printers-mh14004/mac)

## Print a label

1. Drop an image or PDF onto the preview, or choose **Open…**. Paste an image with **⌘V** or **Ctrl+V**.
2. For an image, adjust the crop or choose **Fit entire image** to keep edge text and barcodes. For a PDF, use the arrows above the preview to inspect each page. Label Printer fits the entire PDF page onto the label.
3. Click **Print Label** or **Print N Labels** for a saved Bluetooth printer. Each PDF page prints on its own 4 × 6 label in document order. **System Print…** opens the macOS print dialog, and **Save PNG…** exports the page shown in the preview.

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

Label Printer has no accounts, analytics, or uploads. It uses the clipboard when you paste, opens image and PDF files locally, and keeps the selected printer settings on your Mac. It sends label content to the selected printer when you print.

Label Printer is open source under the [MIT License](LICENSE). Contributions are welcome. For a printer compatibility report, include the model, connection method, macOS version, and any steps to reproduce using a synthetic label. Label Printer is an independent project. Printer names identify compatibility presets and do not imply vendor endorsement.
