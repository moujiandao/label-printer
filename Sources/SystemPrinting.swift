import AppKit

@MainActor
enum SystemPrinting {
    static func openPrintDialog(for label: LabelRaster, defaults: UserDefaults = .standard) {
        let pointsPerMillimeter = 72.0 / 25.4
        let size = NSSize(width: 100 * pointsPerMillimeter, height: 150 * pointsPerMillimeter)
        let image = NSImage(cgImage: label.preview, size: size)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown

        let info = NSPrintInfo(dictionary: [:])
        let printerKey = "lastSystemPrinter"
        if let name = defaults.string(forKey: printerKey),
           NSPrinter.printerNames.contains(name), let printer = NSPrinter(name: name) {
            info.printer = printer
        }
        info.paperSize = size
        info.orientation = .portrait
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = "4 × 6 Label"
        operation.showsPrintPanel = true
        if operation.run() {
            defaults.set(operation.printInfo.printer.name, forKey: printerKey)
        }
    }
}
