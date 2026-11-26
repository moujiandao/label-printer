import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct LabelPrinterApp: App {
    @StateObject private var editor = LabelEditor()
    @StateObject private var printer = PrinterConnection()

    var body: some Scene {
        Window("Label Printer", id: "label-printer") {
            LabelPrinterView(editor: editor, printer: printer)
                .frame(minWidth: 740, minHeight: 560)
                .background { PasteShortcut(action: editor.paste) }
                .onAppear {
                    editor.resolution = printer.profile?.resolution ?? .standard
                    printer.connectIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    printer.connectIfNeeded()
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    printer.connectIfNeeded()
                }
                .onChange(of: printer.profile?.resolution) { _, resolution in
                    editor.resolution = resolution ?? .standard
                }
        }
        .defaultSize(width: 860, height: 650)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Image or PDF…", action: editor.chooseFile)
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save PNG…", action: editor.savePNG)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(editor.raster == nil || editor.isImporting)
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste Image", action: editor.paste)
            }
        }
    }
}

private struct PasteShortcut: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }

    func updateNSView(_ view: ShortcutView, context: Context) {
        view.paste = action
    }

    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) {
        view.removeMonitor()
    }

    final class ShortcutView: NSView {
        var paste: (@MainActor () -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      event.charactersIgnoringModifiers?.lowercased() == "v"
                else { return event }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .subtracting([.capsLock, .numericPad])
                guard modifiers == .command || modifiers == .control else { return event }
                self.paste?()
                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

struct LabelPrinterView: View {
    @ObservedObject var editor: LabelEditor
    @ObservedObject var printer: PrinterConnection
    @State private var isDropTarget = false
    @State private var showingPrinterSetup = false

    private let accent = Color(red: 0.11, green: 0.38, blue: 0.33)
    private let border = Color.primary.opacity(0.11)
    private let canvas = Color(nsColor: .controlBackgroundColor)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 18) {
                preview
                tools
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .sheet(isPresented: $showingPrinterSetup, onDismiss: printer.cancelSetup) {
            PrinterSetupView(printer: printer)
                .onAppear(perform: printer.beginSetup)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(accent)
                .font(.title2)
                .frame(width: 40, height: 40)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Shipping label").font(.title2.weight(.semibold))
                Text("4 × 6  ·  100 × 150 mm")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(printer.phase == .ready ? .green : Color.secondary.opacity(0.55))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(printer.phase.title)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 11)
            .background(canvas, in: Capsule())
            .overlay { Capsule().strokeBorder(border, lineWidth: 1) }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Print preview").font(.headline)
                Spacer()
                if editor.pageCount > 1 {
                    Button {
                        editor.selectPage(editor.pageIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Previous page")
                    .disabled(editor.pageIndex == 0 || editor.isImporting)
                    Text("Page \(editor.pageIndex + 1) of \(editor.pageCount)")
                        .font(.subheadline.monospacedDigit())
                    Button {
                        editor.selectPage(editor.pageIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityLabel("Next page")
                    .disabled(editor.pageIndex == editor.pageCount - 1 || editor.isImporting)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isDropTarget ? accent.opacity(0.15) : canvas)
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isDropTarget ? accent : border,
                        style: StrokeStyle(lineWidth: isDropTarget ? 2 : 1, dash: editor.raster == nil ? [6, 4] : [])
                    )
                if let raster = editor.raster {
                    Image(raster.preview, scale: 1, label: Text("Black and white 4 by 6 label preview"))
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.17), radius: 7, x: 0, y: 4)
                        .padding(22)
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: "arrow.down.document")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                        Text("Drop a label image or PDF here").font(.title3.weight(.semibold))
                        Text("Or paste an image with ⌘V or Ctrl+V").foregroundStyle(.secondary)
                        Button("Paste Image", action: editor.paste)
                            .controlSize(.large)
                            .padding(.top, 4)
                    }
                    .padding(18)
                }
                if editor.isImporting {
                    ProgressView("Loading label…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL, .image, .pdf], isTargeted: $isDropTarget, perform: editor.acceptDrop)
            if let error = editor.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
            } else if let info = editor.infoMessage {
                Text(info).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(editor.raster == nil ? "Files stay on this Mac." : "Drop an image or PDF to replace this label.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Label").font(.headline)
                HStack(spacing: 8) {
                    Button("Paste Image", systemImage: "clipboard", action: editor.paste)
                    Button("Open…", systemImage: "folder", action: editor.chooseFile)
                }
            }
            if !editor.isPDF {
                Divider()
                imageFraming
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Printer").font(.headline)
                if let profile = printer.profile {
                    Text(profile.name).font(.subheadline.weight(.medium))
                    Text("\(profile.language.rawValue) · \(profile.resolution.title)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reconnect Printer", systemImage: "arrow.clockwise", action: printer.reconnect)
                        .disabled(!printer.canReconnect)
                }
                Button(printer.profile == nil ? "Add Bluetooth Printer…" : "Change Bluetooth Printer…") {
                    showingPrinterSetup = true
                }
                .disabled(printer.progress != nil || printer.phase == .reconnecting)
                if let description = connectionDescription {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 5)
            if let progress = printer.progress {
                ProgressView(printer.printProgressTitle, value: progress)
            } else if let message = printer.printMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(printer.printFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if let job = editor.printJob { printer.printLabels(job) }
            } label: {
                Label(editor.pageCount > 1 ? "Print \(editor.pageCount) Labels" : "Print Label", systemImage: "printer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(editor.raster == nil || editor.isImporting || printer.phase != .ready || printer.progress != nil)
            Button("System Print…", systemImage: "printer") {
                if let job = editor.printJob { SystemPrinting.openPrintDialog(for: job) }
            }
            .disabled(editor.raster == nil || editor.isImporting || printer.progress != nil)
            Button("Save PNG…", systemImage: "square.and.arrow.down", action: editor.savePNG)
                .disabled(editor.raster == nil || editor.isImporting)
        }
        .padding(17)
        .frame(width: 255)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(canvas, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 1) }
    }

    private var imageFraming: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Framing").font(.headline)
            Picker("Framing", selection: $editor.framing) {
                ForEach(LabelFraming.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }.labelsHidden()
            if editor.canAdjustCrop {
                Slider(value: $editor.position, in: 0...1) { Text("Crop position") }
                    .accessibilityLabel("Crop position")
                Text("Use Fit entire image if the crop cuts off text or barcodes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Rotate", systemImage: "rotate.right", action: editor.rotate)
                Button("Reset", action: editor.resetCrop)
            }
        }
        .disabled(editor.image == nil || editor.isImporting)
    }

    private var connectionDescription: String? {
        switch printer.phase {
        case .idle: printer.profile == nil ? "Use System Print for printers added to your Mac." : "Label Printer automatically tries to connect to your saved printer."
        case .starting: "Allow Bluetooth access if macOS asks."
        case .offline: "Check that the printer is on, nearby, and available."
        case .denied: "Allow Label Printer in System Settings → Privacy & Security → Bluetooth."
        case .bluetoothOff: "Turn on Bluetooth to connect your printer."
        case .incompatible: "The printer did not expose its expected Bluetooth write service."
        default: nil
        }
    }
}
