import Foundation
import CoreBluetooth

// MARK: - Profile IDs

enum ThermometerProfileID: String, CaseIterable, Codable, Identifiable {
    case thermoworksBluedot = "thermoworks-bluedot"
    case meater = "meater"
    case thermapenBlue = "thermapen-blue"
    case inkbirdIBBQ = "inkbird-ibbq"
    case autoDetect = "auto-detect"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thermoworksBluedot: "ThermoWorks BlueDOT"
        case .meater: "MEATER"
        case .thermapenBlue: "Thermapen Blue"
        case .inkbirdIBBQ: "Inkbird iBBQ"
        case .autoDetect: "Auto-detect"
        }
    }

    var pairingHint: String {
        switch self {
        case .thermoworksBluedot: "Wake the BlueDOT; we use its BLE temperature stream."
        case .meater: "Insert MEATER into the charger briefly, then place probe nearby."
        case .thermapenBlue: "Open the probe, connect in range, press Transfer to send a reading."
        case .inkbirdIBBQ: "Power on the iBBQ / Inkbird grill unit with probes plugged in."
        case .autoDetect: "We’ll connect and infer the temperature format from GATT data."
        }
    }
}

struct TemperatureDecodeResult: Equatable {
    var fahrenheit: Double
    var raw: Int32
    var detail: String?
}

struct HeuristicDecodeCandidate: Equatable {
    var fahrenheit: Double
    var confidence: Double
    var method: String
}

// MARK: - Well-known UUIDs

enum GATTUUID {
    static let healthThermometerService = CBUUID(string: "1809")
    static let temperatureMeasurement = CBUUID(string: "2A1C")
    static let temperatureCelsius = CBUUID(string: "2A6E")
    static let temperatureFahrenheit = CBUUID(string: "2A1F")
    static let environmentalSensing = CBUUID(string: "181A")

    static let bluedotTemp = CBUUID(string: "783F2991-23E0-4BDC-AC16-78601BD84B39")
    static let meaterService = CBUUID(string: "A75CC7FC-C956-488F-AC2A-2DBC08B63A04")
    static let meaterTemp = CBUUID(string: "7EDDA774-045E-4BBF-909B-45D1991A2876")
    static let inkbirdService = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    static let inkbirdRealtime = CBUUID(string: "0000FFF4-0000-1000-8000-00805F9B34FB")
    static let inkbirdSettings = CBUUID(string: "0000FFF5-0000-1000-8000-00805F9B34FB")
}

// MARK: - Discovery

struct ThermometerProfile: Equatable {
    let id: ThermometerProfileID
    let namePatterns: [String]
    let advertisedServiceUUIDs: [CBUUID]

    func matches(peripheralName: String, advertisementServiceUUIDs: [CBUUID]) -> Bool {
        let lower = peripheralName.lowercased()
        let nameHit = namePatterns.contains { pattern in
            lower.contains(pattern.lowercased())
        }
        if !nameHit, advertisedServiceUUIDs.isEmpty { return false }
        if !nameHit { return false }
        if advertisedServiceUUIDs.isEmpty { return true }
        return advertisedServiceUUIDs.contains { adv in
            self.advertisedServiceUUIDs.contains { $0.uuidString == adv.uuidString }
        } || advertisedServiceUUIDs.isEmpty
    }
}

enum ThermometerProfileRegistry {
    static let catalog: [ThermometerProfile] = [
        ThermometerProfile(
            id: .thermoworksBluedot,
            namePatterns: ["bluedot"],
            advertisedServiceUUIDs: []
        ),
        ThermometerProfile(
            id: .meater,
            namePatterns: ["meater"],
            advertisedServiceUUIDs: [GATTUUID.meaterService]
        ),
        ThermometerProfile(
            id: .thermapenBlue,
            namePatterns: ["thermapen", "thermapen one", "thermapenone"],
            advertisedServiceUUIDs: []
        ),
        ThermometerProfile(
            id: .inkbirdIBBQ,
            namePatterns: ["ibbq", "xbbq", "inkbird", "ibt-", "idt-"],
            advertisedServiceUUIDs: [GATTUUID.inkbirdService, CBUUID(string: "FFF0")]
        ),
    ]

    static func profile(for id: String) -> ThermometerProfileID {
        ThermometerProfileID(rawValue: id) ?? .autoDetect
    }

    static func inferProfile(
        peripheralName: String,
        advertisementServiceUUIDs: [CBUUID],
        preferred: ThermometerProfileID?
    ) -> ThermometerProfileID {
        if let preferred, preferred != .autoDetect { return preferred }
        for p in catalog {
            if p.matches(peripheralName: peripheralName, advertisementServiceUUIDs: advertisementServiceUUIDs) {
                return p.id
            }
        }
        return .autoDetect
    }
}

