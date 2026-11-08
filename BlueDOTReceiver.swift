import Cocoa
import CoreBluetooth
import Foundation

private let targetDeviceUUID = UUID(uuidString: "0B843D4E-A492-D46A-F05B-003EBA2B18DE")!
private let tempCharacteristicUUID = CBUUID(string: "783F2991-23E0-4BDC-AC16-78601BD84B39")
private let preferredLocalName = "BlueDOT"

private struct IngestConfig: Codable {
    var ingestURL: String
    var token: String
}

private struct IngestPayload: Codable {
    var temperatureF: Double
    var unit: String
    var raw: Int32
    var updatedAt: String
    var connection: String
    var deviceName: String?
    var deviceUUID: String?
}

private enum ConfigLoader {
    static func load() -> IngestConfig? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/bluedot-receiver/config.json")
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(IngestConfig.self, from: data),
              !cfg.ingestURL.isEmpty, !cfg.token.isEmpty
        else { return nil }
        return cfg
    }
}

private final class Broadcaster {
    private let session = URLSession(configuration: .default)
    private var lastPost: Date?
    private let minInterval: TimeInterval = 2.0

    func post(connection: String, temperatureF: Double?, raw: Int32?, deviceName: String?, deviceUUID: String?) {
        guard let cfg = ConfigLoader.load(),
              let endpoint = URL(string: cfg.ingestURL)
        else { return }

        if let temperatureF {
            let now = Date()
            if let lastPost, now.timeIntervalSince(lastPost) < minInterval { return }
            lastPost = now
            send(cfg: cfg, endpoint: endpoint, payload: IngestPayload(
                temperatureF: temperatureF,
                unit: "F",
                raw: raw ?? 0,
                updatedAt: iso8601(now),
                connection: connection,
                deviceName: deviceName,
                deviceUUID: deviceUUID
            ))
        } else {
            send(cfg: cfg, endpoint: endpoint, payload: IngestPayload(
                temperatureF: -1,
                unit: "F",
                raw: 0,
                updatedAt: iso8601(Date()),
                connection: connection,
                deviceName: deviceName,
                deviceUUID: deviceUUID
            ))
        }
    }

    private func send(cfg: IngestConfig, endpoint: URL, payload: IngestPayload) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(payload)
        session.dataTask(with: req) { _, response, error in
            if let error {
                fputs("Ingest error: \(error.localizedDescription)\n", stderr)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                fputs("Ingest HTTP \(http.statusCode)\n", stderr)
            }
        }.resume()
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

private func parseTemperatureF(from data: Data) -> (fahrenheit: Double, raw: Int32)? {
    let bytes = [UInt8](data)
    guard bytes.count >= 5 else { return nil }
    let raw =
        Int32(bytes[1]) |
        (Int32(bytes[2]) << 8) |
        (Int32(bytes[3]) << 16) |
        (Int32(bytes[4]) << 24)
    // Same as artisan-websocket-bluedot: integer is °F, not tenths.
    return (Double(raw), raw)
}

private func formatStatus(temperature: Double?, raw: Int32?, connection: String, detail: String, ingestOK: Bool) -> String {
    var lines: [String] = []
    lines.append(connection == "connected" ? "Connected to BlueDOT" : "Status: \(connection)")
    if let temperature {
        lines.append(String(format: "Temperature: %.1f °F", temperature))
    } else {
        lines.append("Temperature: —")
    }
    if let raw {
        lines.append("Raw: \(raw)")
    }
    lines.append(detail)
    if ingestOK {
        lines.append("Public feed: configured")
    } else {
        lines.append("Public feed: add ~/.config/bluedot-receiver/config.json")
    }
    return lines.joined(separator: "\n")
}

final class Receiver: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    var manager: CBCentralManager!
    var window: NSWindow!
    var label: NSTextField!

    private var peripheral: CBPeripheral?
    private var tempCharacteristic: CBCharacteristic?
    private var lastTemperature: Double?
    private var lastRaw: Int32?
    private var connectionState = "connecting"
    private var detailLine = "Starting…"
    private let broadcaster = Broadcaster()
    private var reconnectWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BlueDOT Receiver"
        label = NSTextField(wrappingLabelWithString: "Requesting Bluetooth access…")
        label.frame = NSRect(x: 24, y: 24, width: 512, height: 180)
        window.contentView?.addSubview(label)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func refreshLabel() {
        let ingestOK = ConfigLoader.load() != nil
        label.stringValue = formatStatus(
            temperature: lastTemperature,
            raw: lastRaw,
            connection: connectionState,
            detail: detailLine,
            ingestOK: ingestOK
        )
    }

