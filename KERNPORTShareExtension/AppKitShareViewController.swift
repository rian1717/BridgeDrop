import AppKit
import KERNPORTCore
import UniformTypeIdentifiers

/// Native AppKit surface for Finder's Share menu.
///
/// The view is built synchronously in `loadView`, so Finder receives a usable
/// remote view immediately. File-provider and network work starts afterwards.
@objc(AppKitShareViewController)
@MainActor
final class AppKitShareViewController: NSViewController {
    private let engine = KERNPORTEngine(
        deviceName: Host.current().localizedName ?? "KERNPORT Mac",
        receiveDirectory: FileManager.default.temporaryDirectory)

    private let summaryLabel = NSTextField(labelWithString: "Preparing selected files…")
    private let statusLabel = NSTextField(labelWithString: "Searching for Android devices…")
    private let spinner = NSProgressIndicator()
    private let progress = NSProgressIndicator()
    private let devicesStack = NSStackView()

    private var urls: [URL] = []
    private var devices: [String: KERNPORTDevice] = [:]
    private var selectedDeviceID: String?
    private var progressPoller: Task<Void, Never>?

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 400, height: 460))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active

        let title = NSTextField(labelWithString: "KERNPORT")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "arrow.left.arrow.right.circle.fill",
            accessibilityDescription: "KERNPORT") ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.symbolConfiguration = .init(pointSize: 22, weight: .medium)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelShare))
        cancel.bezelStyle = .inline

        let header = NSStackView(views: [icon, title, NSView(), cancel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.maximumNumberOfLines = 2

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.usesThreadedAnimation = true
        progress.isHidden = true

        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 8
        devicesStack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)

        let loading = NSStackView(views: [spinner, statusLabel])
        loading.orientation = .vertical
        loading.alignment = .centerX
        loading.spacing = 12

        let content = NSStackView(views: [header, summaryLabel, NSBox.separator(), loading, progress, devicesStack])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        summaryLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        loading.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        progress.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        devicesStack.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        devicesStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        view = root
        preferredContentSize = NSSize(width: 400, height: 460)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        wireEngine()
        loadSelectedURLs()
        engine.startDiscovery()
    }

    override func viewWillDisappear() {
        progressPoller?.cancel()
        progressPoller = nil
        if let selectedDeviceID {
            engine.cancelTransfer(id: selectedDeviceID)
        }
        engine.stopDiscovery()
        super.viewWillDisappear()
    }

    private func wireEngine() {
        engine.onDeviceFound = { [weak self] device in
            self?.add(device)
        }
        engine.onDeviceLost = { [weak self] id in
            self?.removeDevice(id: id)
        }
        engine.onOutgoingEvent = { [weak self] _, event in
            guard let self else { return }
            switch event {
            case .connected(let pin):
                self.setStatus("Confirm PIN \(pin) on both devices")
            case .accepted:
                self.spinner.stopAnimation(nil)
                self.spinner.isHidden = true
                self.progress.isHidden = false
                self.setStatus("Sending…")
            case .progress(let fraction):
                self.progress.doubleValue = fraction
                self.setStatus("Sending… \(Int(fraction * 100))%")
            case .finished:
                self.progress.doubleValue = 1
                self.setStatus("Sent")
                self.finish(after: .milliseconds(600))
            case .failed(let error):
                self.setStatus(error.userMessage)
                self.restoreDeviceButtons()
            }
        }
    }

    private func loadSelectedURLs() {
        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            .map(ShareProvider.init)

        guard !providers.isEmpty else {
            summaryLabel.stringValue = "No files were provided"
            return
        }

        Task {
            let loaded = await withTaskGroup(of: URL?.self) { group in
                for provider in providers {
                    group.addTask { await Self.loadURL(from: provider) }
                }
                var values: [URL] = []
                for await url in group {
                    if let url { values.append(url) }
                }
                return values
            }
            urls = loaded
            if loaded.isEmpty {
                summaryLabel.stringValue = "Finder could not provide the selected file"
            } else if loaded.count == 1 {
                summaryLabel.stringValue = loaded[0].lastPathComponent
            } else {
                summaryLabel.stringValue = "\(loaded.count) selected files"
            }
        }
    }

    private nonisolated static func loadURL(from box: ShareProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            let result = ShareURLResult(continuation)
            box.provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? NSURL else {
                    result.resume(nil)
                    return
                }
                result.resume(url as URL)
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                result.resume(nil)
            }
        }
    }

    private func add(_ device: KERNPORTDevice) {
        guard devices[device.id] == nil else { return }
        devices[device.id] = device

        let button = NSButton(
            title: device.name,
            target: self,
            action: #selector(selectDevice(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(device.id)
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.image = NSImage(
            systemSymbolName: symbol(for: device.type),
            accessibilityDescription: device.name)
        devicesStack.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: devicesStack.widthAnchor).isActive = true

        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.stringValue = "Choose a nearby device"
    }

    private func removeDevice(id: String) {
        devices[id] = nil
        guard let button = devicesStack.arrangedSubviews.compactMap({ $0 as? NSButton })
            .first(where: { $0.identifier?.rawValue == id }) else { return }
        devicesStack.removeArrangedSubview(button)
        button.removeFromSuperview()

        if devices.isEmpty {
            spinner.isHidden = false
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Open Quick Share on your Android device"
        }
    }

    @objc private func selectDevice(_ sender: NSButton) {
        guard !urls.isEmpty,
              let id = sender.identifier?.rawValue,
              let device = devices[id] else {
            setStatus("The selected file is not ready yet")
            return
        }

        selectedDeviceID = id
        devicesStack.arrangedSubviews.forEach { ($0 as? NSControl)?.isEnabled = false }
        spinner.isHidden = false
        spinner.startAnimation(nil)
        setStatus("Connecting to \(device.name)…")
        engine.stopDiscovery()
        sendThroughMainApp(files: urls, device: device)
    }

    private func sendThroughMainApp(files: [URL], device: KERNPORTDevice) {
        let paths = files.map(\.path)

        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "app.kernport.mac").isEmpty else {
            performFinderSend(paths: paths, deviceName: device.name)
            return
        }

        var appURL = Bundle.main.bundleURL
        appURL.deleteLastPathComponent()
        appURL.deleteLastPathComponent()
        appURL.deleteLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    self.setStatus(error.localizedDescription)
                    self.restoreDeviceButtons()
                } else {
                    self.performFinderSend(paths: paths, deviceName: device.name)
                }
            }
        }
    }

    private func performFinderSend(paths: [String], deviceName: String) {
        guard let url = URL(string: "http://127.0.0.1:47821/finder-send") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(
            "kernport-finder-4A5E7C91-5F0B-4D38-AE7A-8F0D81B9A234",
            forHTTPHeaderField: "X-KERNPORT-Finder")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["paths": paths, "deviceName": deviceName])
        } catch {
            setStatus(error.localizedDescription)
            restoreDeviceButtons()
            return
        }

        setStatus("Connecting to \(deviceName)…")
        spinner.isHidden = false
        spinner.startAnimation(nil)
        progress.isHidden = false
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        progressPoller?.cancel()
        progressPoller = Task { await pollProgress(deviceName: deviceName) }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                progressPoller?.cancel()
                progressPoller = nil
                let result = try JSONDecoder().decode(FinderSendResponse.self, from: data)
                if result.ok {
                    spinner.stopAnimation(nil)
                    spinner.isHidden = true
                    progress.stopAnimation(nil)
                    progress.isIndeterminate = false
                    progress.doubleValue = 1
                    setStatus("Sent")
                    finish(after: .milliseconds(600))
                } else {
                    setStatus(result.error ?? "Couldn’t send")
                    restoreDeviceButtons()
                    engine.startDiscovery()
                }
            } catch {
                progressPoller?.cancel()
                progressPoller = nil
                setStatus(error.localizedDescription)
                restoreDeviceButtons()
                engine.startDiscovery()
            }
        }
    }

    private func pollProgress(deviceName: String) async {
        guard let url = URL(string: "http://127.0.0.1:47821/finder-progress") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue(
            "kernport-finder-4A5E7C91-5F0B-4D38-AE7A-8F0D81B9A234",
            forHTTPHeaderField: "X-KERNPORT-Finder")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["deviceName": deviceName])

        while !Task.isCancelled {
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let state = try? JSONDecoder().decode(FinderProgressResponse.self, from: data),
               !Task.isCancelled {
                show(state, deviceName: deviceName)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func show(_ state: FinderProgressResponse, deviceName: String) {
        switch state.state {
        case "awaitingConsent":
            setStatus("Waiting for \(deviceName) to accept… PIN \(state.pin ?? "")")
        case "sending":
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            let fraction = state.fraction ?? 0
            if progress.isIndeterminate {
                progress.stopAnimation(nil)
                progress.isIndeterminate = false
            }
            progress.doubleValue = fraction
            let total = state.totalBytes ?? 0
            if total > 0 {
                let sent = ByteCountFormatter.string(
                    fromByteCount: Int64(Double(total) * fraction), countStyle: .file)
                let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                setStatus("Sending… \(Int(fraction * 100))% · \(sent) of \(size)")
            } else {
                setStatus("Sending… \(Int(fraction * 100))%")
            }
        default:
            break
        }
    }

    private func restoreDeviceButtons() {
        selectedDeviceID = nil
        progressPoller?.cancel()
        progressPoller = nil
        progress.stopAnimation(nil)
        progress.isIndeterminate = false
        progress.doubleValue = 0
        progress.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        devicesStack.arrangedSubviews.forEach { ($0 as? NSControl)?.isEnabled = true }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func finish(after delay: Duration) {
        Task {
            try? await Task.sleep(for: delay)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    @objc private func cancelShare() {
        if let selectedDeviceID {
            engine.cancelTransfer(id: selectedDeviceID)
        }
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func symbol(for type: KERNPORTDevice.DeviceType) -> String {
        switch type {
        case .phone: "iphone.gen3"
        case .tablet: "ipad"
        case .computer: "laptopcomputer"
        case .unknown: "questionmark.circle"
        }
    }
}

private struct FinderSendResponse: Decodable, Sendable {
    let ok: Bool
    let error: String?
}

private struct FinderProgressResponse: Decodable, Sendable {
    let state: String
    let pin: String?
    let fraction: Double?
    let totalBytes: Int64?
}

private final class ShareProvider: @unchecked Sendable {
    let provider: NSItemProvider
    init(_ provider: NSItemProvider) { self.provider = provider }
}

private final class ShareURLResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL?, Never>?

    init(_ continuation: CheckedContinuation<URL?, Never>) {
        self.continuation = continuation
    }

    func resume(_ url: URL?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: url)
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
