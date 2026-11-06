import SwiftUI
import AppKit

enum AppMode: String, CaseIterable, Identifiable {
    case send = "Send"
    case receive = "Receive"
    var id: String { rawValue }
    var symbol: String { self == .send ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
}

/// State of the send flow.
///
/// Quick Share has no "connect, then later choose files" step — the handshake
/// happens when files are offered. The `qr*` states cover reaching a device
/// that isn't in the discovery list: stage files, show a QR, and when a device
/// scans it the transfer starts automatically.
enum ConnectionState: Equatable {
    case idle
    case staging(RemoteDevice)                       // device picked, choosing files
    case connecting(RemoteDevice)                    // offer sent, handshaking
    case awaitingConsent(RemoteDevice, pin: String)  // PIN shown, waiting for remote

    case qrStaging                                   // QR mode, choosing files (no device yet)
    case qrShowing(payload: String)                  // QR displayed, waiting for a scan

    var device: RemoteDevice? {
        switch self {
        case .staging(let d), .connecting(let d), .awaitingConsent(let d, _): return d
        default: return nil
        }
    }
}

/// Single source of truth for the app. Views observe it; it consumes engine
/// callbacks and updates its state.
///
/// `@Observable`, not `ObservableObject`: every screen observes this model, and
/// `ObservableObject` would invalidate all of them on any change — including on
/// each transfer-progress tick. View-graph re-evaluation is expensive in this
/// window (see `SearchingSymbol`), so per-property read tracking matters.
@MainActor
@Observable
final class AppModel {

    // Global
    var mode: AppMode = .send
    /// Drives the ⌘⌥I build-info sheet; set from the menu command.
    var showingBuildInfo = false
    var deviceName: String = AppModel.defaultDeviceName()

    // Receive side
    //
    // Two facts, not one: `wantsVisible` is the user's intent and flips
    // instantly; `isVisible` is what the engine achieved and drives the status.
    private(set) var wantsVisible: Bool = false
    private(set) var isVisible: Bool = false
    /// Set when advertising was requested but never came up.
    private(set) var visibilityFailed: Bool = false

    /// What to show the user about advertising.
    enum VisibilityStatus: Equatable {
        case off
        case starting
        case on
        case stopping
        case failed
    }

    var visibilityStatus: VisibilityStatus {
        if visibilityFailed { return .failed }
        switch (wantsVisible, isVisible) {
        case (true, true):   return .on
        case (true, false):  return .starting
        case (false, true):  return .stopping
        case (false, false): return .off
        }
    }
    var incomingRequest: IncomingRequest? = nil
    /// Bumped on every incoming request. `openWindow` is a View-only action,
    /// so `MenuBarView` watches this to reopen a closed window.
    private(set) var incomingActivityToken = UUID()

    // Send side
    var discoveredDevices: [RemoteDevice] = []
    var connection: ConnectionState = .idle
    var stagedFiles: [FileItem] = []

    // Both
    var transfers: [ActiveTransfer] = []

    /// Recently transferred files, newest first, for the File menu.
    var recentFiles: [RecentFile] = []
    private static let maxRecentFiles = 10

    /// Names seen before. This is only a familiarity hint: Quick Share exposes
    /// no verifiable persistent identity here, so names never grant trust.
    var knownDevices: [KnownDevice] = []

    // Settings (persisted)
    var downloadDirectory: URL = AppModel.defaultDownloadDirectory()
    var startVisible: Bool = false
    var appearance: AppAppearance = .system
    /// Live system appearance. "System" resolves to a concrete scheme because
    /// `.preferredColorScheme(nil)` does not reliably reset a window that was
    /// previously forced to Light or Dark.
    private var systemIsDark: Bool = AppModel.currentSystemIsDark()
    /// Held outside actor isolation: `deinit` is nonisolated and cannot read
    /// main-actor state.
    private let appearanceObserver = ObserverBox()

