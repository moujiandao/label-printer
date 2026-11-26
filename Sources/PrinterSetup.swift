import SwiftUI

struct PrinterSetupView: View {
    @ObservedObject var printer: PrinterConnection
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEndpoint: PrinterEndpoint?
    @State private var language: PrinterLanguage?
    @State private var resolution: PrinterResolution = .standard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bluetooth Printer Setup").font(.title2.weight(.semibold))
            if let device = printer.setupPrinter, printer.phase == .setupReady {
                configuration(device)
            } else {
                discovery
            }
            HStack {
                Button(printer.profile == nil ? "Cancel" : "Use Saved Printer") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if printer.phase == .setupReady {
                    Button("Choose Another Device", action: printer.scanForSetup)
                    Button("Save Printer") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(language == nil || selectedEndpoint == nil)
                } else {
                    Button("Scan Again", action: printer.scanForSetup)
                        .disabled(printer.phase.isConnecting && printer.phase != .searching)
                }
            }
        }
        .padding(22)
        .frame(width: 590, height: 445)
        .onChange(of: printer.endpoints) { _, endpoints in
            let knownNelko = printer.setupPrinter?.isNelko == true && endpoints.contains(.nelko)
            selectedEndpoint = knownNelko ? .nelko : nil
            language = knownNelko ? .tspl : nil
            resolution = .standard
        }
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(printer.setupMessage ?? scanDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
            if printer.phase.isConnecting {
                ProgressView(printer.phase.title).controlSize(.small)
            }
            if printer.setupPrinter == nil {
                List(printer.nearbyPrinters) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                            Text(device.isNelko ? "Nelko preset available" : String(device.id.uuidString.suffix(8)))
                                .monospaced().font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Select") { printer.inspect(device) }
                            .accessibilityLabel("Select \(device.name)")
                    }
                }
                .overlay {
                    if printer.nearbyPrinters.isEmpty && printer.phase == .choosing {
                        Text("No devices found").foregroundStyle(.secondary)
                    }
                }
            } else {
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func configuration(_ device: PrinterConnection.NearbyPrinter) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(device.name).font(.headline)
            Text(device.isNelko && printer.endpoints.contains(.nelko)
                 ? "The Nelko print endpoint and TSPL are preselected."
                 : "Use your printer’s documentation to select its print endpoint and command language.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Command language", selection: $language) {
                Text("Select TSPL or ZPL").tag(nil as PrinterLanguage?)
                ForEach(PrinterLanguage.allCases) { item in Text(item.rawValue).tag(Optional(item)) }
            }
            Picker("Resolution", selection: $resolution) {
                ForEach(PrinterResolution.allCases) { item in Text(item.title).tag(item) }
            }
            Text("Bluetooth write endpoint").font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(printer.endpoints) { endpoint in
                        Button {
                            selectedEndpoint = endpoint
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: selectedEndpoint == endpoint ? "largecircle.fill.circle" : "circle")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(endpoint == .nelko ? "Transparent UART write" : "Characteristic \(endpoint.characteristic)")
                                    Text(endpoint == .nelko
                                         ? endpoint.characteristic : "Service \(endpoint.service)")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .font(.caption.monospaced())
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedEndpoint == endpoint ? .isSelected : [])
                    }
                }
            }
            if let message = printer.setupMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var scanDescription: String {
        switch printer.phase {
        case .starting: "Allow Bluetooth access if macOS asks."
        case .bluetoothOff: "Turn on Bluetooth in System Settings."
        case .denied: "Allow Label Printer in System Settings → Privacy & Security → Bluetooth."
        default: "Turn on your label printer and select it from nearby devices."
        }
    }

    private func save() {
        guard let selectedEndpoint, let language else { return }
        if printer.saveSetup(endpoint: selectedEndpoint, language: language, resolution: resolution) {
            dismiss()
        }
    }
}
