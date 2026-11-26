import AppKit
import UniformTypeIdentifiers
import zlib

@main
struct OfflineChecks {
    @MainActor
    static func main() async throws {
        try verifyReconnectEligibility()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("Synthetic label.png")
        let image = try makeImage()
        let original = try LabelImage.render(image, framing: .fill, position: 0.5)
        try original.writePNG(to: file)
        let png = try Data(contentsOf: file)
        let imported = try LabelImage.load(file: file)
        try require(imported.width == 800 && imported.height == 1200, "Exported PNG is 800 by 1200 pixels")
        let roundTrip = try LabelImage.render(imported, framing: .fill, position: 0.5)
        try require(roundTrip.bitmap == original.bitmap, "PNG and printer raster use the same pixels")

        try require(
            original.bitmap[40 * original.rowBytes + 5] == 0x00 &&
                original.bitmap[40 * original.rowBytes + 90] == 0xFF &&
                original.bitmap[900 * original.rowBytes + 5] == 0xFF,
            "TSPL rows are top-down, with black as zero and white as one"
        )

        let header = "SIZE 100 mm,150 mm\r\nGAP 2 mm,0 mm\r\nDIRECTION 0,0\r\nSPEED 4\r\nDENSITY 6\r\nCLS\r\nBITMAP 0,0,100,1200,0,"
        let trailer = "\r\nPRINT 1,1\r\n"
        let genericTSPL = PrinterProfile(
            identifier: UUID(), name: "Synthetic printer", endpoint: .nelko,
            language: .tspl, resolution: .standard
        )
        let job = try original.printJob(for: genericTSPL)
        try require(job.starts(with: header.utf8), "Print job declares correct physical size and bytes per row")
        try require(job.suffix(trailer.utf8.count) == Data(trailer.utf8), "Print job requests exactly one copy")
        try require(
            Data(job.dropFirst(header.utf8.count).dropLast(trailer.utf8.count)) == original.bitmap,
            "Print payload embeds all bitmap bytes unchanged"
        )
        try verifyNelko(original, trailer: trailer)

        let fit = LabelImage.imageRect(size: CGSize(width: 1600, height: 1200), framing: .fit, position: 0.5)
        let fillLeft = LabelImage.imageRect(size: CGSize(width: 1600, height: 1200), framing: .fill, position: 0)
        let fillRight = LabelImage.imageRect(size: CGSize(width: 1600, height: 1200), framing: .fill, position: 1)
        try require(fit == CGRect(x: 0, y: 300, width: 800, height: 600), "Fit preserves the entire image")
        try require(fillLeft.minX == 0 && fillRight.maxX == 800, "Horizontal crop can reach both edges")
        let fillTop = LabelImage.imageRect(size: CGSize(width: 400, height: 1200), framing: .fill, position: 0)
        let fillBottom = LabelImage.imageRect(size: CGSize(width: 400, height: 1200), framing: .fill, position: 1)
        try require(fillTop.maxY == 1200 && fillBottom.minY == 0, "Vertical crop can reach both edges")
        let rotated = try LabelImage.rotateClockwise(image)
        try require(rotated.width == image.height && rotated.height == image.width, "Rotate swaps source axes")

        let highResolution = try LabelImage.render(image, framing: .fill, position: 0.5, resolution: .high)
        try require(highResolution.preview.width == 1200 && highResolution.preview.height == 1800, "300 dpi uses 12 dots per millimeter")
        try verifyZPL(original)
        try verifyZPL(highResolution)
        try verifyPrinterPreferences()

        let pasteboard = NSPasteboard(name: .init("LabelPrinter.Tests." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let pasted = try LabelImage.pasted(from: pasteboard)
        try require(pasted.width == 800 && pasted.height == 1200, "Clipboard PNG can be pasted")
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let pastedFile = try LabelImage.pasted(from: pasteboard)
        try require(pastedFile.width == 800 && pastedFile.height == 1200, "Copied Finder image file can be pasted")
        pasteboard.clearContents()
        pasteboard.setString("Text only", forType: .string)
        do {
            _ = try LabelImage.pasted(from: pasteboard)
            throw CheckFailed(message: "Text-only clipboard should be rejected")
        } catch LabelImageError.unreadable {}

        let provider = NSItemProvider(object: file as NSURL)
        let editor = LabelEditor()
        try require(editor.acceptDrop([provider]), "Finder file representation is accepted as a drop")
        try await waitForImport(editor)
        try require(editor.raster?.bitmap == original.bitmap, "Dropped file appears in the print preview")

        let imageProvider = NSItemProvider()
        let missingFile = directory.appendingPathComponent("Missing png.png")
        imageProvider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { callback in
            callback(missingFile.dataRepresentation, nil)
            return nil
        }
        imageProvider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { callback in
            callback(png, nil)
            return nil
        }
        try require(editor.acceptDrop([imageProvider]), "Drop can offer both file URL and PNG data")
        try await waitForImport(editor)
        try require(editor.raster?.bitmap == original.bitmap, "Dropped PNG data is used when the file URL fails")

        let brokenProvider = NSItemProvider(object: missingFile as NSURL)
        try require(editor.acceptDrop([brokenProvider]), "Replacement drop opens the import path")
        try await waitForImport(editor)
        try require(editor.errorMessage != nil && editor.raster == nil, "Failed replacement clears the old printable label")
        print("Offline image, clipboard, drop, crop, PNG, TSPL, Nelko Bluetooth, ZPL and printer preference checks passed.")
    }

    static func verifyReconnectEligibility() throws {
        for phase in [PrinterConnection.Phase.idle, .offline] {
            try require(phase.shouldAttemptConnection(hasConnectedEndpoint: false), "A session can connect when idle or offline")
        }
        for phase in [PrinterConnection.Phase.starting, .searching, .connecting, .discovering, .reconnecting] {
            try require(!phase.shouldAttemptConnection(hasConnectedEndpoint: false), "A session keeps the current connection attempt")
        }
        try require(
            !PrinterConnection.Phase.ready.shouldAttemptConnection(hasConnectedEndpoint: true),
            "A session keeps the connected printer"
        )
        try require(
            PrinterConnection.Phase.ready.shouldAttemptConnection(hasConnectedEndpoint: false),
            "A session retries when the app still shows a printer whose connection is gone"
        )
    }

    @MainActor
    static func waitForImport(_ editor: LabelEditor) async throws {
        for _ in 0..<100 where editor.isImporting {
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(!editor.isImporting, "Import completed before the test deadline")
    }

    static func makeImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: 80, height: 120, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw CheckFailed(message: "Could not create synthetic image") }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 120))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 100, width: 20, height: 20))
        guard let image = context.makeImage() else { throw CheckFailed(message: "Could not load synthetic image") }
        return image
    }

    static func verifyNelko(_ label: LabelRaster, trailer: String) throws {
        let domain = "LabelPrinter.Tests." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw CheckFailed(message: "Could not open isolated test preferences")
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(UUID().uuidString, forKey: "connectedPL70eIdentifier")
        guard let profile = PrinterProfile.load(from: defaults) else {
            throw CheckFailed(message: "Could not load the existing Nelko profile")
        }
        let job = try label.printJob(for: profile)
        let header = "SIZE 100 mm,150 mm\r\nGAP 2 mm,0 mm\r\nDIRECTION 0,0\r\nSPEED 4\r\nDENSITY 6\r\nCLS\r\nBITMAP 0,0,100,1200,3,"
        try require(job.starts(with: header.utf8), "Nelko Bluetooth uses bitmap mode 3 at 4 × 6")
        let body = job.dropFirst(header.utf8.count)
        guard let separator = body.firstIndex(of: 44),
              let encodedLength = Int(String(decoding: body[..<separator], as: UTF8.self)),
              encodedLength > 0 else {
            throw CheckFailed(message: "Nelko bitmap is missing its compressed byte count")
        }
        let payload = body.dropFirst(separator - body.startIndex + 1)
        try require(payload.dropFirst(encodedLength).elementsEqual(trailer.utf8), "Compressed byte count ends at the single-copy command")
        let compressed = Array(payload.prefix(encodedLength))
        var decoded = [UInt8](repeating: 0, count: label.bitmap.count)
        var decodedLength = uLongf(decoded.count)
        let result = uncompress(&decoded, &decodedLength, compressed, uLong(compressed.count))
        try require(result == Z_OK && decodedLength == label.bitmap.count, "Nelko payload is a complete zlib bitmap")
        try require(decoded.elementsEqual(label.bitmap.lazy.map { ~$0 }), "Nelko compressed pixels use one for ink and zero for white")
        print("Nelko Bluetooth synthetic bitmap: \(label.bitmap.count) raw bytes, \(encodedLength) compressed bytes.")
    }

    static func verifyZPL(_ label: LabelRaster) throws {
        let profile = PrinterProfile(
            identifier: UUID(), name: "PL70e-BT_TEST-LE", endpoint: .nelko,
            language: .zpl, resolution: label.resolution
        )
        var job = try label.printJob(for: profile)[...]
        let header = "^XA^PON^LH0,0^PW\(label.preview.width)^LL\(label.preview.height)"
        try require(job.starts(with: header.utf8), "ZPL declares the intended raster dimensions")
        job = job.dropFirst(header.utf8.count)
        var nextRow = 0
        var actualBitmap = Data()
        while job.starts(with: "^FO0,".utf8) {
            let commaIndices = job.indices.lazy.filter { job[$0] == 44 }.prefix(5)
            guard let lastComma = commaIndices.last,
                  let field = String(data: job[...lastComma], encoding: .ascii) else {
                throw CheckFailed(message: "ZPL graphic field is missing")
            }
            let columns = field.split(separator: ",")
            guard columns.count == 5, let marker = columns[1].range(of: "^GFB"),
                  let startingRow = Int(columns[1][..<marker.lowerBound]),
                  let byteCount = Int(columns[2]), let graphicCount = Int(columns[3]), let bytesPerRow = Int(columns[4])
            else { throw CheckFailed(message: "Invalid ZPL graphic field header") }
            try require(startingRow == nextRow, "ZPL strips occupy consecutive rows")
            try require(
                (1...99_999).contains(byteCount) && graphicCount == byteCount &&
                    bytesPerRow == label.rowBytes && byteCount % bytesPerRow == 0,
                "ZPL fields stay within the documented limit and use whole rows"
            )
            job = job[(lastComma + 1)...]
            actualBitmap.append(contentsOf: job.prefix(byteCount))
            job = job.dropFirst(byteCount)
            try require(job.starts(with: "^FS".utf8), "Each binary strip ends at the declared byte count")
            job = job.dropFirst("^FS".utf8.count)
            nextRow += byteCount / bytesPerRow
        }
        try require(nextRow == label.preview.height, "ZPL contains every row")
        try require(job.elementsEqual("^PQ1^XZ".utf8), "ZPL requests one label")
        try require(actualBitmap.elementsEqual(label.bitmap.lazy.map { ~$0 }), "ZPL inverts TSPL pixel polarity")
    }

    static func verifyPrinterPreferences() throws {
        let domain = "LabelPrinter.Tests." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw CheckFailed(message: "Could not open isolated test preferences")
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        try require(PrinterProfile.load(from: defaults) == nil, "A new installation has no selected printer")
        let oldID = UUID()
        defaults.set(oldID.uuidString, forKey: "connectedPL70eIdentifier")
        let oldProfile = PrinterProfile.load(from: defaults)
        try require(
            oldProfile?.identifier == oldID && oldProfile?.endpoint == .nelko &&
                oldProfile?.language == .tspl && oldProfile?.resolution == .standard,
            "The old Nelko preference keeps its device, endpoint, format, and resolution"
        )
        let current = PrinterProfile(
            identifier: UUID(), name: "Synthetic printer",
            endpoint: PrinterEndpoint(service: "FDE0", characteristic: "FDE1"),
            language: .zpl, resolution: .high
        )
        try current.save(to: defaults)
        try require(PrinterProfile.load(from: defaults) == current, "The saved profile takes precedence over the previous Nelko preference")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailed(message: message) }
    }

    struct CheckFailed: Error {
        let message: String
    }
}