    private func scheduleReconnect(after: TimeInterval = 3.0) {
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.beginConnectionAttempt()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }

    private func beginConnectionAttempt() {
        guard manager.state == .poweredOn else { return }
        connectionState = "connecting"
        detailLine = "Connecting…"
        refreshLabel()

        let known = manager.retrievePeripherals(withIdentifiers: [targetDeviceUUID])
        if let p = known.first {
            peripheral = p
            p.delegate = self
            manager.stopScan()
            manager.connect(p, options: nil)
            return
        }

        detailLine = "Scanning for BlueDOT…"
        refreshLabel()
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            detailLine = "Bluetooth ready."
            beginConnectionAttempt()
        case .unauthorized:
            connectionState = "unauthorized"
            detailLine = "Enable Bluetooth for BlueDOT Receiver in System Settings."
        case .poweredOff:
            connectionState = "bluetooth_off"
            detailLine = "Turn on Bluetooth."
            broadcaster.post(connection: connectionState, temperatureF: nil, raw: nil, deviceName: nil, deviceUUID: nil)
        default:
            connectionState = "unavailable"
            detailLine = "Bluetooth state: \(central.state.rawValue)"
        }
        refreshLabel()
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let matches = p.identifier == targetDeviceUUID
            || name == preferredLocalName
            || name.lowercased().contains("bluedot")
        guard matches else { return }

        central.stopScan()
        peripheral = p
        p.delegate = self
        detailLine = "Found \(name.isEmpty ? p.identifier.uuidString : name)"
        refreshLabel()
        central.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        connectionState = "connected"
        detailLine = "Discovering services…"
        refreshLabel()
        broadcaster.post(
            connection: "connected",
            temperatureF: nil,
            raw: nil,
            deviceName: p.name,
            deviceUUID: p.identifier.uuidString
        )
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connectionState = "disconnected"
        detailLine = error?.localizedDescription ?? "Connection failed"
        peripheral = nil
        tempCharacteristic = nil
        refreshLabel()
        broadcaster.post(connection: "disconnected", temperatureF: nil, raw: nil, deviceName: p.name, deviceUUID: p.identifier.uuidString)
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connectionState = "disconnected"
        detailLine = error?.localizedDescription ?? "Disconnected — reconnecting…"
        peripheral = nil
        tempCharacteristic = nil
        refreshLabel()
        broadcaster.post(connection: "disconnected", temperatureF: nil, raw: nil, deviceName: p.name, deviceUUID: p.identifier.uuidString)
        scheduleReconnect()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            detailLine = error.localizedDescription
            refreshLabel()
            manager.cancelPeripheralConnection(peripheral)
            return
        }
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics([tempCharacteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            detailLine = error.localizedDescription
            refreshLabel()
            return
        }
        guard let chars = service.characteristics,
              let temp = chars.first(where: { $0.uuid == tempCharacteristicUUID })
        else { return }

        tempCharacteristic = temp
        detailLine = "Subscribed to temperature"
        refreshLabel()
        peripheral.setNotifyValue(true, for: temp)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            detailLine = error.localizedDescription
            refreshLabel()
            return
        }
        guard characteristic.uuid == tempCharacteristicUUID,
              let data = characteristic.value,
              let parsed = parseTemperatureF(from: data)
        else { return }

        lastTemperature = parsed.fahrenheit
        lastRaw = parsed.raw
        detailLine = "Last update: \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))"
        refreshLabel()
        broadcaster.post(
            connection: "connected",
            temperatureF: parsed.fahrenheit,
            raw: parsed.raw,
            deviceName: peripheral.name,
            deviceUUID: peripheral.identifier.uuidString
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            detailLine = "Notify error: \(error.localizedDescription)"
            refreshLabel()
        }
    }
}

let app = NSApplication.shared
let receiver = Receiver()
app.delegate = receiver
app.setActivationPolicy(.regular)
app.run()
