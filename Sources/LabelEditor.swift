import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class LabelEditor: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var raster: LabelRaster?
    @Published private(set) var isImporting = false
    @Published private(set) var pageIndex = 0
    var resolution: PrinterResolution = .standard {
        didSet {
            if resolution != oldValue { render() }
        }
    }
    @Published var framing: LabelFraming = .fill { didSet { render() } }
    @Published var position = 0.5 { didSet { render() } }
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    private var document: LabelDocument?
    private var importID = UUID()
    private var pendingDrop: ArraySlice<DropRepresentation> = []

    private struct DropRepresentation {
        let provider: NSItemProvider
        let type: String
        let isFile: Bool
        let isPDF: Bool

        var priority: Int {
            if isFile { return 0 }
            return isPDF ? 1 : 2
        }
    }

    var canAdjustCrop: Bool {
        guard let image else { return false }
        let ratio = Double(image.width) / Double(image.height)
        return framing == .fill && abs(ratio - LabelImage.aspectRatio) > 0.001
    }

    var pageCount: Int {
        if case let .pdf(pdf) = document { return pdf.pageCount }
        return raster == nil ? 0 : 1
    }

    var isPDF: Bool {
        if case .pdf = document { return true }
        return false
    }

    var printJob: LabelPrintJob? {
        guard !isImporting, let raster else { return nil }
        if case let .pdf(pdf) = document { return .pdf(pdf, resolution) }
        return .image(raster)
    }

    func paste() {
        importNow {
            .image(try LabelImage.pasted(from: .general))
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.begin { [weak self] response in
            guard response == .OK, let file = panel.url else { return }
            self?.load(file: file)
        }
    }

    func load(file: URL) {
        importNow { try LabelDocument.load(file: file) }
    }

    func selectPage(_ index: Int) {
        guard !isImporting, isPDF, (0..<pageCount).contains(index), index != pageIndex else { return }
        pageIndex = index
        render()
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileType = UTType.fileURL.identifier
        let representations = providers.flatMap { provider in
            provider.registeredTypeIdentifiers.compactMap { type -> DropRepresentation? in
                let isFile = type == fileType
                let contentType = UTType(type)
                let isPDF = contentType?.conforms(to: .pdf) == true
                guard isFile || isPDF || contentType?.conforms(to: .image) == true else { return nil }
                return DropRepresentation(provider: provider, type: type, isFile: isFile, isPDF: isPDF)
            }.sorted { $0.priority < $1.priority }
        }
        guard !representations.isEmpty else { return false }

        let requestID = beginImport()
        pendingDrop = representations[...]
        loadNextDropRepresentation(id: requestID)
        return true
    }

    private func loadNextDropRepresentation(id: UUID) {
        guard let item = pendingDrop.popFirst() else { return }
        let isPDF = item.isPDF
        let isFile = item.isFile
        item.provider.loadDataRepresentation(forTypeIdentifier: item.type) { [weak self] data, error in
            let payload = Result {
                guard let data else { throw error ?? LabelImageError.unreadable }
                guard isFile else { return (data, isPDF) }
                guard let url = URL(dataRepresentation: data, relativeTo: nil)
                else { throw LabelImageError.unreadable }
                return (try LabelImage.fileData(at: url), url.pathExtension.lowercased() == "pdf")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.importID == id else { return }
                let result = payload.flatMap { data, isPDF in
                    Result { try LabelDocument.decode(data, isPDF: isPDF) }
                }
                if case .failure = result, !self.pendingDrop.isEmpty {
                    self.loadNextDropRepresentation(id: id)
                } else {
                    self.completeImport(result, id: id)
                }
            }
        }
    }

    func rotate() {
        guard let image else { return }
        do {
            self.image = try LabelImage.rotateClockwise(image)
            position = 0.5
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetCrop() {
        guard case let .image(original) = document else { return }
        image = original
        framing = .fill
        position = 0.5
    }

    func savePNG() {
        guard let raster else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = pageCount > 1 ? "Label-4x6-Page-\(pageIndex + 1).png" : "Label-4x6.png"
        panel.prompt = "Save PNG"
        panel.begin { [weak self] response in
            guard response == .OK, let file = panel.url else { return }
            do {
                try raster.writePNG(to: file)
                self?.errorMessage = nil
                self?.infoMessage = "Saved \(file.lastPathComponent)"
            } catch {
                self?.infoMessage = nil
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func importNow(_ read: () throws -> LabelDocument) {
        let id = beginImport()
        completeImport(Result(catching: read), id: id)
    }

    private func beginImport() -> UUID {
        importID = UUID()
        pendingDrop = []
        isImporting = true
        errorMessage = nil
        infoMessage = nil
        return importID
    }

    private func completeImport(_ result: Result<LabelDocument, Error>, id: UUID) {
        guard id == importID else { return }
        isImporting = false
        pendingDrop = []
        pageIndex = 0
        switch result {
        case let .success(imported):
            document = imported
            if case .image = imported {
                resetCrop()
            } else {
                image = nil
                render()
            }
        case let .failure(error):
            document = nil
            image = nil
            raster = nil
            errorMessage = error.localizedDescription
        }
    }

    private func render() {
        do {
            if case let .pdf(pdf) = document {
                raster = try pdf.raster(page: pageIndex, resolution: resolution)
            } else if let image {
                raster = try LabelImage.render(image, framing: framing, position: position, resolution: resolution)
            } else {
                raster = nil
                return
            }
            errorMessage = nil
            infoMessage = nil
        } catch {
            raster = nil
            errorMessage = error.localizedDescription
        }
    }
}
