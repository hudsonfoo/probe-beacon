import SwiftUI
import Charts
import CoreBluetooth
import UserNotifications
import AppKit
import AudioToolbox
import Darwin
import Security

private let defaultDeviceUUID = UUID(uuidString: "0B843D4E-A492-D46A-F05B-003EBA2B18DE")!
private let tempCharacteristicUUID = CBUUID(string: "783F2991-23E0-4BDC-AC16-78601BD84B39")
private let preferredLocalName = "BlueDOT"

// MARK: - Models & config

struct IngestConfig: Codable, Equatable {
    var ingestURL: String
    var token: String
}

struct AppPreferences: Codable, Equatable {
    /// Legacy primary probe; kept in sync with `activeProbeUUID` on save.
    var deviceUUID: String
    var savedProbeUUIDs: [String]
    var activeProbeUUID: String
    var probeNames: [String: String]
    var useCelsius: Bool
    var menuBarEnabled: Bool
    var broadcastPaused: Bool
    var alertEnabled: Bool
    var alertHighF: Double
    var alertLowF: Double
    var targetEnabled: Bool
    var targetTempF: Double
    var targetAlarmEnabled: Bool
    var ntfyEnabled: Bool
    var ntfyTopic: String
    var ntfyServer: String
    var dashboardHosting: String
    var homeIngestPort: Int
    var autoCheckUpdates: Bool

    static let defaults = AppPreferences(
        deviceUUID: "",
        savedProbeUUIDs: [],
        activeProbeUUID: "",
        probeNames: [:],
        useCelsius: false,
        menuBarEnabled: true,
        broadcastPaused: false,
        alertEnabled: false,
        alertHighF: 165,
        alertLowF: 40,
        targetEnabled: false,
        targetTempF: 203,
        targetAlarmEnabled: true,
        ntfyEnabled: false,
        ntfyTopic: "",
        ntfyServer: "https://ntfy.sh",
        dashboardHosting: DashboardHosting.cloudflare.rawValue,
        homeIngestPort: 8787,
        autoCheckUpdates: true
    )

    var resolvedActiveProbeUUID: String {
        if !activeProbeUUID.isEmpty { return activeProbeUUID }
        if !deviceUUID.isEmpty { return deviceUUID }
        return savedProbeUUIDs.first ?? ""
    }

    mutating func syncLegacyDeviceUUID() {
        activeProbeUUID = resolvedActiveProbeUUID
        deviceUUID = activeProbeUUID
        if !activeProbeUUID.isEmpty, !savedProbeUUIDs.contains(activeProbeUUID) {
            savedProbeUUIDs.append(activeProbeUUID)
        }
    }

    init(
        deviceUUID: String,
        savedProbeUUIDs: [String] = [],
        activeProbeUUID: String = "",
        probeNames: [String: String] = [:],
        useCelsius: Bool,
        menuBarEnabled: Bool,
        broadcastPaused: Bool,
        alertEnabled: Bool,
        alertHighF: Double,
        alertLowF: Double,
        targetEnabled: Bool = false,
        targetTempF: Double = 203,
        targetAlarmEnabled: Bool = true,
        ntfyEnabled: Bool = false,
        ntfyTopic: String = "",
        ntfyServer: String = "https://ntfy.sh",
        dashboardHosting: String = DashboardHosting.cloudflare.rawValue,
        homeIngestPort: Int = 8787,
        autoCheckUpdates: Bool = true
    ) {
        self.deviceUUID = deviceUUID
        self.savedProbeUUIDs = savedProbeUUIDs
        self.activeProbeUUID = activeProbeUUID.isEmpty ? deviceUUID : activeProbeUUID
        self.probeNames = probeNames
        self.useCelsius = useCelsius
        self.menuBarEnabled = menuBarEnabled
        self.broadcastPaused = broadcastPaused
        self.alertEnabled = alertEnabled
        self.alertHighF = alertHighF
        self.alertLowF = alertLowF
        self.targetEnabled = targetEnabled
        self.targetTempF = targetTempF
        self.targetAlarmEnabled = targetAlarmEnabled
        self.ntfyEnabled = ntfyEnabled
        self.ntfyTopic = ntfyTopic
        self.ntfyServer = ntfyServer
        self.dashboardHosting = dashboardHosting
        self.homeIngestPort = homeIngestPort
        self.autoCheckUpdates = autoCheckUpdates
    }

    var hosting: DashboardHosting {
        DashboardHosting(rawValue: dashboardHosting) ?? .cloudflare
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceUUID = try c.decode(String.self, forKey: .deviceUUID)
        savedProbeUUIDs = try c.decodeIfPresent([String].self, forKey: .savedProbeUUIDs) ?? []
        activeProbeUUID = try c.decodeIfPresent(String.self, forKey: .activeProbeUUID) ?? ""
        probeNames = try c.decodeIfPresent([String: String].self, forKey: .probeNames) ?? [:]
        if savedProbeUUIDs.isEmpty, !deviceUUID.isEmpty {
            savedProbeUUIDs = [deviceUUID]
        }
        if activeProbeUUID.isEmpty, !deviceUUID.isEmpty {
            activeProbeUUID = deviceUUID
        }
        if !activeProbeUUID.isEmpty {
            deviceUUID = activeProbeUUID
        }
        useCelsius = try c.decode(Bool.self, forKey: .useCelsius)
        menuBarEnabled = try c.decode(Bool.self, forKey: .menuBarEnabled)
        broadcastPaused = try c.decode(Bool.self, forKey: .broadcastPaused)
        alertEnabled = try c.decode(Bool.self, forKey: .alertEnabled)
        alertHighF = try c.decode(Double.self, forKey: .alertHighF)
        alertLowF = try c.decode(Double.self, forKey: .alertLowF)
        targetEnabled = try c.decodeIfPresent(Bool.self, forKey: .targetEnabled) ?? false
        targetTempF = try c.decodeIfPresent(Double.self, forKey: .targetTempF) ?? 203
        targetAlarmEnabled = try c.decodeIfPresent(Bool.self, forKey: .targetAlarmEnabled) ?? true
        ntfyEnabled = try c.decodeIfPresent(Bool.self, forKey: .ntfyEnabled) ?? false
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic) ?? ""
        ntfyServer = try c.decodeIfPresent(String.self, forKey: .ntfyServer) ?? "https://ntfy.sh"
        dashboardHosting = try c.decodeIfPresent(String.self, forKey: .dashboardHosting) ?? DashboardHosting.cloudflare.rawValue
        homeIngestPort = try c.decodeIfPresent(Int.self, forKey: .homeIngestPort) ?? 8787
        autoCheckUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
    }
}

private enum AppUpdateConstants {
    static let repo = "hudsonfoo/thermoworks-bluedot-manager"
    static let releasesURL = URL(string: "https://github.com/hudsonfoo/thermoworks-bluedot-manager/releases")!
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

@MainActor
final class UpdateController: ObservableObject {
    @Published var status = ""
    @Published var latestVersion: String?
    @Published var downloadURL: URL?
    @Published var isChecking = false
    @Published var isInstalling = false

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    var updateAvailable: Bool {
        guard let latestVersion else { return false }
        return Self.isVersion(latestVersion, newerThan: currentVersion)
    }

    func checkOnLaunchIfEnabled(autoCheck: Bool) {
        guard autoCheck else { return }
        Task {
            await checkForUpdates(silent: true)
            if updateAvailable, let latestVersion {
                promptToInstall(version: latestVersion)
            }
        }
    }

    func checkForUpdates(silent: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        if !silent { status = "Checking GitHub releases…" }

        guard let api = URL(string: "https://api.github.com/repos/\(AppUpdateConstants.repo)/releases/latest") else {
            status = "Invalid update URL"
            if !silent { notifyManualCheck(title: "Update check failed", message: status) }
            return
        }
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BlueDOT-Manager", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                status = "Could not reach GitHub (status \((response as? HTTPURLResponse)?.statusCode ?? 0))"
                if !silent { notifyManualCheck(title: "Update check failed", message: status) }
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            latestVersion = version
            let preferredDMG = "BlueDOT-Manager-\(version).dmg"
            let dmgAsset = release.assets.first(where: { $0.name == preferredDMG })
                ?? release.assets.first(where: { $0.name.hasPrefix("BlueDOT-Manager") && $0.name.hasSuffix(".dmg") })
                ?? release.assets.first(where: { $0.name.hasSuffix(".dmg") })
            if let dmg = dmgAsset {
                downloadURL = URL(string: dmg.browserDownloadURL)
            } else {
                downloadURL = nil
            }

            if Self.isVersion(version, newerThan: currentVersion) {
                status = "Update available: v\(version) (you have v\(currentVersion))"
                if !silent {
                    promptToInstall(version: version)
                }
            } else {
                status = "BlueDOT Manager v\(currentVersion) is up to date."
                latestVersion = nil
                downloadURL = nil
                if !silent { promptUpToDate() }
            }
        } catch {
            status = "Update check failed: \(error.localizedDescription)"
            if !silent { notifyManualCheck(title: "Update check failed", message: status) }
        }
    }

