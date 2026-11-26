import Combine
import CoreBluetooth
import Foundation

@MainActor
final class PrinterConnection: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle, starting, searching, choosing, connecting, discovering, setupReady, ready, offline
        case bluetoothOff, denied, incompatible

        var title: String {
            switch self {
            case .idle: "Printer disconnected"
            case .starting: "Starting Bluetooth"
            case .searching: "Looking for printer"
            case .choosing: "Select a Bluetooth printer"
            case .connecting, .discovering: "Connecting to printer"
            case .setupReady: "Select a print endpoint"
            case .ready: "Printer connected"
            case .offline: "Printer out of reach"
            case .bluetoothOff: "Bluetooth is off"
            case .denied: "Bluetooth permission needed"
            case .incompatible: "Printer service unavailable"
            }
        }

        var isConnecting: Bool {
            self == .starting || self == .searching || self == .connecting || self == .discovering
        }
    }

    struct NearbyPrinter: Identifiable {
        let id: UUID
        let name: String

        var isNelko: Bool { PrinterProfile.isNelkoModel(name) }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double?
    @Published private(set) var printMessage: String?
    @Published private(set) var printFailed = false
    @Published private(set) var profile: PrinterProfile?
    @Published private(set) var nearbyPrinters: [NearbyPrinter] = []
    @Published private(set) var setupPrinter: NearbyPrinter?
    @Published private(set) var endpoints: [PrinterEndpoint] = []
    @Published private(set) var setupMessage: String?

    private let defaults: UserDefaults
    private var central: CBCentralManager?
    private var target: CBPeripheral?
    private var endpoint: CBCharacteristic?
    private var schedule: DispatchWorkItem?
    private var printTimeout: DispatchWorkItem?
    private var transfer: Transfer?
    private var isSettingUp = false
    private var nearbyPeripherals: [UUID: CBPeripheral] = [:]
    private var pendingServices: Set<CBUUID> = []
    private var writableCharacteristics: [PrinterEndpoint: CBCharacteristic] = [:]

    private struct Transfer {
        let job: Data
        let writeType: CBCharacteristicWriteType
        let chunkSize: Int
        var offset = 0
        var waitingForCapacity = false
        var token = UUID()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.profile = PrinterProfile.load(from: defaults)
        super.init()
    }

    func reconnectOnLaunch() {
        guard profile != nil, central == nil else { return }
        startBluetooth()
    }

    func connect() {
        guard profile != nil, !isSettingUp, phase != .ready, !phase.isConnecting else { return }
        startBluetooth()
    }

    func beginSetup() {
        guard transfer == nil else { return }
        isSettingUp = true
        scanForSetup()
    }

    func scanForSetup() {
        guard isSettingUp else { return }
        disconnect()
        setupPrinter = nil
        nearbyPrinters = []
        nearbyPeripherals = [:]
        setupMessage = nil
        startBluetooth()
    }

    func inspect(_ printer: NearbyPrinter) {
        guard isSettingUp, setupPrinter == nil, let peripheral = nearbyPeripherals[printer.id] else { return }
        setupPrinter = printer
        setupMessage = nil
        beginConnection(peripheral)
    }

    func saveSetup(endpoint selection: PrinterEndpoint, language: PrinterLanguage, resolution: PrinterResolution) -> Bool {
        guard isSettingUp, phase == .setupReady, let setupPrinter, target?.state == .connected,
              let characteristic = writableCharacteristics[selection] else { return false }
        let configuration = PrinterProfile(
            identifier: setupPrinter.id, name: setupPrinter.name, endpoint: selection,
            language: language, resolution: resolution
        )
        do {
            try configuration.save(to: defaults)
        } catch {
            setupMessage = "The printer settings could not be saved."
            return false
        }
        endpoint = characteristic
        profile = configuration
        resetSetup()
        printMessage = nil
        phase = .ready
        return true
    }

    func cancelSetup() {
        guard isSettingUp else { return }
        disconnect()
        resetSetup()
        phase = .idle
        if profile != nil { startBluetooth() }
    }

    private func resetSetup() {
        isSettingUp = false
        setupPrinter = nil
        nearbyPrinters = []
        nearbyPeripherals = [:]
        endpoints = []
        writableCharacteristics = [:]
        setupMessage = nil
    }

    private func startBluetooth() {
        if let central {
            centralManagerDidUpdateState(central)
        } else {
            phase = .starting
            central = CBCentralManager(delegate: self, queue: .main, options: [
                CBCentralManagerOptionShowPowerAlertKey: false
            ])
        }
    }

    func printLabel(_ label: LabelRaster) {
        guard phase == .ready, transfer == nil, let profile, let target, let endpoint,
              label.resolution == profile.resolution else { return }
        let writeType: CBCharacteristicWriteType = endpoint.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        // Match the vendor BLE SDK's 100-byte writes and pacing.
        let chunkSize = min(target.maximumWriteValueLength(for: writeType), 100)
        guard chunkSize > 0 else {
            finishPrint(error: "The printer could not accept a Bluetooth write.")
            return
        }
        do {
            let job = try label.printJob(for: profile)
            transfer = Transfer(job: job, writeType: writeType, chunkSize: chunkSize)
        } catch {
            finishPrint(error: error.localizedDescription)
            return
        }
        printMessage = nil
        printFailed = false
        progress = 0
        sendNextChunk()
    }

    private func sendNextChunk() {
        guard let target, let endpoint, var transfer else { return }
        guard transfer.offset < transfer.job.count else {
            finishPrint()
            return
        }

        armPrintTimeout()
        if transfer.writeType == .withoutResponse && !target.canSendWriteWithoutResponse {
            transfer.waitingForCapacity = true
            self.transfer = transfer
            return
        }
        transfer.waitingForCapacity = false
        let end = min(transfer.offset + transfer.chunkSize, transfer.job.count)
        let chunk = transfer.job.subdata(in: transfer.offset..<end)
        transfer.offset = end
        self.transfer = transfer
        target.writeValue(chunk, for: endpoint, type: transfer.writeType)

        if transfer.writeType == .withoutResponse {
            progress = Double(end) / Double(transfer.job.count)
            paceNextChunk(token: transfer.token)
        }
    }

    private func paceNextChunk(token: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            guard let self, self.transfer?.token == token else { return }
            self.sendNextChunk()
        }
    }

    private func armPrintTimeout() {
        printTimeout?.cancel()
        guard let token = transfer?.token else { return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.transfer?.token == token else { return }
            self.finishPrint(error: "Bluetooth stopped responding. Check the printer before sending the label again.")
            self.retryAfterDisconnect()
        }
        printTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func finishPrint(error: String? = nil) {
        printTimeout?.cancel()
        printTimeout = nil
        transfer = nil
        progress = nil
        printFailed = error != nil
        printMessage = error ?? "Bluetooth transfer finished. Check the printer for output."
    }

    private func startSearch(preferSavedPeripheral: Bool) {
        guard let central, central.state == .poweredOn else { return }
        schedule?.cancel()
        guard target == nil else { return }

        if !isSettingUp, profile == nil { return }
        if !isSettingUp, preferSavedPeripheral, let profile,
           let known = central.retrievePeripherals(withIdentifiers: [profile.identifier]).first {
            beginConnection(known)
            return
        }
        phase = .searching
        // Some printers omit their write service from their advertisement.
        central.scanForPeripherals(withServices: nil, options: nil)
        later(seconds: 12) { printer in
            guard printer.phase == .searching else { return }
            printer.central?.stopScan()
            if printer.isSettingUp {
                printer.phase = .choosing
            } else {
                printer.markOfflineAndRetry()
            }
        }
    }

    private func beginConnection(_ peripheral: CBPeripheral) {
        guard let central else { return }
        central.stopScan()
        target = peripheral
        endpoint = nil
        phase = .connecting
        peripheral.delegate = self
        if peripheral.state == .connected {
            discoverPrinterService(peripheral)
        } else {
            central.connect(peripheral, options: nil)
            later(seconds: 10) { printer in
                guard printer.phase == .connecting else { return }
                printer.retryAfterDisconnect()
            }
        }
    }

    private func discoverPrinterService(_ peripheral: CBPeripheral) {
        phase = .discovering
        let service = isSettingUp ? nil : profile.map { CBUUID(string: $0.endpoint.service) }
        peripheral.discoverServices(service.map { [$0] })
        later(seconds: 8) { printer in
            guard printer.phase == .discovering else { return }
            printer.retryAfterDisconnect()
        }
    }

    private func disconnect() {
        schedule?.cancel()
        central?.stopScan()
        if let target, target.state != .disconnected {
            central?.cancelPeripheralConnection(target)
        }
        target = nil
        endpoint = nil
        pendingServices = []
        writableCharacteristics = [:]
        endpoints = []
    }

    private func retryAfterDisconnect() {
        disconnect()
        if isSettingUp {
            setupPrinter = nil
            setupMessage = "Could not inspect this device. Select it again or rescan."
            phase = .choosing
            return
        }
        markOfflineAndRetry()
    }

    private func markOfflineAndRetry() {
        phase = .offline
        // Reconnect the printer, but never resend a job after an interrupted transfer.
        if profile != nil {
            later(seconds: 5) { printer in
                guard printer.phase == .offline else { return }
                printer.startSearch(preferSavedPeripheral: false)
            }
        }
    }

    private func later(seconds: Double, _ action: @escaping (PrinterConnection) -> Void) {
        schedule?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            action(self)
        }
        schedule = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

extension PrinterConnection: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startSearch(preferSavedPeripheral: true)
            return
        case .poweredOff:
            phase = .bluetoothOff
        case .unauthorized, .unsupported:
            phase = .denied
        case .unknown, .resetting:
            phase = .starting
        @unknown default:
            phase = .denied
        }
        if transfer != nil { finishPrint(error: "Bluetooth became unavailable while sending the label.") }
        disconnect()
        if isSettingUp {
            setupPrinter = nil
            nearbyPrinters = []
            nearbyPeripherals = [:]
            setupMessage = nil
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        guard phase == .searching else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if isSettingUp {
            guard nearbyPeripherals[peripheral.identifier] == nil else { return }
            let device = NearbyPrinter(
                id: peripheral.identifier,
                name: advertisedName ?? peripheral.name ?? "Unnamed device"
            )
            nearbyPeripherals[device.id] = peripheral
            nearbyPrinters.append(device)
        } else if peripheral.identifier == profile?.identifier {
            beginConnection(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === target, phase == .connecting, peripheral.state == .connected else { return }
        discoverPrinterService(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === target, phase == .connecting, peripheral.state == .disconnected else { return }
        retryAfterDisconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === target, peripheral.state == .disconnected else { return }
        if transfer != nil { finishPrint(error: "Printer disconnected. Check the label before printing again.") }
        retryAfterDisconnect()
    }
}

extension PrinterConnection: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === target else { return }
        let invalidated = invalidatedServices.contains { $0.uuid.uuidString == profile?.endpoint.service }
        guard isSettingUp || invalidated else { return }
        if transfer != nil {
            finishPrint(error: "The printer’s Bluetooth services changed during transfer. Check the label before printing again.")
        }
        retryAfterDisconnect()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === target, phase == .discovering else { return }
        guard error == nil else {
            retryAfterDisconnect()
            return
        }
        let services = peripheral.services ?? []
        if isSettingUp {
            guard !services.isEmpty else {
                rejectEndpoint()
                return
            }
            pendingServices = Set(services.map(\.uuid))
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
            return
        }
        guard let profile,
              let service = services.first(where: { $0.uuid == CBUUID(string: profile.endpoint.service) })
        else {
            rejectEndpoint()
            return
        }
        peripheral.discoverCharacteristics([CBUUID(string: profile.endpoint.characteristic)], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === target, phase == .discovering else { return }
        let writable: CBCharacteristicProperties = [.write, .writeWithoutResponse]
        let characteristics = (service.characteristics ?? []).filter {
            !$0.properties.intersection(writable).isEmpty
        }
        if isSettingUp {
            guard pendingServices.remove(service.uuid) != nil else { return }
            if error == nil {
                for characteristic in characteristics {
                    writableCharacteristics[PrinterEndpoint(
                        service: service.uuid.uuidString, characteristic: characteristic.uuid.uuidString
                    )] = characteristic
                }
            }
            guard pendingServices.isEmpty else { return }
            guard !writableCharacteristics.isEmpty else {
                rejectEndpoint()
                return
            }
            schedule?.cancel()
            endpoints = writableCharacteristics.keys.sorted {
                ($0.service, $0.characteristic) < ($1.service, $1.characteristic)
            }
            phase = .setupReady
            return
        }

        guard let profile, service.uuid == CBUUID(string: profile.endpoint.service) else { return }
        guard error == nil else {
            retryAfterDisconnect()
            return
        }
        guard let characteristic = characteristics.first(where: {
            $0.uuid == CBUUID(string: profile.endpoint.characteristic)
        }) else {
            rejectEndpoint()
            return
        }
        schedule?.cancel()
        endpoint = characteristic
        phase = .ready
    }

    private func rejectEndpoint() {
        disconnect()
        if isSettingUp {
            setupPrinter = nil
            setupMessage = "This device did not expose a writable Bluetooth endpoint."
            phase = .choosing
        } else {
            phase = .incompatible
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === target, characteristic === endpoint, let transfer,
              transfer.writeType == .withResponse else { return }
        guard error == nil else {
            finishPrint(error: "The printer rejected part of the label. Check the printer before trying again.")
            retryAfterDisconnect()
            return
        }
        progress = Double(transfer.offset) / Double(transfer.job.count)
        paceNextChunk(token: transfer.token)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === target, transfer?.waitingForCapacity == true else { return }
        sendNextChunk()
    }
}
