import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class LabelEditor: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var raster: LabelRaster?
    @Published private(set) var isImporting = false
    var resolution: PrinterResolution = .standard {
        didSet {
            if resolution != oldValue { render() }
        }
    }
    @Published var framing: LabelFraming = .fill { didSet { render() } }
    @Published var position = 0.5 { didSet { render() } }
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    private var original: CGImage?
    private var importID = UUID()
    private var pendingDrop: ArraySlice<DropRepresentation> = []

    private struct DropRepresentation {
        let provider: NSItemProvider
        let type: String
        let isFile: Bool
    }

    var canAdjustCrop: Bool {
        guard let image else { return false }
        let ratio = Double(image.width) / Double(image.height)
        return framing == .fill && abs(ratio - LabelImage.aspectRatio) > 0.001
    }

    func paste() {
        importNow {
            try LabelImage.pasted(from: .general)
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Image"
        panel.begin { [weak self] response in
            guard response == .OK, let file = panel.url else { return }
            self?.importNow { try LabelImage.load(file: file) }
        }
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileType = UTType.fileURL.identifier
        let representations = providers.flatMap { provider in
            provider.registeredTypeIdentifiers.compactMap { type -> DropRepresentation? in
                let isFile = type == fileType
                guard isFile || UTType(type)?.conforms(to: .image) == true else { return nil }
                return DropRepresentation(provider: provider, type: type, isFile: isFile)
            }.sorted { $0.isFile && !$1.isFile }
        }
        guard !representations.isEmpty else { return false }

        let requestID = beginImport()
        pendingDrop = representations[...]
        loadNextDropRepresentation(id: requestID)
        return true
    }

    private func loadNextDropRepresentation(id: UUID) {
        guard let item = pendingDrop.popFirst() else { return }
        let isFile = item.isFile
        item.provider.loadDataRepresentation(forTypeIdentifier: item.type) { [weak self] data, error in
            let result = Result {
                guard let data else { throw error ?? LabelImageError.unreadable }
                if isFile {
                    guard let url = URL(dataRepresentation: data, relativeTo: nil)
                    else { throw LabelImageError.unreadable }
                    return try LabelImage.load(file: url)
                }
                return try LabelImage.decode(data)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.importID == id else { return }
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
        image = original
        framing = .fill
        position = 0.5
    }

    func savePNG() {
        guard let raster else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Label-4x6.png"
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

    private func importNow(_ read: () throws -> CGImage) {
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

    private func completeImport(_ result: Result<CGImage, Error>, id: UUID) {
        guard id == importID else { return }
        isImporting = false
        pendingDrop = []
        switch result {
        case let .success(imported):
            original = imported
            resetCrop()
        case let .failure(error):
            original = nil
            image = nil
            raster = nil
            errorMessage = error.localizedDescription
        }
    }

    private func render() {
        guard let image else {
            raster = nil
            return
        }
        do {
            raster = try LabelImage.render(image, framing: framing, position: position, resolution: resolution)
            errorMessage = nil
            infoMessage = nil
        } catch {
            raster = nil
            errorMessage = error.localizedDescription
        }
    }
}
