import Foundation

enum PrinterLanguage: String, CaseIterable, Codable, Identifiable {
    case tspl = "TSPL"
    case zpl = "ZPL"

    var id: Self { self }
}

enum PrinterResolution: Int, CaseIterable, Codable, Identifiable {
    case standard = 8
    case high = 12

    var id: Self { self }
    var title: String { self == .standard ? "203 dpi" : "300 dpi" }
    var width: Int { 100 * rawValue }
    var height: Int { 150 * rawValue }
    var actualDPI: Double { Double(rawValue) * 25.4 }
}

struct PrinterEndpoint: Codable, Hashable, Identifiable {
    let service: String
    let characteristic: String

    var id: Self { self }

    // BEEPRT and Nelko use the Transparent UART RX characteristic.
    static let nelko = Self(
        service: "49535343-FE7D-4AE5-8FA9-9FAFD205E455",
        characteristic: "49535343-8841-43F4-A8D4-ECBE34729BB3"
    )
}

struct PrinterProfile: Codable, Equatable {
    let identifier: UUID
    let name: String
    let endpoint: PrinterEndpoint
    let language: PrinterLanguage
    let resolution: PrinterResolution

    private static let storageKey = "bluetoothPrinterProfile"
    private static let legacyKey = "connectedPL70eIdentifier"

    var usesNelkoBitmapCompression: Bool {
        language == .tspl && endpoint == .nelko && Self.isNelkoModel(name)
    }

    static func isNelkoModel(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("PL70e-BT")
    }

    static func load(from defaults: UserDefaults) -> Self? {
        if let saved = defaults.data(forKey: storageKey) {
            return try? JSONDecoder().decode(Self.self, from: saved)
        }
        guard let legacy = defaults.string(forKey: legacyKey).flatMap(UUID.init(uuidString:)) else { return nil }
        return Self(identifier: legacy, name: "Nelko PL70e-BT", endpoint: .nelko, language: .tspl, resolution: .standard)
    }

    func save(to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}