    var effectiveColorScheme: ColorScheme {
        switch appearance {
        case .system: return systemIsDark ? .dark : .light
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    private nonisolated static func currentSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
    /// Localhost control API for the `kernport` CLI. Off by default: it can read
    /// any path the user can and push it to a nearby device, so it's opt-in.
    var controlAPIEnabled: Bool = false

    /// Phone → Mac clipboard. Off until paired: it lets a phone write ⌘V.
    private(set) var clipboardEnabled: Bool = false
    private(set) var clipboardPairCode: String = ""
    private(set) var clipboardPairingLink: String = ""
    private(set) var clipboardStatus: String = "Off"
    /// True while a phone copy is arriving. Drives the pasting ring.
    private(set) var clipboardPasting = false
    private var pasteStarted: Date?
    private var pasteHide: DispatchWorkItem?
    private var clipboardToken: String = ""
    private var clipboardServer: ClipboardServer?

    var clipboardPairCodeSpaced: String {
        guard clipboardPairCode.count == 8 else { return clipboardPairCode }
        let split = clipboardPairCode.index(clipboardPairCode.startIndex, offsetBy: 4)
        return "\(clipboardPairCode[..<split]) \(clipboardPairCode[split...])"
    }

    // Control API state; the endpoints themselves are in AppModel+CLI.
    var controlServer: ControlServer?
    struct CliSendResult { let ok: Bool; let pin: String?; let error: String? }
    var cliPending: [String: (CliSendResult) -> Void] = [:]
    var cliPins: [String: String] = [:]

    let service: BridgeDropService
    private let prefs = Preferences()

    init(service: BridgeDropService? = nil) {
        let usesRealDefaultService = service == nil
            && ProcessInfo.processInfo.environment["KERNPORT_MOCK"] == nil
        // Defaults to the real engine. Set KERNPORT_MOCK=1 for the simulated engine.
        if let service {
            self.service = service
        } else if ProcessInfo.processInfo.environment["KERNPORT_MOCK"] != nil {
            self.service = MockBridgeDropService()
        } else {
            self.service = NearbyBridgeDropService()
        }
        if let saved = prefs.downloadDirectory { self.downloadDirectory = saved }
        self.startVisible = prefs.startVisible
        self.controlAPIEnabled = prefs.controlAPIEnabled
        self.clipboardEnabled = prefs.clipboardEnabled
        self.appearance = prefs.appearance
        self.knownDevices = prefs.loadKnownDevices()
        self.pairedPhoneNames = prefs.loadPairedPhones()
        self.removedPhoneNames = prefs.loadRemovedPhones()
        self.recentFiles = prefs.loadRecentFiles()
        self.service.delegate = self
        self.service.setReceiveDirectory(downloadDirectory)
        if startVisible {
            setVisible(true)
        }
        // Discover continuously so the menu-bar list is always current.
        self.service.startDiscovery()
        // The listener also carries Finder share-extension requests. Normal
        // control API routes remain gated by `controlAPIEnabled`.
        if usesRealDefaultService || controlAPIEnabled { startControlServer() }
        if usesRealDefaultService && clipboardEnabled { startClipboardServer() }
        if usesRealDefaultService { startCompanionBrowser() }

        appearanceObserver.set(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemIsDark = AppModel.currentSystemIsDark() }
        })
        if ProcessInfo.processInfo.environment["KERNPORT_MOCK"] != nil {
            deviceName = "MacBook Pro"   // neutral name for demo screenshots
            transfers = DemoData.transfers()
        }
    }

