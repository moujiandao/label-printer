import AppKit
import ImageIO
import UniformTypeIdentifiers
import zlib

enum LabelFraming: String, CaseIterable, Identifiable {
    case fill = "Crop to fill"
    case fit = "Fit entire image"

    var id: Self { self }
}

enum LabelImageError: LocalizedError {
    case unreadable, tooLarge, renderFailed, printEncodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "That item does not contain a supported image."
        case .tooLarge: "Choose an image smaller than 50 MB."
        case .renderFailed: "The label image could not be rendered."
        case .printEncodingFailed: "The label could not be encoded for Bluetooth printing."
        }
    }
}

enum LabelImage {
    static let width = 800
    static let height = 1200
    static let aspectRatio = Double(width) / Double(height)
    static let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    static let maximumFileBytes = 50 * 1024 * 1024

    static func load(file: URL) throws -> CGImage {
        guard file.isFileURL else { throw LabelImageError.unreadable }
        let resources = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resources.isRegularFile == true else { throw LabelImageError.unreadable }
        guard (resources.fileSize ?? 0) <= maximumFileBytes else { throw LabelImageError.tooLarge }
        return try decode(Data(contentsOf: file, options: .mappedIfSafe))
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard data.count <= maximumFileBytes else { throw LabelImageError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .image) == true,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary)
        else { throw LabelImageError.unreadable }
        return image
    }

    @MainActor
    static func pasted(from pasteboard: NSPasteboard) throws -> CGImage {
        if let item = pasteboard.pasteboardItems?.first {
            for type in item.types.sorted(by: { $0 == .png && $1 != .png }) {
                guard UTType(type.rawValue)?.conforms(to: .image) == true,
                      let data = item.data(forType: type)
                else { continue }
                do { return try decode(data) }
                catch LabelImageError.unreadable { continue }
            }
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let file = urls.first {
            return try load(file: file)
        }
        throw LabelImageError.unreadable
    }

    static func imageRect(
        size: CGSize, framing: LabelFraming, position: Double, bounds: CGRect = bounds
    ) -> CGRect {
        let widthScale = bounds.width / size.width
        let heightScale = bounds.height / size.height
        let scale = framing == .fill ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let scaledWidth = size.width * scale
        let scaledHeight = size.height * scale
        let amount = min(1, max(0, position))
        let horizontallyCentered = (bounds.width - scaledWidth) / 2
        let verticallyCentered = (bounds.height - scaledHeight) / 2
        return CGRect(
            x: scaledWidth > bounds.width && framing == .fill
                ? (bounds.width - scaledWidth) * amount : horizontallyCentered,
            y: scaledHeight > bounds.height && framing == .fill
                ? (bounds.height - scaledHeight) * (1 - amount) : verticallyCentered,
            width: scaledWidth,
            height: scaledHeight
        )
    }

    static func rotateClockwise(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: image.height, height: image.width, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw LabelImageError.renderFailed }
        context.translateBy(x: 0, y: CGFloat(image.width))
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rotated = context.makeImage() else { throw LabelImageError.renderFailed }
        return rotated
    }

    static func render(
        _ image: CGImage, framing: LabelFraming, position: Double, resolution: PrinterResolution = .standard
    ) throws -> LabelRaster {
        let width = resolution.width
        let height = resolution.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let raw = context.data else { throw LabelImageError.renderFailed }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.interpolationQuality = .high
        let sourceSize = CGSize(width: image.width, height: image.height)
        context.draw(image, in: imageRect(size: sourceSize, framing: framing, position: position, bounds: bounds))

        let pixels = raw.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        let rowBytes = (width + 7) / 8
        // TSPL BITMAP uses 1 for white and 0 for ink, with the leftmost pixel in the high bit.
        var packed = [UInt8](repeating: 0xFF, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * context.bytesPerRow + x
                if pixels[index] < 160 {
                    pixels[index] = 0
                    packed[y * rowBytes + x / 8] &= ~(UInt8(0x80) >> (x % 8))
                } else {
                    pixels[index] = 255
                }
            }
        }
        guard let preview = context.makeImage() else { throw LabelImageError.renderFailed }
        return LabelRaster(preview: preview, bitmap: Data(packed), rowBytes: rowBytes, resolution: resolution)
    }
}

struct LabelRaster {
    let preview: CGImage
    let bitmap: Data
    let rowBytes: Int
    let resolution: PrinterResolution

    func printJob(for profile: PrinterProfile) throws -> Data {
        if profile.language == .zpl { return zplJob() }
        let payload: Data
        let bitmapMode: String
        if profile.usesNelkoBitmapCompression {
            payload = try nelkoCompressedBitmap()
            bitmapMode = "3,\(payload.count)"
        } else {
            payload = bitmap
            bitmapMode = "0"
        }
        let commands = [
            "SIZE 100 mm,150 mm", "GAP 2 mm,0 mm", "DIRECTION 0,0",
            "SPEED 4", "DENSITY 6", "CLS",
            "BITMAP 0,0,\(rowBytes),\(preview.height),\(bitmapMode),"
        ].joined(separator: "\r\n")
        var job = Data(commands.utf8)
        job.append(payload)
        job.append(contentsOf: "\r\nPRINT 1,1\r\n".utf8)
        return job
    }

    private func nelkoCompressedBitmap() throws -> Data {
        // The vendor's TSPL mode 3 sends zlib data with one bits for ink.
        let pixels = bitmap.map { ~$0 }
        let sourceLength = uLong(pixels.count)
        var compressedLength = compressBound(sourceLength)
        var compressed = [UInt8](repeating: 0, count: Int(compressedLength))
        guard compress(&compressed, &compressedLength, pixels, sourceLength) == Z_OK else {
            throw LabelImageError.printEncodingFailed
        }
        return Data(compressed.prefix(Int(compressedLength)))
    }

    private func zplJob() -> Data {
        var job = Data("^XA^PON^LH0,0^PW\(preview.width)^LL\(preview.height)".utf8)
        // Zebra allows at most 99,999 bytes per graphic field. Keep every strip on whole rows.
        let maximumRows = 99_999 / rowBytes
        for row in stride(from: 0, to: preview.height, by: maximumRows) {
            let rowCount = min(maximumRows, preview.height - row)
            let byteCount = rowCount * rowBytes
            let start = row * rowBytes
            job.append(contentsOf: "^FO0,\(row)^GFB,\(byteCount),\(byteCount),\(rowBytes),".utf8)
            job.append(contentsOf: bitmap[start..<(start + byteCount)].map { ~$0 })
            job.append(contentsOf: "^FS".utf8)
        }
        job.append(contentsOf: "^PQ1^XZ".utf8)
        return job
    }

    func writePNG(to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw LabelImageError.renderFailed }
        CGImageDestinationAddImage(destination, preview, [
            kCGImagePropertyDPIWidth: resolution.actualDPI,
            kCGImagePropertyDPIHeight: resolution.actualDPI
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LabelImageError.renderFailed }
        try (data as Data).write(to: url, options: .atomic)
    }
}