// MARK: - Decoders

enum TemperatureDecoders {
    private static let foodMinF = -40.0
    private static let foodMaxF = 572.0

    static func plausible(_ f: Double) -> Bool {
        f.isFinite && f >= foodMinF && f <= foodMaxF
    }

    static func celsiusToF(_ c: Double) -> Double { c * 9 / 5 + 32 }

    static func decode(profileId: ThermometerProfileID, characteristic: CBUUID, data: Data) -> TemperatureDecodeResult? {
        switch profileId {
        case .thermoworksBluedot:
            return decodeBlueDOT(data)
        case .meater:
            if characteristic == GATTUUID.meaterTemp || data.count >= 6 {
                return decodeMEATER(data)
            }
            return nil
        case .inkbirdIBBQ:
            if characteristic == GATTUUID.inkbirdRealtime || data.count >= 2 {
                return decodeInkbirdRealtime(data, channel: 0)
            }
            return nil
        case .thermapenBlue:
            if let r = decodeBlueDOT(data) { return r }
            if characteristic == GATTUUID.temperatureMeasurement {
                return decodeHealthThermometerMeasurement(data)
            }
            if characteristic == GATTUUID.temperatureCelsius {
                return decodeSInt16Scaled(data, divisor: 100, unitIsCelsius: true, method: "GATT 0x2A6E")
            }
            return nil
        case .autoDetect:
            return nil
        }
    }

    static func decodeBlueDOT(_ data: Data) -> TemperatureDecodeResult? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { return nil }
        let raw =
            Int32(bytes[1]) |
            (Int32(bytes[2]) << 8) |
            (Int32(bytes[3]) << 16) |
            (Int32(bytes[4]) << 24)
        let f = Double(raw)
        guard plausible(f) else { return nil }
        return TemperatureDecodeResult(fahrenheit: f, raw: raw, detail: "BlueDOT / ETI int32 °F")
    }

    static func decodeMEATER(_ data: Data) -> TemperatureDecodeResult? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        let tip = Int16(bytes[0]) | (Int16(bytes[1]) << 8)
        let tipC = (Double(tip) + 8) / 16.0
        let f = celsiusToF(tipC)
        guard plausible(f) else { return nil }
        return TemperatureDecodeResult(fahrenheit: f, raw: Int32(tip), detail: "MEATER tip")
    }

    static func decodeInkbirdRealtime(_ data: Data, channel: Int) -> TemperatureDecodeResult? {
        let offset = channel * 2
        guard data.count >= offset + 2 else { return nil }
        let bytes = [UInt8](data)
        let raw = Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
        if raw == 0x7FFE { return nil }
        let c = Double(raw) / 10.0
        let f = celsiusToF(c)
        guard plausible(f) else { return nil }
        return TemperatureDecodeResult(fahrenheit: f, raw: Int32(raw), detail: "Inkbird probe \(channel + 1)")
    }

    static func decodeHealthThermometerMeasurement(_ data: Data) -> TemperatureDecodeResult? {
        guard data.count >= 5 else { return nil }
        let flags = data[data.startIndex]
        let tempBytes = data.subdata(in: data.index(data.startIndex, offsetBy: 1)..<data.index(data.startIndex, offsetBy: 5))
        var value: Float = 0
        _ = withUnsafeMutableBytes(of: &value) { tempBytes.copyBytes(to: $0) }
        var f = Double(value)
        if (flags & 0x01) == 0 { f = celsiusToF(f) }
        guard plausible(f) else { return nil }
        return TemperatureDecodeResult(fahrenheit: f, raw: Int32(value.bitPattern), detail: "BLE Health Thermometer")
    }

    static func decodeSInt16Scaled(_ data: Data, divisor: Double, unitIsCelsius: Bool, method: String) -> TemperatureDecodeResult? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        let raw = Int16(bitPattern: UInt16(bytes[0]) | (UInt16(bytes[1]) << 8))
        var v = Double(raw) / divisor
        if unitIsCelsius { v = celsiusToF(v) }
        guard plausible(v) else { return nil }
        return TemperatureDecodeResult(fahrenheit: v, raw: Int32(raw), detail: method)
    }

    /// Try many shapes; return ranked candidates for unknown devices.
    static func heuristicCandidates(data: Data) -> [HeuristicDecodeCandidate] {
        var out: [HeuristicDecodeCandidate] = []
        func add(_ f: Double, _ conf: Double, _ method: String) {
            guard plausible(f) else { return }
            out.append(HeuristicDecodeCandidate(fahrenheit: f, confidence: conf, method: method))
        }

        if let r = decodeBlueDOT(data) { add(r.fahrenheit, 0.92, r.detail ?? "bluedot") }
        if let r = decodeMEATER(data) { add(r.fahrenheit, 0.9, r.detail ?? "meater") }
        if let r = decodeHealthThermometerMeasurement(data) { add(r.fahrenheit, 0.88, r.detail ?? "2A1C") }
        if let r = decodeSInt16Scaled(data, divisor: 100, unitIsCelsius: true, method: "sint16 /100 °C") {
            add(r.fahrenheit, 0.75, r.detail ?? "")
        }
        if let r = decodeSInt16Scaled(data, divisor: 10, unitIsCelsius: true, method: "sint16 /10 °C") {
            add(r.fahrenheit, 0.72, r.detail ?? "")
        }
        if let r = decodeSInt16Scaled(data, divisor: 1, unitIsCelsius: false, method: "sint16 whole °F") {
            add(r.fahrenheit, 0.65, r.detail ?? "")
        }
        if data.count >= 4 {
            let bytes = [UInt8](data)
            let u32 = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            add(Double(u32) / 10.0, 0.55, "uint32 /10")
            var f: Float = 0
            let sub = data.prefix(4)
            _ = withUnsafeMutableBytes(of: &f) { sub.copyBytes(to: $0) }
            add(Double(f), 0.5, "float32")
            add(celsiusToF(Double(f)), 0.48, "float32 as °C")
        }
        if data.count >= 2, let r = decodeInkbirdRealtime(data, channel: 0) {
            add(r.fahrenheit, 0.7, r.detail ?? "inkbird ch1")
        }

        return out.sorted { $0.confidence > $1.confidence }
    }

    static func bestHeuristic(data: Data, minimumConfidence: Double = 0.55) -> TemperatureDecodeResult? {
        guard let top = heuristicCandidates(data: data).first, top.confidence >= minimumConfidence else { return nil }
        return TemperatureDecodeResult(
            fahrenheit: top.fahrenheit,
            raw: Int32(top.fahrenheit.rounded()),
            detail: "Auto: \(top.method)"
        )
    }
}