    deinit {
        // `deinit` is nonisolated, so it cannot touch main-actor state. The
        // token is captured into a nonisolated box when the observer is
        // registered, precisely so teardown needs nothing from the actor.
        if let token = appearanceObserver.take() {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    // MARK: Settings

    func setDownloadDirectory(_ url: URL) {
        downloadDirectory = url
        prefs.downloadDirectory = url
        service.setReceiveDirectory(url)
    }

    func setStartVisible(_ on: Bool) {
        setVisible(on)
    }

    func setControlAPIEnabled(_ on: Bool) {
        controlAPIEnabled = on
        prefs.controlAPIEnabled = on
        if on {
            startControlServer()
        } else {
            // Any CLI request still parked on a completion would otherwise hang.
            failAllPendingCli(error: "control_api_disabled")
        }
    }

    func startControlServer() {
        guard controlServer == nil else { return }
        let server = ControlServer(model: self)
        controlServer = server
        server.start()
    }

    func setClipboardEnabled(_ on: Bool) {
        clipboardEnabled = on
        prefs.clipboardEnabled = on
        if on {
            startClipboardServer()
        } else {
            clipboardServer?.stop()
            clipboardServer = nil
            clipboardStatus = "Off"
            clipboardPairingLink = ""
        }
    }

    func startClipboardServer() {
        clipboardToken = prefs.clipboardToken()
        clipboardPairCode = prefs.clipboardPairCode()
        refreshClipboardLink()
        guard clipboardServer == nil else { return }
        let server = ClipboardServer(token: clipboardToken, pairCode: clipboardPairCode, deviceName: deviceName)
        server.onIncoming = { [weak self] in
            self?.beginPasteIndicator()
        }
        server.onFailed = { [weak self] in
            self?.cancelPasteIndicator()
        }
        server.onApplied = { [weak self] summary in
            self?.finishPasteIndicator(summary)
        }
        server.onPairedPhone = { [weak self] name in
            self?.acceptPairedPhone(name)
        }
        server.approveUncodedPair = { name, decision in
            let shown = String(name.replacingOccurrences(of: "\n", with: " ").prefix(60))
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Allow \(shown) to paste here?"
                alert.informativeText = "This phone is on your Wi-Fi and did not use the 8-digit code. Allowing it lets that phone replace what you paste with Command-V. You can remove it later."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Don’t Allow")
                NSApp.activate(ignoringOtherApps: true)
                decision(alert.runModal() == .alertFirstButtonReturn)
            }
        }
        server.onUnpairedPhone = { [weak self] name in
            self?.forgetPhone(name)
        }
        server.phoneIsRemoved = { [weak self] name in
            self?.isPhoneRemoved(name) ?? false
        }
        server.onListening = { [weak self] listening in
            guard let self, self.clipboardStatus == "Off" || self.clipboardStatus == "Starting…" else { return }
            self.clipboardStatus = listening ? "Waiting for a copy" : "Couldn’t listen on this network"
        }
        clipboardServer = server
        clipboardStatus = "Starting…"
        server.start()
    }

    private func beginPasteIndicator() {
        pasteHide?.cancel()
        pasteStarted = Date()
        clipboardPasting = true
        PasteHUD.shared.show(phase: .pasting)
    }

    private func finishPasteIndicator(_ summary: String) {
        clipboardStatus = summary
        let elapsed = Date().timeIntervalSince(pasteStarted ?? Date())
        let wait = max(0, 0.45 - elapsed)
        let hide = DispatchWorkItem { [weak self] in
            PasteHUD.shared.show(phase: .done)
            let dismiss = DispatchWorkItem { [weak self] in
                self?.clipboardPasting = false
                PasteHUD.shared.hide()
            }
            self?.pasteHide = dismiss
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: dismiss)
        }
        pasteHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: hide)
    }

    private func cancelPasteIndicator() {
        pasteHide?.cancel()
        clipboardPasting = false
        PasteHUD.shared.hide()
    }

    func refreshClipboardLink() {
        guard clipboardEnabled, !clipboardToken.isEmpty else {
            clipboardPairingLink = ""
            return
        }
        var link = URLComponents()
        link.scheme = "kernport"
        link.host = "clip"
        var items = [
            URLQueryItem(name: "port", value: String(ClipboardServer.port)),
            URLQueryItem(name: "code", value: clipboardPairCode),
            URLQueryItem(name: "name", value: deviceName),
        ]
        if let ip = LANAddress.preferredIPv4() {
            items.insert(URLQueryItem(name: "host", value: ip), at: 0)
        }
        link.queryItems = items
        clipboardPairingLink = link.string ?? ""
    }

    func setAppearance(_ a: AppAppearance) {
        appearance = a
        prefs.appearance = a
    }

    private static func defaultDownloadDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    /// Menu-bar glyph reflecting the current state.
    var menuBarSymbol: String {
        if incomingRequest != nil { return "arrow.down.circle.fill" }
        if transfers.contains(where: { $0.phase == .transferring }) { return "arrow.up.arrow.down.circle.fill" }
        return isVisible ? "arrow.2.circlepath.circle.fill" : "arrow.2.circlepath"
    }