    private func promptUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "BlueDOT Manager v\(currentVersion) is the latest release on GitHub."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func notifyManualCheck(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func installUpdate() async {
        guard let downloadURL, let latestVersion else {
            status = "No update downloaded yet — check for updates first."
            return
        }
        isInstalling = true
        status = "Downloading v\(latestVersion)…"

        do {
            var request = URLRequest(url: downloadURL)
            request.setValue("BlueDOT-Manager", forHTTPHeaderField: "User-Agent")
            let (dmgData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                throw UpdateError.badHTTP((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            guard dmgData.count > 200_000 else {
                throw UpdateError.downloadTooSmall
            }

            let dmgPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("BlueDOT-Manager-\(latestVersion).dmg")
            try dmgData.write(to: dmgPath, options: .atomic)

            status = "Mounting installer…"
            let mountPoint = try mountDMG(at: dmgPath)

            guard let appBundle = try findAppBundle(in: mountPoint) else {
                try? detachDMG(at: mountPoint)
                throw UpdateError.noAppInDMG
            }

            let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BlueDOT-Manager-updates", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            let stagedApp = cacheRoot.appendingPathComponent(appBundle.lastPathComponent)
            if FileManager.default.fileExists(atPath: stagedApp.path) {
                try FileManager.default.removeItem(at: stagedApp)
            }
            status = "Preparing v\(latestVersion)…"
            try FileManager.default.copyItem(at: appBundle, to: stagedApp)
            try detachDMG(at: mountPoint)
            try? FileManager.default.removeItem(at: dmgPath)

            let destination = preferredInstallDestination(fallbackAppName: appBundle.lastPathComponent)
            status = "Quitting to install into \(destination.path)…"
            try launchPostQuitInstall(stagedApp: stagedApp, destination: destination)
            isInstalling = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NSApp.terminate(nil)
            }
        } catch {
            isInstalling = false
            status = "Install failed: \(error.localizedDescription)"
        }
    }

    private enum UpdateError: LocalizedError {
        case badHTTP(Int)
        case downloadTooSmall
        case noAppInDMG
        case postQuitScriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .badHTTP(let code): "Download failed (HTTP \(code))."
            case .downloadTooSmall: "Download did not look like a release DMG."
            case .noAppInDMG: "No .app found inside the DMG."
            case .postQuitScriptFailed(let detail): "Could not start installer: \(detail)"
            }
        }
    }

    private func preferredInstallDestination(fallbackAppName: String) -> URL {
        let running = Bundle.main.bundleURL
        if running.path.hasSuffix(".app"),
           FileManager.default.isWritableFile(atPath: running.deletingLastPathComponent().path) {
            return running
        }
        return URL(fileURLWithPath: "/Applications").appendingPathComponent(fallbackAppName)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func launchPostQuitInstall(stagedApp: URL, destination: URL) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bluedot-install-\(UUID().uuidString).sh")
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("bluedot-install-last.log")
        let pid = ProcessInfo.processInfo.processIdentifier
        let stagedPath = shellQuote(stagedApp.path)
        let destPath = shellQuote(destination.path)
        let logPath = shellQuote(logURL.path)
        let cachePath = shellQuote(stagedApp.deletingLastPathComponent().path)
        let scriptPath = shellQuote(scriptURL.path)

        let script = """
        #!/bin/bash
        set -e
        LOG=\(logPath)
        STAGED=\(stagedPath)
        DEST=\(destPath)
        echo "BlueDOT Manager update started" > "$LOG"
        echo "Waiting for pid \(pid)…" >> "$LOG"
        for _ in $(seq 1 240); do
          if ! kill -0 \(pid) 2>/dev/null; then break; fi
          sleep 0.25
        done
        install_app() {
          rm -rf "$DEST"
          /usr/bin/ditto "$STAGED" "$DEST"
        }
        if ! install_app >> "$LOG" 2>&1; then
          echo "Retrying with administrator privileges…" >> "$LOG"
          INSTALL_CMD=$(printf '/bin/rm -rf %q && /usr/bin/ditto %q %q' "$DEST" "$STAGED" "$DEST")
          /usr/bin/osascript -e "do shell script \"$INSTALL_CMD\" with administrator privileges" >> "$LOG" 2>&1
        fi
        /usr/bin/open "$DEST"
        rm -rf \(cachePath)
        rm -f \(scriptPath)
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    private func promptToInstall(version: String) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = "BlueDOT Manager v\(version) is available (you have v\(currentVersion)). The app will download, quit, replace itself, and reopen."
        alert.addButton(withTitle: "Download & Install")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release notes")
        let result = alert.runModal()
        if result == .alertFirstButtonReturn {
            Task { await installUpdate() }
        } else if result == .alertThirdButtonReturn {
            NSWorkspace.shared.open(AppUpdateConstants.releasesURL)
        }
    }

    private func mountDMG(at url: URL) throws -> URL {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", url.path, "-nobrowse", "-quiet", "-plist"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw NSError(domain: "Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "hdiutil attach failed"]) }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { throw NSError(domain: "Update", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not parse mount info"]) }

        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                return URL(fileURLWithPath: mountPoint)
            }
        }
        throw NSError(domain: "Update", code: 3, userInfo: [NSLocalizedDescriptionKey: "No mount point"])
    }

    private func detachDMG(at mountPoint: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", mountPoint.path, "-quiet"]
        try proc.run()
        proc.waitUntilExit()
    }

    private func findAppBundle(in mountRoot: URL) throws -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let items = try FileManager.default.contentsOfDirectory(at: mountRoot, includingPropertiesForKeys: keys)
        if let direct = items.first(where: { $0.pathExtension == "app" }) { return direct }
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard isDir, item.lastPathComponent != "Applications" else { continue }
            let inner = try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
            if let nested = inner.first(where: { $0.pathExtension == "app" }) { return nested }
        }
        return nil
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }
}

enum DashboardHosting: String, Codable, CaseIterable, Identifiable {
    case cloudflare
    case homeNetwork
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cloudflare: "Cloudflare (HTTPS, recommended)"
        case .homeNetwork: "Home network (public IP + port forward)"
        }
    }
}

// MARK: - Local ingest (home hosting)

private final class LocalIngestServer {
    private var process: Process?
    private(set) var isRunning = false

    func bundledServerDirectory() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("ingest-server", isDirectory: true)
    }

    func nodeExecutable() -> String? {
        let paths = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        for p in paths where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    func start(port: Int, token: String) -> String? {
        stop()
        guard let dir = bundledServerDirectory(),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("server.js").path)
        else { return "ingest-server not found in app bundle (reinstall from release DMG)" }
        guard let node = nodeExecutable() else { return "Install Node.js (brew install node) for home hosting" }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: node)
        proc.arguments = ["server.js"]
        proc.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PORT"] = "\(port)"
        env["INGEST_TOKEN"] = token
        proc.environment = env
        do {
            try proc.run()
            process = proc
            isRunning = true
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }
}

private enum NetworkEndpoints {
    static func fetchPublicIPv4(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://api.ipify.org") else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let ip = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { completion(ip) }
        }.resume()
    }

    static func localIPv4() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)
            if !ip.hasPrefix("127.") { addr = ip; break }
        }
        return addr
    }
}

// MARK: - Notifications & alarm audio

private let targetAlarmCategoryId = "BLUEDOT_TARGET_ALARM"

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    weak var store: BluetoothStore?

    func registerCategories() {
        let dismiss = UNNotificationAction(identifier: "DISMISS_ALARM", title: "Dismiss", options: [.destructive])
        let category = UNNotificationCategory(
            identifier: targetAlarmCategoryId,
            actions: [dismiss],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == "bluedot.target" else { return }
        if response.actionIdentifier == "DISMISS_ALARM"
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run {
                store?.dismissTargetAlarm()
            }
        }
    }
}

private final class AlarmSoundPlayer {
    static let shared = AlarmSoundPlayer()
    private var pulseTimer: Timer?
    private var activeSound: NSSound?

    func startRepeating() {
        stop()
        playPulse()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { [weak self] _ in
            self?.playPulse()
        }
    }

    func stop() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        activeSound?.stop()
        activeSound = nil
    }

    private func playPulse() {
        guard pulseTimer != nil else { return }
        AudioServicesPlayAlertSound(SystemSoundID(1005))
        activeSound?.stop()
        if let sound = NSSound(named: "Ping") {
            activeSound = sound
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

private enum RemotePush {
    static func send(prefs: AppPreferences, title: String, body: String) {
        guard prefs.ntfyEnabled else { return }
        let topic = prefs.ntfyTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return }
        var base = prefs.ntfyServer.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "https://ntfy.sh" }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(topic)") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue("urgent", forHTTPHeaderField: "Priority")
        req.setValue("thermometer", forHTTPHeaderField: "Tags")
        req.httpBody = body.data(using: .utf8)
        URLSession.shared.dataTask(with: req).resume()
    }
}

enum TargetProjection: Equatable {
    case disabled
    case noReading
    case atTarget
    case insufficientData
    case flat
    case wrongDirection(heating: Bool, targetAbove: Bool)
    case enRoute(eta: TimeInterval, rateFPerMinute: Double, heating: Bool)

    var headline: String {
        switch self {
        case .disabled:
            return "Set a target to estimate arrival time"
        case .noReading:
            return "Waiting for temperature…"
        case .atTarget:
            return "At target"
        case .insufficientData:
            return "Need more readings"
        case .flat:
            return "Trend too flat to estimate"
        case .wrongDirection(_, let above):
            if above { return "Cooling — target is above" }
            return "Heating — target is below"
        case .enRoute(let eta, let rate, let heating):
            let dir = heating ? "Heating" : "Cooling"
            return "\(dir) · \(formatRate(rate)) · \(formatETA(eta))"
        }
    }

    var detail: String? {
        switch self {
        case .wrongDirection(let heating, let above):
            let trend = heating ? "warming" : "cooling"
            let need = above ? "rise" : "fall"
            return "Currently \(trend); need to \(need) to reach target"
        case .enRoute(let eta, _, _):
            return "Estimated arrival \(Date().addingTimeInterval(eta).formatted(date: .omitted, time: .shortened))"
        case .insufficientData:
            return "Keep the probe connected for ~30s"
        case .flat:
            return "Wait for a clearer heat-up or cool-down"
        default:
            return nil
        }
    }

    private func formatRate(_ fPerMin: Double) -> String {
        let sign = fPerMin >= 0 ? "+" : ""
        return String(format: "%@%.1f°/min", sign, fPerMin)
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "ETA ≈ \(Int(seconds)) sec" }
        if seconds < 7200 { return "ETA ≈ \(Int((seconds / 60).rounded())) min" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return "ETA ≈ \(h)h \(m)m"
    }
}

private enum TargetEstimator {
    /// Minimum |slope| in °F per minute to produce an ETA.
    static let minRateFPerMinute = 0.08
  /// Reject ETAs beyond this (unstable extrapolation).
    static let maxETA: TimeInterval = 48 * 3600

    static func project(currentF: Double, targetF: Double, history: [ReadingRow]) -> TargetProjection {
        if abs(currentF - targetF) < 0.5 { return .atTarget }

        let now = Date()
        let recent = history.filter { now.timeIntervalSince($0.time) <= 600 }.suffix(80)
        guard recent.count >= 4 else { return .insufficientData }

        let points = Array(recent)
        let t0 = points.first!.time
        var sumT = 0.0, sumY = 0.0, sumTT = 0.0, sumTY = 0.0
        let n = Double(points.count)
        for p in points {
            let t = p.time.timeIntervalSince(t0)
            let y = p.fahrenheit
            sumT += t
            sumY += y
            sumTT += t * t
            sumTY += t * y
        }
        let denom = n * sumTT - sumT * sumT
        guard abs(denom) > 1e-9 else { return .flat }

        let slopePerSec = (n * sumTY - sumT * sumY) / denom
        let slopePerMin = slopePerSec * 60
        guard abs(slopePerMin) >= minRateFPerMinute else { return .flat }

        let heating = slopePerSec > 0
        let targetAbove = targetF > currentF
        if heating != targetAbove { return .wrongDirection(heating: heating, targetAbove: targetAbove) }

        let seconds = (targetF - currentF) / slopePerSec
        guard seconds.isFinite, seconds > 0, seconds <= maxETA else { return .flat }

        return .enRoute(eta: seconds, rateFPerMinute: slopePerMin, heating: heating)
    }
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

struct ReadingRow: Identifiable, Equatable {
    let id: UUID
    let time: Date
    let fahrenheit: Double
    let raw: Int32

    init(id: UUID = UUID(), time: Date, fahrenheit: Double, raw: Int32) {
        self.id = id
        self.time = time
        self.fahrenheit = fahrenheit
        self.raw = raw
    }

    init(stored: StoredReading) {
        id = stored.id
        time = stored.time
        fahrenheit = stored.fahrenheit
        raw = stored.raw
    }
}

private enum ConfigPaths {
    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/bluedot-receiver", isDirectory: true)
    }

    static var ingestConfig: URL { configDir.appendingPathComponent("config.json") }
    static var preferences: URL { configDir.appendingPathComponent("preferences.json") }
    static var cooks: URL { configDir.appendingPathComponent("cooks.json") }
}

/// Gap with no readings before starting a new cook automatically.
private let cookGapSeconds: TimeInterval = 24 * 3600

private struct CookArchiveFile: Codable {
    var version: Int = 1
    var cooks: [CookSession]
    var activeCookId: UUID?
}

struct CookSession: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String?
    var probeUUID: String?
    var startedAt: Date
    var endedAt: Date?
    var readings: [StoredReading]

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var isActive: Bool { endedAt == nil }

    var minF: Double? { readings.map(\.fahrenheit).min() }
    var maxF: Double? { readings.map(\.fahrenheit).max() }

    var dayBucket: String {
        startedAt.formatted(.dateTime.year().month().day())
    }
}

struct StoredReading: Codable, Identifiable, Equatable {
    let id: UUID
    let time: Date
    let fahrenheit: Double
    let raw: Int32
}

private enum CookArchiveIO {
    static func load() -> CookArchiveFile {
        guard let data = try? Data(contentsOf: ConfigPaths.cooks),
              let file = try? JSONDecoder().decode(CookArchiveFile.self, from: data)
        else {
            return CookArchiveFile(cooks: [], activeCookId: nil)
        }
        return file
    }

    static func save(_ file: CookArchiveFile) {
        try? FileManager.default.createDirectory(at: ConfigPaths.configDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: ConfigPaths.cooks, options: .atomic)
    }
}

private enum ConfigLoader {
    static func loadIngest() -> IngestConfig? {
        guard let data = try? Data(contentsOf: ConfigPaths.ingestConfig),
              let cfg = try? JSONDecoder().decode(IngestConfig.self, from: data),
              !cfg.ingestURL.isEmpty, !cfg.token.isEmpty
        else { return nil }
        return cfg
    }

    static func saveIngest(_ cfg: IngestConfig) throws {
        try FileManager.default.createDirectory(at: ConfigPaths.configDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(cfg).write(to: ConfigPaths.ingestConfig, options: .atomic)
    }

    static func loadPreferences() -> AppPreferences {
        guard let data = try? Data(contentsOf: ConfigPaths.preferences),
              let prefs = try? JSONDecoder().decode(AppPreferences.self, from: data)
        else { return .defaults }
        return prefs
    }

    static func savePreferences(_ prefs: AppPreferences) throws {
        try FileManager.default.createDirectory(at: ConfigPaths.configDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(prefs).write(to: ConfigPaths.preferences, options: .atomic)
    }

    static func publicPageURL(from ingest: IngestConfig) -> String {
        var base = ingest.ingestURL
        if base.hasSuffix("/api/ingest") { base = String(base.dropLast("/api/ingest".count)) }
        else if let range = base.range(of: "/api/ingest") { base = String(base[..<range.lowerBound]) }
        return base.isEmpty ? ingest.ingestURL : base
    }
}

private final class Broadcaster {
    private let session = URLSession(configuration: .default)
    private var lastPost: Date?
    private let minInterval: TimeInterval = 2.0

    var lastHTTPStatus: Int?
    var lastError: String?

    func post(
        paused: Bool,
        connection: String,
        temperatureF: Double?,
        raw: Int32?,
        deviceName: String?,
        deviceUUID: String?
    ) {
        guard !paused else { return }
        guard let cfg = ConfigLoader.loadIngest(), let endpoint = URL(string: cfg.ingestURL) else {
            DispatchQueue.main.async { self.lastError = "No ingest config" }
            return
        }

        let payload: IngestPayload
        if let temperatureF {
            let now = Date()
            if let lastPost, now.timeIntervalSince(lastPost) < minInterval { return }
            self.lastPost = now
            payload = IngestPayload(
                temperatureF: temperatureF,
                unit: "F",
                raw: raw ?? 0,
                updatedAt: iso8601(now),
                connection: connection,
                deviceName: deviceName,
                deviceUUID: deviceUUID
            )
        } else {
            payload = IngestPayload(
                temperatureF: -1,
                unit: "F",
                raw: 0,
                updatedAt: iso8601(Date()),
                connection: connection,
                deviceName: deviceName,
                deviceUUID: deviceUUID
            )
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(payload)
        session.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                if let error {
                    self.lastError = error.localizedDescription
                } else {
                    self.lastError = nil
                    self.lastHTTPStatus = (response as? HTTPURLResponse)?.statusCode
                }
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
    return (Double(raw), raw)
}

// MARK: - Theme

private enum Theme {
    static let ink = Color(red: 0.05, green: 0.07, blue: 0.11)
    static let panel = Color.white.opacity(0.07)
    static let panelStroke = Color.white.opacity(0.12)
    static let mint = Color(red: 0.43, green: 0.91, blue: 0.68)
    static let sky = Color(red: 0.35, green: 0.55, blue: 0.95)
    static let ember = Color(red: 0.98, green: 0.55, blue: 0.28)
    static let label = Color(red: 0.88, green: 0.91, blue: 0.95)
    static let muted = Color(red: 0.55, green: 0.62, blue: 0.72)

    static func heatColor(fahrenheit: Double) -> Color {
        let t = min(max(fahrenheit, 32), 220)
        let u = (t - 32) / (220 - 32)
        return Color(
            red: 0.35 + u * 0.55,
            green: 0.75 - u * 0.35,
            blue: 0.95 - u * 0.65
        )
    }
}

// MARK: - Bluetooth store

struct ProbeSummary: Identifiable, Equatable {
    var id: String { uuid }
    let uuid: String
    var name: String
    var connectionState: String
    var lastTemperature: Double?
    var lastUpdated: Date?
    var lastRSSI: Int?
}

private final class ProbeSlot {
    let uuid: String
    var peripheral: CBPeripheral?
    var tempCharacteristic: CBCharacteristic?
    var connectionState = "connecting"
    var displayName: String?
    var lastTemperature: Double?
    var lastRaw: Int32?
    var lastRSSI: Int?
    var lastUpdated: Date?
    var highAlertSent = false
    var lowAlertSent = false
    var targetAlarmSent = false
    var reconnectWorkItem: DispatchWorkItem?

    init(uuid: String) { self.uuid = uuid }
}

final class BluetoothStore: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var prefs: AppPreferences
    @Published var ingest = IngestConfig(ingestURL: "", token: "")
    @Published var history: [ReadingRow] = []
    @Published var cookSessions: [CookSession] = []
    @Published var activeCookId: UUID?
    @Published var selectedCookId: UUID?
    @Published var connectionState = "connecting"
    @Published var detailLine = "Starting…"
    @Published var lastTemperature: Double?
    @Published var lastRaw: Int32?
    @Published var lastRSSI: Int?
    @Published var sessionMin: Double?
    @Published var sessionMax: Double?
    @Published var lastUpdated: Date?
    @Published var feedStatus = "Tap Test feed to verify the public dashboard."
    @Published var broadcastOK = false
    @Published var targetAlarmRinging = false
    @Published var publicIPv4: String?
    @Published var localIPv4: String?
    @Published var homeIngestStatus = ""
    @Published var probeSummaries: [ProbeSummary] = []
    @Published var probePairingPresented = false
    @Published var probePairingStatus = ""
    @Published var probePairingSucceeded = false
    @Published var probePairingFoundName: String?

    private var manager: CBCentralManager!
    private let localIngest = LocalIngestServer()
    private var probeSlots: [String: ProbeSlot] = [:]
    private var scanningForMoreProbes = false
    private var pairingBaselineUUIDs: Set<String> = []
    private var pairingTimeoutWorkItem: DispatchWorkItem?
    private let broadcaster = Broadcaster()
    private var targetAlarmSnoozeUntil: Date?
    private var pulsePhase = false
    private var didStartBluetooth = false

    var publicURL: String {
        guard !ingest.ingestURL.isEmpty else { return "" }
        return ConfigLoader.publicPageURL(from: ingest)
    }

    var displayValue: Double? {
        guard let f = lastTemperature else { return nil }
        if prefs.useCelsius { return (f - 32) * 5 / 9 }
        return f
    }

    var unitSymbol: String { prefs.useCelsius ? "°C" : "°F" }

    var targetDisplayValue: Double {
        if prefs.useCelsius { return (prefs.targetTempF - 32) * 5 / 9 }
        return prefs.targetTempF
    }

    var targetProjection: TargetProjection {
        guard prefs.targetEnabled else { return .disabled }
        guard let current = lastTemperature else { return .noReading }
        return TargetEstimator.project(currentF: current, targetF: prefs.targetTempF, history: history)
    }

    func setTargetDisplayValue(_ value: Double) {
        if prefs.useCelsius {
            prefs.targetTempF = value * 9 / 5 + 32
        } else {
            prefs.targetTempF = value
        }
        if let slot = probeSlots[prefs.resolvedActiveProbeUUID] {
            slot.targetAlarmSent = false
        }
        targetAlarmRinging = false
    }

    func dismissTargetAlarm() {
        targetAlarmRinging = false
        targetAlarmSnoozeUntil = nil
        AlarmSoundPlayer.shared.stop()
        MenuBarController.shared.sync(store: self)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["bluedot.target"])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["bluedot.target"])
    }

    func snoozeTargetAlarm(minutes: Int) {
        dismissTargetAlarm()
        targetAlarmSnoozeUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    func testNotifications() {
        notify(
            identifier: "bluedot.test",
            title: "BlueDOT test",
            body: "If you see this banner and hear a sound, Mac notifications are working.",
            urgent: false
        )
        RemotePush.send(prefs: prefs, title: "BlueDOT test", body: "iPhone push path OK if you see this on ntfy.")
    }

    var menuBarStatusLine: String {
        if targetAlarmRinging { return "TARGET HIT" }
        if prefs.targetEnabled {
            return "Target \(Int(targetDisplayValue))\(unitSymbol)"
        }
        switch connectionState {
        case "connected": return "Live"
        case "connecting": return "Connecting…"
        default: return connectionState.replacingOccurrences(of: "_", with: " ")
        }
    }

    override init() {
        prefs = ConfigLoader.loadPreferences()
        if let cfg = ConfigLoader.loadIngest() { ingest = cfg }
        super.init()
        ensureProbeSlotsFromPrefs()
        loadCookArchive()
        Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pulsePhase.toggle()
                MenuBarController.shared.sync(store: self)
            }
        }
    }

    func start() {
        guard !didStartBluetooth else { return }
        didStartBluetooth = true

        let center = UNUserNotificationCenter.current()
        NotificationDelegate.shared.store = self
        NotificationDelegate.shared.registerCategories()
        center.delegate = NotificationDelegate.shared
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        MenuBarController.shared.attach(store: self)
        refreshNetworkAddresses()

        // State-restore identifier is iOS-only; on macOS it aborts inside CoreBluetooth.
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func saveAll() {
        do {
            prefs.syncLegacyDeviceUUID()
            try ConfigLoader.saveIngest(ingest)
            try ConfigLoader.savePreferences(prefs)
            MenuBarController.shared.sync(store: self)
        } catch {
            detailLine = "Save failed: \(error.localizedDescription)"
        }
    }

    func displayName(forProbeUUID uuid: String) -> String {
        if let custom = prefs.probeNames[uuid], !custom.isEmpty { return custom }
        if let slot = probeSlots[uuid], let n = slot.displayName, !n.isEmpty { return n }
        return "BlueDOT"
    }

    func selectProbe(_ uuid: String) {
        guard prefs.savedProbeUUIDs.contains(uuid) else { return }
        prefs.activeProbeUUID = uuid
        prefs.deviceUUID = uuid
        try? ConfigLoader.savePreferences(prefs)
        syncPublishedFromActiveProbe()
        reloadActiveHistory()
        recomputeSessionStats()
        MenuBarController.shared.sync(store: self)
    }

    func renameProbe(_ uuid: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            prefs.probeNames.removeValue(forKey: uuid)
        } else {
            prefs.probeNames[uuid] = trimmed
        }
        saveAll()
        refreshProbeSummaries()
    }

    func forgetProbe(_ uuid: String) {
        disconnectProbe(uuid)
        prefs.savedProbeUUIDs.removeAll { $0 == uuid }
        prefs.probeNames.removeValue(forKey: uuid)
        probeSlots.removeValue(forKey: uuid)
        if prefs.resolvedActiveProbeUUID == uuid {
            prefs.activeProbeUUID = prefs.savedProbeUUIDs.first ?? ""
            prefs.deviceUUID = prefs.activeProbeUUID
        }
        saveAll()
        refreshProbeSummaries()
        syncPublishedFromActiveProbe()
        beginConnectionAttempt()
    }

    func startProbePairing() {
        probePairingPresented = true
        probePairingSucceeded = false
        probePairingFoundName = nil
        pairingBaselineUUIDs = Set(prefs.savedProbeUUIDs)
        pairingTimeoutWorkItem?.cancel()

        guard let manager else {
            probePairingStatus = "Bluetooth is still starting. Try again in a moment."
            return
        }
        switch manager.state {
        case .poweredOn:
            probePairingStatus = "Looking for a BlueDOT near your Mac…"
            beginScanForAdditionalProbe()
            scheduleProbePairingTimeout()
        case .poweredOff:
            probePairingStatus = "Turn on Bluetooth in Control Center, then tap Try again."
        case .unauthorized:
            probePairingStatus = "Allow Bluetooth for BlueDOT Manager in System Settings → Privacy & Security."
        default:
            probePairingStatus = "Bluetooth isn’t ready yet (status \(manager.state.rawValue)). Try again shortly."
        }
    }

    func cancelProbePairing() {
        pairingTimeoutWorkItem?.cancel()
        scanningForMoreProbes = false
        probePairingPresented = false
        probePairingSucceeded = false
        if let manager, allSlotsConnected() { manager.stopScan() }
    }

    func retryProbePairing() {
        probePairingSucceeded = false
        probePairingFoundName = nil
        startProbePairing()
    }

    private func scheduleProbePairingTimeout() {
        pairingTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.probePairingPresented, !self.probePairingSucceeded else { return }
                self.scanningForMoreProbes = false
                self.probePairingStatus = "No new BlueDOT found yet."
                self.manager?.stopScan()
            }
        }
        pairingTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 75, execute: work)
    }

    private func beginScanForAdditionalProbe() {
        scanningForMoreProbes = true
        detailLine = "Scanning for another BlueDOT…"
        guard let manager, manager.state == .poweredOn else { return }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func markProbePairingFound(peripheral: CBPeripheral, name: String) {
        guard probePairingPresented, !probePairingSucceeded else { return }
        let uuid = peripheral.identifier.uuidString
        guard !pairingBaselineUUIDs.contains(uuid) else { return }
        pairingTimeoutWorkItem?.cancel()
        let label = name.isEmpty ? displayName(forProbeUUID: uuid) : name
        probePairingFoundName = label
        probePairingStatus = "Found \(label). Connecting…"
    }

    private func completeProbePairingSuccess(for uuid: String) {
        guard probePairingPresented, !pairingBaselineUUIDs.contains(uuid) else { return }
        pairingTimeoutWorkItem?.cancel()
        scanningForMoreProbes = false
        probePairingSucceeded = true
        let label = displayName(forProbeUUID: uuid)
        probePairingFoundName = label
        probePairingStatus = "\(label) is ready to use."
        saveAll()
        refreshProbeSummaries()
        if let manager, allSlotsConnected() { manager.stopScan() }
    }

    private func ensureProbeSlotsFromPrefs() {
        for uuid in prefs.savedProbeUUIDs where probeSlots[uuid] == nil {
            probeSlots[uuid] = ProbeSlot(uuid: uuid)
        }
        refreshProbeSummaries()
        syncPublishedFromActiveProbe()
    }

    private func slot(for peripheral: CBPeripheral) -> ProbeSlot? {
        probeSlots[peripheral.identifier.uuidString]
    }

    private func ensureSlot(for uuid: String) -> ProbeSlot {
        if let existing = probeSlots[uuid] { return existing }
        let slot = ProbeSlot(uuid: uuid)
        probeSlots[uuid] = slot
        return slot
    }

    private func refreshProbeSummaries() {
        let uuids = prefs.savedProbeUUIDs
        probeSummaries = uuids.map { uuid in
            let slot = probeSlots[uuid]
            return ProbeSummary(
                uuid: uuid,
                name: displayName(forProbeUUID: uuid),
                connectionState: slot?.connectionState ?? "connecting",
                lastTemperature: slot?.lastTemperature,
                lastUpdated: slot?.lastUpdated,
                lastRSSI: slot?.lastRSSI
            )
        }
    }

    private func syncPublishedFromActiveProbe() {
        let uuid = prefs.resolvedActiveProbeUUID
        guard !uuid.isEmpty, let slot = probeSlots[uuid] else {
            if let any = probeSummaries.first, let slot = probeSlots[any.uuid] {
                applyPublished(from: slot)
            }
            refreshProbeSummaries()
            return
        }
        applyPublished(from: slot)
        refreshProbeSummaries()
    }

    private func applyPublished(from slot: ProbeSlot) {
        connectionState = slot.connectionState
        lastTemperature = slot.lastTemperature
        lastRaw = slot.lastRaw
        lastRSSI = slot.lastRSSI
        lastUpdated = slot.lastUpdated
        if slot.connectionState == "connected", slot.lastTemperature != nil {
            detailLine = "Live · \(displayName(forProbeUUID: slot.uuid))"
        } else if slot.connectionState == "connecting" {
            detailLine = "Connecting \(displayName(forProbeUUID: slot.uuid))…"
        }
    }

    private func activeCookSessionIndex(forProbe uuid: String) -> Int? {
        cookSessions.firstIndex { $0.isActive && ($0.probeUUID == uuid || ($0.probeUUID == nil && uuid == prefs.savedProbeUUIDs.first)) }
    }

    func toggleUnit() {
        prefs.useCelsius.toggle()
        try? ConfigLoader.savePreferences(prefs)
    }

    // MARK: Cook sessions

    private func loadCookArchive() {
        var file = CookArchiveIO.load()
        splitStaleActiveCook(&file)
        let probe = prefs.resolvedActiveProbeUUID
        if probe.isEmpty {
            if file.activeCookId == nil {
                let cook = CookSession(id: UUID(), title: nil, probeUUID: nil, startedAt: Date(), endedAt: nil, readings: [])
                file.cooks.append(cook)
                file.activeCookId = cook.id
                CookArchiveIO.save(file)
            }
        } else if activeCookSessionIndex(forProbe: probe) == nil {
            startNewCook(manual: false, probeUUID: probe)
        }
        cookSessions = file.cooks.sorted { $0.startedAt > $1.startedAt }
        activeCookId = activeCookSessionIndex(forProbe: probe).map { cookSessions[$0].id }
            ?? file.activeCookId
        selectedCookId = activeCookId
        reloadActiveHistory()
        recomputeSessionStats()
    }

    private func persistCooks() {
        let file = CookArchiveFile(version: 1, cooks: cookSessions, activeCookId: activeCookId)
        CookArchiveIO.save(file)
    }

    private func splitStaleActiveCook(_ file: inout CookArchiveFile) {
        for idx in file.cooks.indices {
            let cook = file.cooks[idx]
            guard cook.isActive else { continue }
            let last = cook.readings.last?.time ?? cook.startedAt
            if Date().timeIntervalSince(last) >= cookGapSeconds {
                file.cooks[idx].endedAt = last
                if file.activeCookId == cook.id { file.activeCookId = nil }
            }
        }
    }

    private func ensureActiveCookForNewReading(probeUUID: String) {
        splitStaleOnCurrentArchiveIfNeeded(probeUUID: probeUUID)
        if activeCookSessionIndex(forProbe: probeUUID) == nil {
            startNewCook(manual: false, probeUUID: probeUUID)
        }
    }

    private func splitStaleOnCurrentArchiveIfNeeded(probeUUID: String) {
        guard let idx = activeCookSessionIndex(forProbe: probeUUID) else { return }
        let cook = cookSessions[idx]
        if let last = cook.readings.last,
           Date().timeIntervalSince(last.time) >= cookGapSeconds {
            cookSessions[idx].endedAt = last.time
            if prefs.resolvedActiveProbeUUID == probeUUID {
                activeCookId = nil
                history = []
            }
            persistCooks()
        }
    }

    func startNewCook(manual: Bool = true, probeUUID: String? = nil) {
        let probe = probeUUID ?? prefs.resolvedActiveProbeUUID
        if let idx = activeCookSessionIndex(forProbe: probe) {
            cookSessions[idx].endedAt = Date()
        }
        let cook = CookSession(
            id: UUID(),
            title: nil,
            probeUUID: probe.isEmpty ? nil : probe,
            startedAt: Date(),
            endedAt: nil,
            readings: []
        )
        cookSessions.insert(cook, at: 0)
        if probe == prefs.resolvedActiveProbeUUID || probe.isEmpty {
            activeCookId = cook.id
            selectedCookId = cook.id
            history = []
            sessionMin = nil
            sessionMax = nil
            if let slot = probeSlots[probe] { slot.targetAlarmSent = false }
            targetAlarmRinging = false
        }
        if manual { detailLine = "New cook started" }
        persistCooks()
    }

    func renameCook(id: UUID, title: String) {
        guard let idx = cookSessions.firstIndex(where: { $0.id == id }) else { return }
        cookSessions[idx].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        persistCooks()
    }

    func cook(for id: UUID) -> CookSession? {
        cookSessions.first { $0.id == id }
    }

    private func reloadActiveHistory() {
        let probe = prefs.resolvedActiveProbeUUID
        guard let idx = activeCookSessionIndex(forProbe: probe) else {
            history = []
            activeCookId = nil
            return
        }
        let cook = cookSessions[idx]
        activeCookId = cook.id
        history = cook.readings.map { ReadingRow(stored: $0) }
    }

    private func recomputeSessionStats() {
        guard !history.isEmpty else {
            sessionMin = nil
            sessionMax = nil
            return
        }
        let temps = history.map(\.fahrenheit)
        sessionMin = temps.min()
        sessionMax = temps.max()
    }

    func reconnect() {
        for slot in probeSlots.values {
            slot.reconnectWorkItem?.cancel()
            if let p = slot.peripheral, let manager { manager.cancelPeripheralConnection(p) }
            slot.peripheral = nil
            slot.tempCharacteristic = nil
            slot.connectionState = "connecting"
        }
        syncPublishedFromActiveProbe()
        beginConnectionAttempt()
    }

    func disconnectManual() {
        for slot in probeSlots.values {
            slot.reconnectWorkItem?.cancel()
            if let p = slot.peripheral, let manager { manager.cancelPeripheralConnection(p) }
            slot.peripheral = nil
            slot.tempCharacteristic = nil
            slot.connectionState = "disconnected"
        }
        manager?.stopScan()
        connectionState = "disconnected"
        detailLine = "Disconnected manually"
        refreshProbeSummaries()
        syncPublishedFromActiveProbe()
    }

    private func disconnectProbe(_ uuid: String) {
        guard let slot = probeSlots[uuid] else { return }
        slot.reconnectWorkItem?.cancel()
        if let p = slot.peripheral, let manager { manager.cancelPeripheralConnection(p) }
        slot.peripheral = nil
        slot.tempCharacteristic = nil
        slot.connectionState = "disconnected"
    }

    func openPublicPage() {
        guard let url = URL(string: publicURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyPublicLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicURL, forType: .string)
    }

    func testPublicFeed() {
        guard let url = URL(string: publicURL + "/api/reading") else {
            feedStatus = "Set ingest URL first."
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            Task { @MainActor in
                if let error {
                    self?.feedStatus = error.localizedDescription
                    self?.broadcastOK = false
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self?.broadcastOK = (200 ... 299).contains(code)
                self?.feedStatus = "HTTP \(code)\n\(body.prefix(280))"
            }
        }.resume()
    }

    // MARK: BLE

    private func scheduleReconnect(for uuid: String, after: TimeInterval = 3.0) {
        let slot = ensureSlot(for: uuid)
        slot.reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connectProbe(uuid: uuid) }
        slot.reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }

    private func savedUUIDList() -> [UUID] {
        prefs.savedProbeUUIDs.compactMap { UUID(uuidString: $0) }
    }

    private func allSlotsConnected() -> Bool {
        guard !prefs.savedProbeUUIDs.isEmpty else { return false }
        return prefs.savedProbeUUIDs.allSatisfy { probeSlots[$0]?.connectionState == "connected" }
    }

    private func connectProbe(uuid: String) {
        guard let manager, manager.state == .poweredOn,
              let id = UUID(uuidString: uuid)
        else { return }
        let slot = ensureSlot(for: uuid)
        if slot.peripheral != nil, slot.connectionState == "connected" { return }
        if let p = manager.retrievePeripherals(withIdentifiers: [id]).first {
            slot.peripheral = p
            slot.connectionState = "connecting"
            p.delegate = self
            manager.connect(p, options: nil)
            refreshProbeSummaries()
            syncPublishedFromActiveProbe()
        }
    }

    private func beginConnectionAttempt() {
        guard let manager, manager.state == .poweredOn else { return }
        connectionState = "connecting"
        ensureProbeSlotsFromPrefs()

        let saved = savedUUIDList()
        if !saved.isEmpty {
            detailLine = saved.count == 1 ? "Connecting…" : "Connecting \(saved.count) probes…"
            for uuid in prefs.savedProbeUUIDs {
                connectProbe(uuid: uuid)
            }
            if !allSlotsConnected() {
                manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
            return
        }
        detailLine = "Scanning for BlueDOT…"
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func rememberDiscoveredProbe(_ peripheral: CBPeripheral, name: String) {
        let uuid = peripheral.identifier.uuidString
        let slot = ensureSlot(for: uuid)
        if !name.isEmpty { slot.displayName = name }
        var changed = false
        if !prefs.savedProbeUUIDs.contains(uuid) {
            prefs.savedProbeUUIDs.append(uuid)
            changed = true
            if prefs.activeProbeUUID.isEmpty {
                prefs.activeProbeUUID = uuid
                prefs.deviceUUID = uuid
            }
        }
        if changed {
            try? ConfigLoader.savePreferences(prefs)
            refreshProbeSummaries()
        }
    }

    func refreshNetworkAddresses() {
        localIPv4 = NetworkEndpoints.localIPv4()
        NetworkEndpoints.fetchPublicIPv4 { [weak self] ip in self?.publicIPv4 = ip }
    }

    func applyHomeNetworkHosting() {
        refreshNetworkAddresses()
        let port = prefs.homeIngestPort
        var token = ingest.token
        if token.isEmpty { token = generateToken(); ingest.token = token }
        let localIngestURL = "http://127.0.0.1:\(port)/api/ingest"
        ingest.ingestURL = localIngestURL
        prefs.dashboardHosting = DashboardHosting.homeNetwork.rawValue
        if let err = localIngest.start(port: port, token: token) {
            homeIngestStatus = err
        } else {
            let remote = publicIPv4.map { "http://\($0):\(port)/" } ?? "http://YOUR_PUBLIC_IP:\(port)/"
            homeIngestStatus = "Server running. Forward TCP \(port) on your router to this Mac. Dashboard: \(remote)"
        }
        saveAll()
    }

    func stopHomeIngestServer() {
        localIngest.stop()
        homeIngestStatus = "Stopped local ingest server."
    }

    var suggestedHomeDashboardURL: String {
        let port = prefs.homeIngestPort
        if let ip = publicIPv4 { return "http://\(ip):\(port)/" }
        return "http://YOUR_PUBLIC_IP:\(port)/"
    }

    private func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                detailLine = "Bluetooth ready."
                beginConnectionAttempt()
            case .unauthorized:
                connectionState = "unauthorized"
                detailLine = "Enable Bluetooth in System Settings."
            case .poweredOff:
                connectionState = "bluetooth_off"
                detailLine = "Turn on Bluetooth."
                postBroadcast(temp: nil, raw: nil)
            default:
                connectionState = "unavailable"
                detailLine = "Bluetooth state: \(central.state.rawValue)"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        Task { @MainActor in
            let uuid = p.identifier.uuidString
            let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
            let savedSet = Set(prefs.savedProbeUUIDs)
            let isKnown = savedSet.contains(uuid)
            let looksLikeBlueDOT = name == preferredLocalName || name.lowercased().contains("bluedot")
            let allowNew = scanningForMoreProbes || prefs.savedProbeUUIDs.isEmpty
            guard isKnown || (looksLikeBlueDOT && allowNew) else { return }

            let slot = ensureSlot(for: uuid)
            slot.lastRSSI = rssi.intValue
            let isNewProbe = !pairingBaselineUUIDs.contains(uuid)
            if scanningForMoreProbes, isNewProbe {
                markProbePairingFound(peripheral: p, name: name)
            }
            rememberDiscoveredProbe(p, name: name)

            if slot.peripheral?.identifier == p.identifier, slot.connectionState == "connected" {
                refreshProbeSummaries()
                if allSlotsConnected(), !scanningForMoreProbes { central.stopScan() }
                return
            }
            slot.peripheral = p
            slot.connectionState = "connecting"
            p.delegate = self
            detailLine = "Found \(name.isEmpty ? uuid : name)"
            central.connect(p, options: nil)
            refreshProbeSummaries()
            syncPublishedFromActiveProbe()

            if allSlotsConnected(), !scanningForMoreProbes { central.stopScan() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in
            let uuid = p.identifier.uuidString
            let slot = ensureSlot(for: uuid)
            slot.connectionState = "connected"
            slot.peripheral = p
            if probePairingPresented, !pairingBaselineUUIDs.contains(uuid) {
                completeProbePairingSuccess(for: uuid)
            } else if !probePairingPresented {
                scanningForMoreProbes = false
            }
            syncPublishedFromActiveProbe()
            detailLine = "Discovering services…"
            if uuid == prefs.resolvedActiveProbeUUID {
                postBroadcast(temp: nil, raw: nil, device: p)
            }
            p.discoverServices(nil)
            refreshProbeSummaries()
            if allSlotsConnected(), !scanningForMoreProbes { central.stopScan() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let uuid = p.identifier.uuidString
            let slot = ensureSlot(for: uuid)
            slot.connectionState = "disconnected"
            detailLine = error?.localizedDescription ?? "Connection failed"
            slot.peripheral = nil
            slot.tempCharacteristic = nil
            if uuid == prefs.resolvedActiveProbeUUID {
                postBroadcast(temp: nil, raw: nil, device: p)
            }
            syncPublishedFromActiveProbe()
            scheduleReconnect(for: uuid)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let uuid = p.identifier.uuidString
            let slot = ensureSlot(for: uuid)
            slot.connectionState = "disconnected"
            if uuid == prefs.resolvedActiveProbeUUID {
                detailLine = error?.localizedDescription ?? "Disconnected — reconnecting…"
            }
            slot.peripheral = nil
            slot.tempCharacteristic = nil
            if uuid == prefs.resolvedActiveProbeUUID {
                postBroadcast(temp: nil, raw: nil, device: p)
            }
            syncPublishedFromActiveProbe()
            scheduleReconnect(for: uuid)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                detailLine = error.localizedDescription
                manager?.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.services?.forEach { peripheral.discoverCharacteristics([tempCharacteristicUUID], for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard error == nil,
                  let temp = service.characteristics?.first(where: { $0.uuid == tempCharacteristicUUID }),
                  let slot = slot(for: peripheral)
            else { return }
            slot.tempCharacteristic = temp
            if peripheral.identifier.uuidString == prefs.resolvedActiveProbeUUID {
                detailLine = "Streaming temperature"
            }
            peripheral.setNotifyValue(true, for: temp)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard error == nil,
                  characteristic.uuid == tempCharacteristicUUID,
                  let data = characteristic.value,
                  let parsed = parseTemperatureF(from: data),
                  let slot = slot(for: peripheral)
            else { return }
            let uuid = peripheral.identifier.uuidString
            slot.lastTemperature = parsed.fahrenheit
            slot.lastRaw = parsed.raw
            slot.lastUpdated = Date()
            if uuid == prefs.resolvedActiveProbeUUID {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    lastTemperature = parsed.fahrenheit
                    lastRaw = parsed.raw
                    lastUpdated = slot.lastUpdated
                }
            }
            refreshProbeSummaries()
            recordReading(parsed.fahrenheit, raw: parsed.raw, probeUUID: uuid)
            if uuid == prefs.resolvedActiveProbeUUID {
                postBroadcast(temp: parsed.fahrenheit, raw: parsed.raw, device: peripheral)
            }
        }
    }

    private func recordReading(_ f: Double, raw: Int32, probeUUID: String) {
        ensureActiveCookForNewReading(probeUUID: probeUUID)
        guard let idx = activeCookSessionIndex(forProbe: probeUUID) else { return }

        let row = StoredReading(id: UUID(), time: Date(), fahrenheit: f, raw: raw)
        cookSessions[idx].readings.append(row)
        if cookSessions[idx].readings.count == 1 {
            cookSessions[idx].startedAt = row.time
        }
        if cookSessions[idx].readings.count > 20_000 {
            cookSessions[idx].readings.removeFirst(cookSessions[idx].readings.count - 20_000)
        }
        if probeUUID == prefs.resolvedActiveProbeUUID {
            reloadActiveHistory()
            sessionMin = min(sessionMin ?? f, f)
            sessionMax = max(sessionMax ?? f, f)
            checkAlerts(f, slot: probeSlots[probeUUID])
            checkTargetAlarm(f, slot: probeSlots[probeUUID])
        }
        persistCooks()
    }

    private func checkTargetAlarm(_ f: Double, slot: ProbeSlot?) {
        guard prefs.targetEnabled, prefs.targetAlarmEnabled else {
            slot?.targetAlarmSent = false
            return
        }
        if let snooze = targetAlarmSnoozeUntil, Date() < snooze { return }
        if let snooze = targetAlarmSnoozeUntil, Date() >= snooze {
            targetAlarmSnoozeUntil = nil
            slot?.targetAlarmSent = false
        }
        let delta = abs(f - prefs.targetTempF)
        if delta <= 0.5 {
            guard slot?.targetAlarmSent != true else { return }
            slot?.targetAlarmSent = true
            targetAlarmRinging = true
            let label = prefs.useCelsius
                ? String(format: "%.0f °C", targetDisplayValue)
                : String(format: "%.0f °F", prefs.targetTempF)
            let probeName = slot.map { displayName(forProbeUUID: $0.uuid) } ?? "BlueDOT"
            let body = "\(probeName) hit target · now \(label)"
            beginTargetAlarm(title: "Target temperature reached", body: body)
        } else if delta > 4 {
            slot?.targetAlarmSent = false
        }
    }

    private func checkAlerts(_ f: Double, slot: ProbeSlot?) {
        guard prefs.alertEnabled, let slot else { return }
        if f >= prefs.alertHighF, !slot.highAlertSent {
            slot.highAlertSent = true
            let name = displayName(forProbeUUID: slot.uuid)
            notify(title: "\(name) high", body: String(format: "Temperature reached %.0f °F", f))
        } else if f < prefs.alertHighF - 2 { slot.highAlertSent = false }
        if f <= prefs.alertLowF, !slot.lowAlertSent {
            slot.lowAlertSent = true
            let name = displayName(forProbeUUID: slot.uuid)
            notify(title: "\(name) low", body: String(format: "Temperature dropped to %.0f °F", f))
        } else if f > prefs.alertLowF + 2 { slot.lowAlertSent = false }
    }

    private func beginTargetAlarm(title: String, body: String) {
        AlarmSoundPlayer.shared.startRepeating()
        notify(identifier: "bluedot.target", title: title, body: body, urgent: true, category: targetAlarmCategoryId)
        RemotePush.send(prefs: prefs, title: title, body: body)
        MenuBarController.shared.sync(store: self)
    }

    private func notify(identifier: String, title: String, body: String, urgent: Bool, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        if urgent, #available(macOS 12.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func notify(title: String, body: String) {
        notify(identifier: UUID().uuidString, title: title, body: body, urgent: false)
    }

    private func postBroadcast(temp: Double?, raw: Int32?, device: CBPeripheral? = nil) {
        let uuid = prefs.resolvedActiveProbeUUID
        let slot = probeSlots[uuid]
        broadcaster.post(
            paused: prefs.broadcastPaused,
            connection: connectionState,
            temperatureF: temp,
            raw: raw,
            deviceName: device?.name ?? slot?.displayName ?? displayName(forProbeUUID: uuid),
            deviceUUID: device?.identifier.uuidString ?? (uuid.isEmpty ? nil : uuid)
        )
    }

    var connectionTint: Color {
        switch connectionState {
        case "connected": return Theme.mint
        case "connecting": return Theme.sky
        case "disconnected", "bluetooth_off": return .red.opacity(0.85)
        default: return Theme.muted
        }
    }
}

final class MenuBarController: NSObject {
    static let shared = MenuBarController()
    private var item: NSStatusItem?
    private weak var store: BluetoothStore?
    private var bellImage: NSImage?
    private var thermImage: NSImage?

    override init() {
        super.init()
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        bellImage = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "Target alarm")?.withSymbolConfiguration(cfg)
        thermImage = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "Temperature")?.withSymbolConfiguration(cfg)
    }

    func attach(store: BluetoothStore) {
        self.store = store
        sync(store: store)
    }

    func sync(store: BluetoothStore?) {
        DispatchQueue.main.async {
            guard let store else { return }
            if !store.prefs.menuBarEnabled {
                if let item = self.item { NSStatusBar.system.removeStatusItem(item) }
                self.item = nil
                return
            }
            if self.item == nil {
                self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
            guard let button = self.item?.button else { return }

            if store.targetAlarmRinging {
                button.image = self.bellImage
                button.imagePosition = .imageLeading
                button.contentTintColor = .systemOrange
                button.title = store.displayValue.map { String(format: " %.0f%@ ", $0, store.unitSymbol) } ?? " ALARM "
            } else {
                button.image = self.thermImage
                button.imagePosition = .imageLeading
                button.contentTintColor = store.connectionState == "connected" ? .systemGreen : .secondaryLabelColor
                if let v = store.displayValue {
                    if store.prefs.targetEnabled {
                        button.title = String(format: " %.0f%@ → %.0f ", v, store.unitSymbol, store.targetDisplayValue)
                    } else {
                        button.title = String(format: " %.0f%@ ", v, store.unitSymbol)
                    }
                } else {
                    button.title = " — "
                }
            }

            button.toolTip = self.tooltip(for: store)
            self.item?.menu = self.buildMenu(for: store)
        }
    }

    private func tooltip(for store: BluetoothStore) -> String {
        var lines: [String] = []
        if let t = store.lastTemperature {
            lines.append("Current: \(Int(t))°F")
        }
        if store.prefs.targetEnabled {
            lines.append("Target: \(Int(store.prefs.targetTempF))°F")
            lines.append(store.targetProjection.headline)
        }
        if store.targetAlarmRinging { lines.append("🔔 Target reached — tap menu to dismiss") }
        return lines.joined(separator: "\n")
    }

    private func buildMenu(for store: BluetoothStore) -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem()
        header.isEnabled = false
        if let v = store.displayValue {
            header.title = "Now \(String(format: "%.0f", v))\(store.unitSymbol)"
        } else {
            header.title = "No reading"
        }
        menu.addItem(header)

        let status = NSMenuItem()
        status.isEnabled = false
        status.title = store.menuBarStatusLine
        menu.addItem(status)

        if store.prefs.targetEnabled {
            let eta = NSMenuItem()
            eta.isEnabled = false
            eta.title = store.targetProjection.headline
            menu.addItem(eta)
        }

        if store.targetAlarmRinging {
            let alarm = NSMenuItem(title: "Dismiss alarm", action: #selector(dismissAlarm), keyEquivalent: "d")
            alarm.keyEquivalentModifierMask = [.command]
            alarm.target = self
            menu.insertItem(alarm, at: 0)
        }

        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show BlueDOT Manager", action: #selector(focusApp), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        if let url = URL(string: store.publicURL), !store.publicURL.isEmpty {
            let web = NSMenuItem(title: "Open live dashboard", action: #selector(openDashboard), keyEquivalent: "")
            web.target = self
            web.representedObject = url
            menu.addItem(web)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func dismissAlarm() {
        store?.dismissTargetAlarm()
        sync(store: store)
    }

    @objc private func focusApp() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil); break }
    }

    @objc private func openDashboard(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - UI components

private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.panelStroke))
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AuroraBackground: View {
    let accent: Color
    @State private var animate = false

    var body: some View {
        ZStack {
            Theme.ink
            Circle()
                .fill(accent.opacity(0.35))
                .frame(width: 420, height: 420)
                .blur(radius: 90)
                .offset(x: animate ? 120 : -80, y: animate ? -120 : 60)
            Circle()
                .fill(Theme.sky.opacity(0.22))
                .frame(width: 360, height: 360)
                .blur(radius: 80)
                .offset(x: animate ? -100 : 90, y: animate ? 140 : -40)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) { animate = true }
        }
    }
}

// MARK: - Screens

private enum SidebarTab: String, CaseIterable, Identifiable {
    case live, history, publicLink, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .history: "History"
        case .publicLink: "Public"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .live: "flame.fill"
        case .history: "chart.xyaxis.line"
        case .publicLink: "globe.americas.fill"
        case .settings: "slider.horizontal.3"
        }
    }
}

private struct LiveScreen: View {
    @EnvironmentObject var store: BluetoothStore

    var body: some View {
        ZStack {
            AuroraBackground(accent: store.lastTemperature.map { Theme.heatColor(fahrenheit: $0) } ?? Theme.sky)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    hero
                    targetCard
                    chartCard
                    statsRow
                    controls
                }
                .padding(28)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ThermoWorks BlueDOT")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                        .textCase(.uppercase)
                        .kerning(1.2)
                    Text(store.detailLine)
                        .font(.callout)
                        .foregroundStyle(Theme.label.opacity(0.85))
                }
                Spacer()
                ConnectionChip(state: store.connectionState, tint: store.connectionTint, rssi: store.lastRSSI)
            }
            if !store.probeSummaries.isEmpty {
                ProbeStrip(store: store)
            }
        }
    }

    private var hero: some View {
        GlassCard {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let v = store.displayValue {
                    Text(String(format: "%.0f", v))
                        .font(.system(size: 92, weight: .thin, design: .rounded))
                        .foregroundStyle(
                            store.lastTemperature.map { Theme.heatColor(fahrenheit: $0) } ?? Theme.label
                        )
                        .contentTransition(.numericText())
                } else {
                    Text("—")
                        .font(.system(size: 92, weight: .thin, design: .rounded))
                        .foregroundStyle(Theme.muted)
                }
                Text(store.unitSymbol)
                    .font(.system(size: 36, weight: .light, design: .rounded))
                    .foregroundStyle(Theme.muted)
                    .padding(.bottom, 12)
                Spacer()
                if let updated = store.lastUpdated {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(updated, style: .relative)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    private var targetCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Target temperature", systemImage: "scope")
                        .font(.headline)
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Toggle("Track", isOn: $store.prefs.targetEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: store.prefs.targetEnabled) { _, enabled in
                            if !enabled {
                                store.targetAlarmRinging = false
                            }
                            store.saveAll()
                        }
                }
                Toggle(isOn: $store.prefs.targetAlarmEnabled) {
                    Label("Alarm when target is reached", systemImage: "bell.badge")
                }
                .disabled(!store.prefs.targetEnabled)
                .onChange(of: store.prefs.targetAlarmEnabled) { _, _ in store.saveAll() }
                if store.targetAlarmRinging {
                    HStack {
                        Label("Target reached", systemImage: "bell.fill")
                            .foregroundStyle(Theme.ember)
                        Spacer()
                        Button("Dismiss") { store.dismissTargetAlarm() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.ember)
                    }
                }
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        TextField("Target", value: Binding(
                            get: { store.targetDisplayValue },
                            set: { store.setTargetDisplayValue($0); store.saveAll() }
                        ), format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 88)
                        .disabled(!store.prefs.targetEnabled)
                        Text(store.unitSymbol)
                            .foregroundStyle(Theme.muted)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.targetProjection.headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(projectionColor(store.targetProjection))
                        if let detail = store.targetProjection.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
    }

    private func projectionColor(_ p: TargetProjection) -> Color {
        switch p {
        case .enRoute, .atTarget: Theme.mint
        case .wrongDirection: Theme.ember
        case .flat, .insufficientData: Theme.sky
        default: Theme.muted
        }
    }

    private var chartCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Temperature trend", systemImage: "waveform.path.ecg")
                    .font(.headline)
                    .foregroundStyle(Theme.label)
                Chart {
                    ForEach(store.history.suffix(90)) { row in
                        AreaMark(
                            x: .value("Time", row.time),
                            y: .value("°F", row.fahrenheit)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.mint.opacity(0.45), Theme.mint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Time", row.time),
                            y: .value("°F", row.fahrenheit)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Theme.mint)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    }
                    if store.prefs.targetEnabled {
                        RuleMark(y: .value("Target", store.prefs.targetTempF))
                            .foregroundStyle(Theme.ember.opacity(0.9))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("Target \(Int(store.targetDisplayValue))\(store.unitSymbol)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.ember)
                            }
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.08))
                        AxisValueLabel().foregroundStyle(Theme.muted)
                    }
                }
                .frame(height: 200)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 14) {
            StatTile(title: "Session min", value: store.sessionMin.map { String(format: "%.0f°", $0) } ?? "—", symbol: "arrow.down.circle")
            StatTile(title: "Session max", value: store.sessionMax.map { String(format: "%.0f°", $0) } ?? "—", symbol: "arrow.up.circle")
            StatTile(title: "Samples", value: "\(store.history.count)", symbol: "dot.radiowaves.left.and.right")
            StatTile(title: "Raw BLE", value: store.lastRaw.map { "\($0)" } ?? "—", symbol: "bolt.horizontal.circle")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { store.reconnect() } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.sky)

            Button { store.disconnectManual() } label: {
                Label("Disconnect", systemImage: "pause.circle")
            }
            .buttonStyle(.bordered)

            Button { store.toggleUnit() } label: {
                Label(store.prefs.useCelsius ? "Show °F" : "Show °C", systemImage: "thermometer.medium")
            }
            .buttonStyle(.bordered)

            Button { store.startNewCook() } label: {
                Label("New cook", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)

            Spacer()

            Toggle(isOn: $store.prefs.broadcastPaused) {
                Label("Pause broadcast", systemImage: "antenna.radiowaves.left.and.right.slash")
            }
            .toggleStyle(.switch)
            .onChange(of: store.prefs.broadcastPaused) { _, _ in store.saveAll() }
        }
    }
}

private struct ProbeStrip: View {
    @ObservedObject var store: BluetoothStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.probeSummaries) { probe in
                    ProbeChip(
                        probe: probe,
                        isActive: probe.uuid == store.prefs.resolvedActiveProbeUUID,
                        unit: store.unitSymbol,
                        useCelsius: store.prefs.useCelsius
                    ) {
                        store.selectProbe(probe.uuid)
                    }
                }
            }
        }
    }
}

private struct ProbeChip: View {
    let probe: ProbeSummary
    let isActive: Bool
    let unit: String
    let useCelsius: Bool
    let onSelect: () -> Void

    private var tempLabel: String {
        guard let f = probe.lastTemperature else { return "—" }
        let v = useCelsius ? (f - 32) * 5 / 9 : f
        return String(format: "%.0f%@", v, unit)
    }

    private var tint: Color {
        switch probe.connectionState {
        case "connected": Theme.mint
        case "connecting": Theme.sky
        default: .red.opacity(0.85)
        }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(probe.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Text(tempLabel)
                    .font(.title3.weight(.medium).monospacedDigit())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isActive ? tint.opacity(0.22) : Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive ? tint.opacity(0.55) : Theme.panelStroke, lineWidth: isActive ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ConnectionChip: View {
    let state: String
    let tint: Color
    let rssi: Int?

  var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .shadow(color: tint.opacity(0.8), radius: 6)
            Text(state.replacingOccurrences(of: "_", with: " "))
                .font(.caption.weight(.semibold))
            if let rssi {
                Text("· \(rssi) dBm")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(Theme.label)
    }
}

private struct HistoryScreen: View {
    @EnvironmentObject var store: BluetoothStore
    private var grouped: [(day: String, cooks: [CookSession])] {
        let past = store.cookSessions.filter { !$0.isActive }
        let groups = Dictionary(grouping: past, by: \.dayBucket)
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.startedAt > $1.startedAt }) }
    }

    var body: some View {
        NavigationSplitView {
            ZStack {
                Theme.ink.ignoresSafeArea()
                List(selection: $store.selectedCookId) {
                    if let activeId = store.activeCookId, let active = store.cook(for: activeId) {
                        Section("Active cook") {
                            CookRow(cook: active, isActive: true)
                                .tag(active.id)
                        }
                    }
                    ForEach(grouped, id: \.day) { bucket in
                        Section(bucket.day) {
                            ForEach(bucket.cooks) { cook in
                                CookRow(cook: cook, isActive: false)
                                    .tag(cook.id)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Cooks")
            .toolbar {
                Button {
                    store.startNewCook()
                } label: {
                    Label("New cook", systemImage: "plus.circle")
                }
            }
        } detail: {
            if let id = store.selectedCookId, let cook = store.cook(for: id) {
                CookDetailView(cook: cook, onRename: { title in store.renameCook(id: id, title: title) })
            } else {
                ContentUnavailableView("Select a cook", systemImage: "clock.arrow.circlepath")
            }
        }
    }
}

private struct CookRow: View {
    @EnvironmentObject var store: BluetoothStore
    let cook: CookSession
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(cook.displayTitle)
                    .font(.headline)
                if isActive {
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.mint.opacity(0.25), in: Capsule())
                }
            }
            HStack(spacing: 8) {
                if let probe = cook.probeUUID {
                    Text(store.displayName(forProbeUUID: probe))
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                }
                Text("\(cook.readings.count) pts")
                if let min = cook.minF, let max = cook.maxF {
                    Text("· \(Int(min))–\(Int(max))°F")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 4)
    }
}

private struct CookDetailView: View {
    let cook: CookSession
    var onRename: (String) -> Void
    @State private var title: String = ""

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField("Cook title (e.g. Brisket)", text: $title, onCommit: { onRename(title) })
                            .textFieldStyle(.roundedBorder)
                        Button("Save title") { onRename(title) }
                    }
                    if cook.readings.count >= 2 {
                        Chart(cook.readings) { r in
                            LineMark(x: .value("t", r.time), y: .value("°F", r.fahrenheit))
                                .foregroundStyle(Theme.mint)
                        }
                        .frame(height: 180)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(cook.readings.reversed()) { r in
                            HStack {
                                Text(r.time, style: .time)
                                Spacer()
                                Text(String(format: "%.0f °F", r.fahrenheit))
                                    .foregroundStyle(Theme.heatColor(fahrenheit: r.fahrenheit))
                            }
                            .font(.callout)
                            .padding(.vertical, 6)
                            Divider().opacity(0.15)
                        }
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle(cook.displayTitle)
        .onAppear { title = cook.title ?? "" }
    }
}

private struct PublicScreen: View {
    @EnvironmentObject var store: BluetoothStore

    var body: some View {
        ZStack {
            AuroraBackground(accent: store.broadcastOK ? Theme.mint : Theme.ember)
            VStack(alignment: .leading, spacing: 20) {
                Text("Remote dashboard")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.label)
                Text("Share this link — no secrets in the browser.")
                    .foregroundStyle(Theme.muted)

                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(store.publicURL.isEmpty ? "Configure ingest URL in Settings" : store.publicURL)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(Theme.label)
                        HStack {
                            Button("Open in browser", action: store.openPublicPage)
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.mint)
                            Button("Copy link", action: store.copyPublicLink)
                                .buttonStyle(.bordered)
                            Button("Test feed", action: store.testPublicFeed)
                                .buttonStyle(.bordered)
                        }
                    }
                }

                GlassCard {
                    Label(store.broadcastOK ? "Feed reachable" : "Feed not verified", systemImage: store.broadcastOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(store.broadcastOK ? Theme.mint : Theme.ember)
                    Text(store.feedStatus)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(32)
        }
    }
}

private struct ProbePairingSheet: View {
    @EnvironmentObject var store: BluetoothStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: store.probePairingSucceeded ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 28))
                    .foregroundStyle(store.probePairingSucceeded ? Theme.mint : Theme.sky)
                    .symbolEffect(.pulse, options: store.probePairingSucceeded ? .default : .repeating)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.probePairingSucceeded ? "BlueDOT added" : "Add a BlueDOT")
                        .font(.title2.weight(.bold))
                    Text(store.probePairingStatus)
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                }
            }

            if !store.probePairingSucceeded {
                VStack(alignment: .leading, spacing: 10) {
                    pairingStep("1", "On your BlueDOT", "Press the power button until the display wakes up.")
                    pairingStep("2", "Stay close", "Keep the probe within a few feet of this Mac.")
                    pairingStep("3", "Wait", "We’ll connect automatically when it appears.")
                }
                .padding(16)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching…")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
            } else if let name = store.probePairingFoundName {
                Label("\(name) is connected", systemImage: "thermometer.medium")
                    .font(.headline)
                    .foregroundStyle(Theme.mint)
                Text("Switch live view from the Live tab, or tap Done.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            }

            HStack {
                if store.probePairingSucceeded {
                    Button("Done") {
                        store.cancelProbePairing()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.mint)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") {
                        store.cancelProbePairing()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Try again") { store.retryProbePairing() }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(28)
        .frame(width: 440)
        .background(Theme.ink)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            if store.probePairingStatus.isEmpty {
                store.startProbePairing()
            }
        }
    }

    private func pairingStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Theme.sky.opacity(0.35), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct SettingsScreen: View {
    @EnvironmentObject var store: BluetoothStore
    @EnvironmentObject var updater: UpdateController

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            Form {
                Section {
                    Picker("Hosting", selection: Binding(
                        get: { store.prefs.hosting },
                        set: { store.prefs.dashboardHosting = $0.rawValue }
                    )) {
                        ForEach(DashboardHosting.allCases) { h in
                            Text(h.label).tag(h)
                        }
                    }
                    if store.prefs.hosting == .cloudflare {
                        TextField("Ingest URL", text: $store.ingest.ingestURL)
                        SecureField("Bearer token", text: $store.ingest.token)
                        Text("Use a Cloudflare Worker URL ending in /api/ingest (see README).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Port", value: $store.prefs.homeIngestPort, format: .number)
                        if let lan = store.localIPv4 {
                            LabeledContent("This Mac (LAN)", value: lan)
                        }
                        if let pub = store.publicIPv4 {
                            LabeledContent("Your public IP", value: pub)
                        }
                        Text(store.suggestedHomeDashboardURL)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text(store.homeIngestStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Detect IPs") { store.refreshNetworkAddresses() }
                            Button("Start home server") { store.applyHomeNetworkHosting() }
                            Button("Stop") { store.stopHomeIngestServer() }
                        }
                        Text("On your router, forward the port above to this Mac. Visitors use http://PUBLIC_IP:PORT/ (HTTP, not HTTPS).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Live dashboard")
                }
                Section {
                    if store.prefs.savedProbeUUIDs.isEmpty {
                        Text("BlueDOT probes are found automatically on first launch. Tap “Add BlueDOT…” to pair another unit.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.probeSummaries) { probe in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("Name", text: Binding(
                                    get: { store.prefs.probeNames[probe.uuid] ?? probe.name },
                                    set: { store.renameProbe(probe.uuid, name: $0) }
                                ))
                                Text(probe.uuid)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(probe.connectionState.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if probe.uuid == store.prefs.resolvedActiveProbeUUID {
                                Text("Live")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                            } else {
                                Button("Use for live") { store.selectProbe(probe.uuid) }
                            }
                        }
                        Button("Forget probe", role: .destructive) {
                            store.forgetProbe(probe.uuid)
                        }
                    }
                    HStack {
                        Button("Add BlueDOT…") { store.startProbePairing() }
                        Button("Reconnect all") { store.reconnect() }
                    }
                } header: {
                    Text("Probes")
                }
                Section("Target (ETA)") {
                    Toggle("Track target temperature", isOn: $store.prefs.targetEnabled)
                    Toggle("Alarm at target", isOn: $store.prefs.targetAlarmEnabled)
                    HStack {
                        Text("Target")
                        TextField("°F", value: $store.prefs.targetTempF, format: .number.precision(.fractionLength(0)))
                        Text("°F (stored)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Alerts") {
                    Toggle("Enable temperature alerts", isOn: $store.prefs.alertEnabled)
                    HStack {
                        Text("High °F")
                        TextField("High", value: $store.prefs.alertHighF, format: .number)
                    }
                    HStack {
                        Text("Low °F")
                        TextField("Low", value: $store.prefs.alertLowF, format: .number)
                    }
                }
                Section {
                    Text("Mac banners require Notifications enabled for BlueDOT Manager in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Test Mac + iPhone notifications") { store.testNotifications() }
                } header: {
                    Text("System notifications")
                }
                Section {
                    Toggle("Push to iPhone (ntfy)", isOn: $store.prefs.ntfyEnabled)
                    TextField("ntfy topic", text: $store.prefs.ntfyTopic)
                        .textFieldStyle(.roundedBorder)
                    TextField("Server (optional)", text: $store.prefs.ntfyServer)
                        .textFieldStyle(.roundedBorder)
                    Text("Install the free ntfy app on iPhone, subscribe to the same topic (use a private random name).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("iPhone alerts")
                } footer: {
                    Text("Apple does not sync custom Mac app alerts to iPhone automatically; ntfy delivers a real push.")
                }
                Section("Display") {
                    Toggle("Use Celsius", isOn: $store.prefs.useCelsius)
                    Toggle("Menu bar thermometer", isOn: $store.prefs.menuBarEnabled)
                }
                Section {
                    LabeledContent("Installed version", value: updater.currentVersion)
                    Toggle("Check for updates on launch", isOn: $store.prefs.autoCheckUpdates)
                    Text(updater.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(updater.isChecking ? "Checking…" : "Check for updates") {
                            Task { await updater.checkForUpdates() }
                        }
                        .disabled(updater.isChecking || updater.isInstalling)
                        if updater.updateAvailable {
                            Button(updater.isInstalling ? "Installing…" : "Install update") {
                                Task { await updater.installUpdate() }
                            }
                            .disabled(updater.isInstalling)
                        }
                        Button("GitHub releases") {
                            NSWorkspace.shared.open(AppUpdateConstants.releasesURL)
                        }
                    }
                } header: {
                    Text("Updates")
                }
                Button("Save settings") { store.saveAll() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.mint)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding()
        }
        .navigationTitle("Settings")
    }
}

private struct TargetAlarmOverlay: View {
    @EnvironmentObject var store: BluetoothStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.ember)
                .symbolEffect(.bounce, options: .repeating)
            Text("Target temperature reached")
                .font(.title2.weight(.bold))
            if let t = store.displayValue {
                Text(String(format: "%.0f%@", t, store.unitSymbol))
                    .font(.system(size: 44, weight: .light, design: .rounded))
            }
            HStack(spacing: 12) {
                Button("Dismiss alarm") { store.dismissTargetAlarm() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ember)
                    .keyboardShortcut(.defaultAction)
                Button("Snooze 5 min") { store.snoozeTargetAlarm(minutes: 5) }
                    .buttonStyle(.bordered)
            }
            Text("Esc · ⌘D · menu bar ⌘D")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
        .padding(32)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.ember.opacity(0.5), lineWidth: 2))
        .shadow(color: Theme.ember.opacity(0.35), radius: 24)
    }
}

private struct RootView: View {
    @EnvironmentObject var store: BluetoothStore
    @State private var tab: SidebarTab? = .live

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, selection: $tab) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationTitle("BlueDOT")
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch tab ?? .live {
                case .live: LiveScreen()
                case .history: HistoryScreen()
                case .publicLink: PublicScreen()
                case .settings: SettingsScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.ink)
        .overlay {
            if store.targetAlarmRinging {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    TargetAlarmOverlay()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.targetAlarmRinging)
        .onExitCommand { if store.targetAlarmRinging { store.dismissTargetAlarm() } }
        .sheet(isPresented: Binding(
            get: { store.probePairingPresented },
            set: { if !$0 { store.cancelProbePairing() } else { store.probePairingPresented = true } }
        )) {
            ProbePairingSheet()
                .environmentObject(store)
        }
    }
}

// MARK: - App entry

@main
struct BlueDOTManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = BluetoothStore()
    @StateObject private var updater = UpdateController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(updater)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.bind(store: store)
                    if !appDelegate.didStart {
                        store.start()
                        updater.checkOnLaunchIfEnabled(autoCheck: store.prefs.autoCheckUpdates)
                        appDelegate.didStart = true
                    }
                }
        }
        .defaultSize(width: 960, height: 640)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Check for Updates…") {
                    Task { await updater.checkForUpdates() }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(updater.isChecking || updater.isInstalling)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var didStart = false

    func bind(store: BluetoothStore) {
        MenuBarController.shared.attach(store: store)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