// MARK: - GATT setup

enum ThermometerGATTPlanner {
    struct Plan {
        var notifyUUIDs: [CBUUID]
        var readUUIDs: [CBUUID]
        var writeCommands: [(uuid: CBUUID, payload: Data)]
    }

    static func plan(for profileId: ThermometerProfileID) -> Plan {
        switch profileId {
        case .thermoworksBluedot:
            return Plan(notifyUUIDs: [GATTUUID.bluedotTemp], readUUIDs: [], writeCommands: [])
        case .meater:
            return Plan(notifyUUIDs: [GATTUUID.meaterTemp], readUUIDs: [GATTUUID.meaterTemp], writeCommands: [])
        case .thermapenBlue:
            return Plan(
                notifyUUIDs: [GATTUUID.bluedotTemp, GATTUUID.temperatureMeasurement, GATTUUID.temperatureCelsius, GATTUUID.temperatureFahrenheit],
                readUUIDs: [GATTUUID.temperatureCelsius, GATTUUID.temperatureFahrenheit],
                writeCommands: []
            )
        case .inkbirdIBBQ:
            return Plan(
                notifyUUIDs: [GATTUUID.inkbirdRealtime],
                readUUIDs: [],
                writeCommands: [(GATTUUID.inkbirdSettings, Data([0x0B, 0x01, 0x00, 0x00, 0x00, 0x00]))]
            )
        case .autoDetect:
            return Plan(
                notifyUUIDs: [GATTUUID.temperatureMeasurement, GATTUUID.temperatureCelsius, GATTUUID.temperatureFahrenheit, GATTUUID.bluedotTemp],
                readUUIDs: [GATTUUID.temperatureCelsius, GATTUUID.temperatureFahrenheit],
                writeCommands: []
            )
        }
    }

    static func interestingCharacteristicUUIDs(for profileId: ThermometerProfileID) -> [CBUUID] {
        let plan = plan(for: profileId)
        return Array(Set(plan.notifyUUIDs + plan.readUUIDs + plan.writeCommands.map(\.uuid)))
    }

    /// For auto-detect, subscribe to every characteristic that supports notify/indicate.
    static func shouldSubscribeAuto(characteristic: CBCharacteristic) -> Bool {
        characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
    }
}