    // MARK: Recent files

    /// Records the files of a completed transfer, newest first.
    func recordRecentFiles(from transfer: ActiveTransfer) {
        let incoming = transfer.direction == .incoming
        let entries = transfer.files.compactMap { file -> RecentFile? in
            guard let url = file.url else { return nil }
            return RecentFile(name: file.name, path: url.path,
                              receivedAt: Date(), wasIncoming: incoming)
        }
        guard !entries.isEmpty else { return }

        // Re-transferring a file should move it up, not duplicate it.
        let newPaths = Set(entries.map(\.path))
        recentFiles.removeAll { newPaths.contains($0.path) }
        recentFiles.insert(contentsOf: entries, at: 0)
        if recentFiles.count > Self.maxRecentFiles {
            recentFiles = Array(recentFiles.prefix(Self.maxRecentFiles))
        }
        persistRecentFiles()
    }

    func clearRecentFiles() {
        recentFiles.removeAll()
        persistRecentFiles()
    }

    private func persistRecentFiles() { prefs.save(recentFiles: recentFiles) }

    func openRecentFile(_ file: RecentFile) {
        guard file.stillExists else {
            // Gone from disk — drop it rather than bouncing the Dock icon.
            recentFiles.removeAll { $0.path == file.path }
            persistRecentFiles()
            return
        }
        NSWorkspace.shared.open(file.url)
    }

    func openDownloadsFolder() {
        NSWorkspace.shared.open(downloadDirectory)
    }

    // MARK: Known devices

    func isKnown(_ name: String) -> Bool {
        knownDevices.contains { $0.name == name }
    }

    /// Native Quick Share names are self-reported, so automatic acceptance is
    /// intentionally unavailable.
    func autoAccepts(_ name: String) -> Bool {
        false
    }

