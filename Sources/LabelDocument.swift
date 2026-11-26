import AppKit

enum LabelDocument {
    case image(CGImage)
    case pdf(LabelPDF)

    static func decode(_ data: Data, isPDF: Bool = false) throws -> Self {
        guard data.count <= LabelImage.maximumFileBytes else { throw LabelImageError.tooLarge }
        if isPDF || data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil {
            return .pdf(try LabelPDF(data: data))
        }
        return .image(try LabelImage.decode(data))
    }

    static func load(file: URL) throws -> Self {
        try decode(LabelImage.fileData(at: file), isPDF: file.pathExtension.lowercased() == "pdf")
    }
}

struct LabelPDF {
    enum OpenError: LocalizedError {
        case unreadable, locked, invalidPage(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable: "The PDF could not be opened or contains no pages."
            case .locked: "Unlock the PDF before opening it in Label Printer."
            case let .invalidPage(number): "PDF page \(number) does not have a usable page size."
            }
        }
    }

    private let document: CGPDFDocument
    var pageCount: Int { document.numberOfPages }

    init(data: Data) throws {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
            throw OpenError.unreadable
        }
        guard document.isUnlocked else { throw OpenError.locked }
        guard document.numberOfPages > 0 else { throw OpenError.unreadable }
        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number) else { throw OpenError.invalidPage(number) }
            let box = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
            guard !box.isEmpty, box.origin.x.isFinite, box.origin.y.isFinite,
                  box.width.isFinite, box.height.isFinite else { throw OpenError.invalidPage(number) }
        }
        self.document = document
    }

    func draw(page index: Int, in context: CGContext, bounds: CGRect) {
        guard let page = document.page(at: index + 1) else { return }
        let box = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
        let displaySize = page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let isLandscape = displaySize.width > displaySize.height
        let portraitSize = isLandscape ? CGSize(width: displaySize.height, height: displaySize.width) : displaySize
        let fitted = LabelImage.imageRect(size: portraitSize, framing: .fit, position: 0.5, bounds: bounds)
        let angle: Int32 = isLandscape ? 90 : 0
        context.saveGState()
        context.clip(to: fitted)
        // Quartz centers a small PDF without enlarging it. Scale the PDF's natural size explicitly.
        context.translateBy(x: fitted.minX, y: fitted.minY)
        context.scaleBy(x: fitted.width / portraitSize.width, y: fitted.height / portraitSize.height)
        let naturalBounds = CGRect(origin: .zero, size: portraitSize)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: naturalBounds, rotate: angle, preserveAspectRatio: true))
        context.clip(to: box)
        context.drawPDFPage(page)
        context.restoreGState()
    }

    func raster(page index: Int, resolution: PrinterResolution) throws -> LabelRaster {
        guard (0..<pageCount).contains(index) else { throw OpenError.invalidPage(index + 1) }
        return try LabelImage.render(resolution: resolution) { context, bounds in
            draw(page: index, in: context, bounds: bounds)
        }
    }
}

enum LabelPrintJob {
    case image(LabelRaster)
    case pdf(LabelPDF, PrinterResolution)

    var pageCount: Int {
        switch self {
        case .image: 1
        case let .pdf(pdf, _): pdf.pageCount
        }
    }

    var resolution: PrinterResolution {
        switch self {
        case let .image(raster): raster.resolution
        case let .pdf(_, resolution): resolution
        }
    }

    func raster(page index: Int) throws -> LabelRaster {
        switch self {
        case let .image(raster):
            guard index == 0 else { throw LabelImageError.renderFailed }
            return raster
        case let .pdf(pdf, resolution): return try pdf.raster(page: index, resolution: resolution)
        }
    }
}
