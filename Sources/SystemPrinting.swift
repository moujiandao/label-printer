import AppKit

@MainActor
enum SystemPrinting {
    static func openPrintDialog(for labels: LabelPrintJob, defaults: UserDefaults = .standard) {
        let info = NSPrintInfo(dictionary: [:])
        let printerKey = "lastSystemPrinter"
        if let name = defaults.string(forKey: printerKey),
           NSPrinter.printerNames.contains(name), let printer = NSPrinter(name: name) {
            info.printer = printer
        }
        let operation = makeOperation(for: labels, info: info)
        if operation.run() {
            defaults.set(operation.printInfo.printer.name, forKey: printerKey)
        }
    }

    static func makeOperation(for labels: LabelPrintJob, info: NSPrintInfo) -> NSPrintOperation {
        let pointsPerMillimeter = 72.0 / 25.4
        let size = NSSize(width: 100 * pointsPerMillimeter, height: 150 * pointsPerMillimeter)
        let view = LabelPrintView(labels: labels, size: size)
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
        operation.jobTitle = labels.pageCount == 1 ? "4 × 6 Label" : "4 × 6 Labels"
        operation.showsPrintPanel = true
        return operation
    }

    private final class LabelPrintView: NSView {
        let labels: LabelPrintJob

        init(labels: LabelPrintJob, size: NSSize) {
            self.labels = labels
            super.init(frame: NSRect(origin: .zero, size: size))
        }

        required init?(coder: NSCoder) { nil }

        override func knowsPageRange(_ range: NSRangePointer) -> Bool {
            range.pointee = NSRange(location: 1, length: labels.pageCount)
            return true
        }

        override func rectForPage(_ page: Int) -> NSRect {
            (1...labels.pageCount).contains(page) ? bounds : .zero
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let number = NSPrintOperation.current?.currentPage ?? 1
            guard (1...labels.pageCount).contains(number) else { return }
            switch labels {
            case let .image(label):
                context.draw(label.preview, in: bounds)
            case let .pdf(pdf, _):
                pdf.draw(page: number - 1, in: context, bounds: bounds)
            }
        }
    }
}