    /// Records a sender as familiar. `autoAccept` remains in the signature for
    /// stored-data/source compatibility but is deliberately ignored.
    func remember(_ name: String, autoAccept: Bool = false) {
        if !knownDevices.contains(where: { $0.name == name }) {
            knownDevices.append(KnownDevice(name: name, autoAccept: false))
            knownDevices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        persistKnown()
    }

    func setAutoAccept(_ enabled: Bool, for name: String) {
        // Retained as a no-op while old preferences and clients migrate.
    }

    func forget(_ name: String) {
        knownDevices.removeAll { $0.name == name }
        persistKnown()
    }

    private func persistKnown() { prefs.save(knownDevices: knownDevices) }

    /// Phones that paired with this Mac. Remembered across launches, and shown
    /// under My devices instead of Nearby devices.
    private(set) var pairedPhoneNames: [String] = []
    /// Phones the user removed. A later copy must not put them back; only
    /// pairing again does.
    private(set) var removedPhoneNames: [String] = []
    private var companionBrowser: CompanionBrowser?

    func rememberPhone(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPhoneRemoved(trimmed),
              !pairedPhoneNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        pairedPhoneNames.append(trimmed)
        pairedPhoneNames.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        prefs.save(pairedPhones: pairedPhoneNames)
    }

    /// The phone paired on purpose. This is the only way back onto My devices
    /// after the user removed it.
    func acceptPairedPhone(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isPhoneRemoved(trimmed) {
            removedPhoneNames.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            prefs.save(removedPhones: removedPhoneNames)
        }
        rememberPhone(trimmed)
    }

    /// Takes a phone off My devices. It can still appear under Nearby while it
    /// is on the network, and copies from it stop until it pairs again.
    func forgetPhone(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pairedPhoneNames.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        prefs.save(pairedPhones: pairedPhoneNames)
        if !isPhoneRemoved(trimmed) {
            removedPhoneNames.append(trimmed)
            removedPhoneNames.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            prefs.save(removedPhones: removedPhoneNames)
        }
        knownDevices.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        persistKnown()
    }

    func isPhoneRemoved(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return removedPhoneNames.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Paired phones that are on the network right now. A KERNPORT phone wins
    /// over a Quick Share advertisement of the same name.
    var myDevices: [RemoteDevice] {
        var rows: [RemoteDevice] = []
        var seen = Set<String>()
        let companions = discoveredDevices.filter(\.isCompanion)
        let pairedQuickShare = discoveredDevices.filter { device in
            !device.isCompanion && isPairedPhone(device.name)
        }
        for device in companions + pairedQuickShare {
            let key = device.name.lowercased()
            if seen.insert(key).inserted { rows.append(device) }
        }
        return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Everyone else currently visible. Paired phones are not listed here.
    var nearbyDevices: [RemoteDevice] {
        let mine = Set(myDevices.map { $0.name.lowercased() })
        return discoveredDevices
            .filter { !$0.isCompanion && !mine.contains($0.name.lowercased()) }
            .sorted {
                isKnown($0.name) == isKnown($1.name) ? $0.name < $1.name : isKnown($0.name)
            }
    }

    /// Paired phones whose screens are off, so they are not advertising.
    var offlinePhoneNames: [String] {
        pairedPhoneNames.filter { name in
            !discoveredDevices.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    private func isPairedPhone(_ name: String) -> Bool {
        pairedPhoneNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func startCompanionBrowser() {
        let browser = CompanionBrowser()
        browser.onFound = { [weak self] device in
            self?.rememberPhone(device.name)
            self?.serviceDidDiscover(device)
        }
        browser.onLost = { [weak self] id in
            self?.serviceDidLose(deviceID: id)
        }
        browser.start()
        companionBrowser = browser
    }


    // MARK: Intents — Receive

    func toggleVisibility() {
        setVisible(!wantsVisible)
    }

    /// Records the intent immediately, then asks the engine. The choice sticks
    /// across launches, so Receive does not turn itself off.
    func setVisible(_ on: Bool) {
        wantsVisible = on
        visibilityFailed = false
        startVisible = on
        prefs.startVisible = on
        if on {
            service.startAdvertising(deviceName: deviceName)
            scheduleVisibilityTimeout()
        } else {
            visibilityToken += 1
            service.stopAdvertising()
        }
    }

    private var visibilityToken = 0
    /// Stops a visibility drop from restarting advertising forever in one call.
    private var restartingVisibility = false

    /// If advertising has not come up yet, try again. Leave the switch on.
    private func scheduleVisibilityTimeout() {
        visibilityToken += 1
        let token = visibilityToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, token == self.visibilityToken,
                  self.wantsVisible, !self.isVisible else { return }
            self.visibilityFailed = true
            self.restartAdvertising()
            self.scheduleVisibilityTimeout()
        }
    }

    private func restartAdvertising() {
        guard wantsVisible, !restartingVisibility else { return }
        restartingVisibility = true
        service.stopAdvertising()
        service.startAdvertising(deviceName: deviceName)
        restartingVisibility = false
    }

    /// Answers the pending request. Every transfer requires explicit consent.
    func respondToIncoming(accept: Bool, alwaysAccept: Bool = false) {
        guard let req = incomingRequest else { return }
        if accept {
            remember(req.device.name)
            acceptIncoming(req)
        } else {
            service.respondToIncoming(id: req.id, accept: false)
        }
        incomingRequest = nil
    }

    /// Accept a request and create its transfer row.
    func acceptIncoming(_ req: IncomingRequest) {
        service.respondToIncoming(id: req.id, accept: true)
        transfers.insert(
            ActiveTransfer(id: req.id, direction: .incoming, deviceName: req.device.name,
                           title: req.summary, totalBytes: req.totalBytes, phase: .transferring,
                           files: req.fileNames.map { TransferFile(name: $0) }),
            at: 0)
    }

    // MARK: Intents — Send

    // Discovery is deliberately always on — it starts in `init` and runs until
    // quit, so the menu-bar device list is current whenever it's opened. There
    // are no start/stop intents because nothing should be turning it off.

    /// Pick a listed device to send to. Opens the file staging UI.
    func selectDevice(_ device: RemoteDevice) {
        connection = .staging(device)
    }

    func cancelSend() {
        if let device = connection.device {
            service.cancelTransfer(id: device.id)
        }
        if case .qrShowing = connection { service.cancelQRCode() }
        if case .qrStaging = connection { service.cancelQRCode() }
        connection = .idle
        stagedFiles = []
    }

    func stage(urls: [URL]) {
        let items = urls.compactMap { url -> FileItem? in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
            let size = Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
            return FileItem(url: url, sizeBytes: size)
        }
        for item in items where !stagedFiles.contains(where: { $0.url == item.url }) {
            stagedFiles.append(item)
        }
        // QR mode has nothing else to decide: the code appears as soon as a file lands.
        if case .qrStaging = connection { showQRCode() }
    }

    func removeStaged(_ item: FileItem) {
        stagedFiles.removeAll { $0.id == item.id }
    }

    /// Begin the handshake + file offer to a listed device.
    func sendStagedFiles() {
        guard case .staging(let device) = connection, !stagedFiles.isEmpty else { return }
        if device.isCompanion {
            sendToCompanion(device)
            return
        }
        connection = .connecting(device)
        service.sendFiles(stagedFiles, to: device)
        scheduleConnectTimeout(for: device)
    }

    /// A paired phone receives through the KERNPORT app, not Quick Share.
    private func sendToCompanion(_ device: RemoteDevice) {
        guard let host = device.companionHost, let port = device.companionPort else { return }
        let files = stagedFiles
        let title = files.count == 1 ? files[0].name : "\(files.count) files"
        let total = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let id = "phone-\(UUID().uuidString.prefix(6))"
        connection = .idle
        stagedFiles = []
        transfers.insert(
            ActiveTransfer(id: id, direction: .outgoing, deviceName: device.name,
                           title: title, totalBytes: total, phase: .transferring,
                           files: files.map { TransferFile(name: $0.name, url: $0.url) }),
            at: 0)
        let token = clipboardToken
        CompanionSender.send(files: files, host: host, port: port, token: token) { [weak self] fraction in
            Task { @MainActor in self?.serviceDidUpdateProgress(id: id, fraction: fraction) }
        } done: { [weak self] error in
            Task { @MainActor in self?.serviceDidFinishTransfer(id: id, error: error) }
        }
    }

    /// One token per device — a shared counter meant a second send silently
    /// invalidated the first one's timeout, leaving it to hang forever.
    private var connectTokens: [String: Int] = [:]

    /// If the handshake doesn't produce a PIN within a few seconds, the connect
    /// failed (device moved on / unreachable). Don't hang — fail cleanly.
    func scheduleConnectTimeout(for device: RemoteDevice) {
        let token = (connectTokens[device.id] ?? 0) + 1
        connectTokens[device.id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, token == self.connectTokens[device.id],
                  case .connecting(let d) = self.connection, d.id == device.id else { return }
            self.connectTokens[device.id] = nil
            self.service.cancelTransfer(id: device.id)
            self.connection = .idle
            self.stagedFiles = []
            self.transfers.insert(
                ActiveTransfer(id: "fail-\(UUID().uuidString.prefix(6))", direction: .outgoing,
                               deviceName: device.name, title: "Couldn’t connect",
                               totalBytes: 0, phase: .failed("No response — try again")),
                at: 0)
            self.finishCli(device.id, ok: false, error: "timeout")
        }
    }

    // MARK: Intents — QR send

    /// Enter QR mode from the discovery list (device not shown → offer a QR).
    func startQRSend() {
        connection = .qrStaging
    }

    /// Show the QR for the files already staged. Called as soon as a file is dropped.
    func showQRCode() {
        guard case .qrStaging = connection, !stagedFiles.isEmpty,
              let payload = service.prepareQRCode() else { return }
        connection = .qrShowing(payload: payload)
    }

    // MARK: Intents — Both

    func cancel(_ transfer: ActiveTransfer) {
        service.cancelTransfer(id: transfer.id)
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.phase.isTerminal }
    }

    // MARK: Helpers

    private static func defaultDeviceName() -> String {
        Host.current().localizedName ?? "Mac"
    }
}

// MARK: - Engine callbacks

extension AppModel: BridgeDropServiceDelegate {

    func serviceDidUpdateVisibility(isVisible: Bool) {
        self.isVisible = isVisible
        if isVisible {
            // It came up — cancel the pending failure check.
            //
            // Intent is deliberately NOT touched here. Setting it would let a
            // late "visible" arriving during teardown flip the switch back on
            // after the user has just turned it off.
            visibilityToken += 1
            visibilityFailed = false
        } else if wantsVisible {
            // Dropped out from under us. Come back without asking the user
            // to open KERNPORT and switch to Receive again.
            restartAdvertising()
            scheduleVisibilityTimeout()
        }
    }

    func serviceDidReceiveIncomingRequest(_ request: IncomingRequest) {
        // `NSApp` is an implicitly-unwrapped global that is nil outside a running
        // GUI app. This path is driven by network input, so don't force it.
        if let app = NSApp { app.activate(ignoringOtherApps: true) }
        // Reopens the main window if it was closed — `NSApp.activate` alone
        // only reorders existing windows, it can't bring back a closed one.
        incomingActivityToken = UUID()

        incomingRequest = request   // surface the prompt
    }

    func serviceDidDiscover(_ device: RemoteDevice) {
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index].name = device.name
            return
        }
        discoveredDevices.append(device)
    }

    func serviceDidLose(deviceID: String) {
        discoveredDevices.removeAll { $0.id == deviceID }
    }

    func serviceDidMatchQRDevice(_ device: RemoteDevice) {
        // A device scanned our QR. If we're waiting with files staged, send them.
        guard case .qrShowing = connection, !stagedFiles.isEmpty else { return }
        connection = .connecting(device)
        service.sendFiles(stagedFiles, to: device)
        scheduleConnectTimeout(for: device)
    }

    func serviceDidEstablishConnection(with device: RemoteDevice, pin: String) {
        connection = .awaitingConsent(device, pin: pin)
        if cliPending[device.id] != nil { cliPins[device.id] = pin }
    }

    func serviceDidFailConnection(with device: RemoteDevice, error: String) {
        connectTokens[device.id] = nil
        if connection.device?.id == device.id {
            connection = .idle
            stagedFiles = []
        }
        if !transfers.contains(where: { $0.id == device.id }) {
            transfers.insert(
                ActiveTransfer(id: device.id, direction: .outgoing, deviceName: device.name,
                               title: "Couldn’t connect", totalBytes: 0, phase: .failed(error)),
                at: 0)
        }
        finishCli(device.id, ok: false, error: error)
    }

    func serviceDidAcceptTransfer(id: String) {
        if let i = transfers.firstIndex(where: { $0.id == id && !$0.phase.isTerminal }) {
            transfers[i].phase = .transferring
        } else {
            let device = connection.device
            let title = stagedFiles.count == 1 ? stagedFiles.first?.name ?? "1 file"
                                               : "\(stagedFiles.count) files"
            let total = stagedFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let files = stagedFiles.map { TransferFile(name: $0.name, url: $0.url) }
            transfers.removeAll { $0.id == id && $0.phase.isTerminal }
            transfers.insert(
                ActiveTransfer(id: id, direction: .outgoing, deviceName: device?.name ?? "Device",
                               title: title, totalBytes: total, phase: .transferring, files: files),
                at: 0)
            stagedFiles = []
            connection = .idle
        }
    }

    func serviceDidUpdateProgress(id: String, fraction: Double) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[i].fraction = fraction
        if transfers[i].phase != .transferring { transfers[i].phase = .transferring }
    }

    func serviceDidFinishTransfer(id: String, error: String?) {
        if let i = transfers.firstIndex(where: { $0.id == id && !$0.phase.isTerminal }) {
            transfers[i].phase = error.map { .failed($0) } ?? .completed
            if error == nil {
                transfers[i].fraction = 1.0
                recordRecentFiles(from: transfers[i])
            }
        }
        if connection.device?.id == id { connection = .idle; stagedFiles = [] }
        finishCli(id, ok: error == nil, error: error)
    }

    func serviceDidResolveFiles(id: String, files: [TransferFile]) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[i].files = files
    }
}


/// A lock-protected slot for a notification-observer token, so `deinit` can
/// release it without touching actor-isolated state.
private final class ObserverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    func set(_ newToken: NSObjectProtocol?) {
        lock.lock(); defer { lock.unlock() }
        token = newToken
    }

    func take() -> NSObjectProtocol? {
        lock.lock(); defer { lock.unlock() }
        let existing = token
        token = nil
        return existing
    }
}
