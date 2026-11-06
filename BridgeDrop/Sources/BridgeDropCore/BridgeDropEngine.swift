import Foundation
import Network

/// The whole protocol, behind one object.
///
/// Everything above this line — the app — deals in devices, offers and
/// progress. Sockets, protobufs and key schedules stay below it.
@MainActor
public final class BridgeDropEngine {

    // MARK: Callbacks

    /// Advertising actually started or stopped (not merely requested).
    public var onVisibilityChange: (@MainActor (Bool) -> Void)?
    public var onDeviceFound: (@MainActor (BridgeDropDevice) -> Void)?
    public var onDeviceLost: (@MainActor (String) -> Void)?
    /// A peer is offering files. Answer with `respondToOffer(id:accept:)`.
    public var onOfferReceived: (@MainActor (IncomingOffer) -> Void)?
    public var onIncomingProgress: (@MainActor (String, Double) -> Void)?
    public var onIncomingFinished: (@MainActor (String, [URL], BridgeDropError?) -> Void)?
    public var onOutgoingEvent: (@MainActor (String, OutboundEvent) -> Void)?
    /// A device scanned our QR code and is now reachable.
    public var onQRDeviceMatched: (@MainActor (BridgeDropDevice) -> Void)?

    // MARK: State

    public private(set) var deviceName: String
    public var receiveDirectory: URL

    private let advertiser: ServiceAdvertiser
    private let browser: ServiceBrowser
    private let endpointID: [UInt8]

    private var inboundSessions: [String: InboundSession] = [:]
    private var outboundSessions: [String: OutboundSession] = [:]

    public init(deviceName: String, receiveDirectory: URL) {
        self.deviceName = deviceName
        self.receiveDirectory = receiveDirectory
        self.endpointID = Self.makeEndpointID()
        self.advertiser = ServiceAdvertiser(deviceName: deviceName, endpointID: endpointID)
        self.browser = ServiceBrowser()

        advertiser.onVisibilityChange = { [weak self] visible in
            self?.onVisibilityChange?(visible)
        }
        advertiser.onConnection = { [weak self] connection, id in
            self?.acceptInbound(connection: connection, id: id)
        }
        browser.onFound = { [weak self] device, _ in self?.onDeviceFound?(device) }
        browser.onLost = { [weak self] id in self?.onDeviceLost?(id) }
        browser.onQRMatch = { [weak self] device in self?.onQRDeviceMatched?(device) }
    }

    // MARK: QR send

    /// Starts a QR offer and returns the link to display. Discovery must be
    /// running for the scanning device to be spotted.
    public func beginQRSession() -> String {
        let session = QRCodeSession()
        browser.qrSession = session
        return session.url
    }

    public func endQRSession() {
        browser.qrSession = nil
    }

    /// Four random alphanumerics, as the protocol expects.
    private static func makeEndpointID() -> [UInt8] {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        var rng = SystemRandomNumberGenerator()
        return (0..<4).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
    }

    // MARK: Receiving

    public func startAdvertising() { advertiser.start() }
    public func stopAdvertising() { advertiser.stop() }

    public func setDeviceName(_ name: String) {
        deviceName = name
        advertiser.updateDeviceName(name)
    }

    public func respondToOffer(id: String, accept: Bool) {
        guard let session = inboundSessions[id] else { return }
        Task { await session.respond(accept: accept) }
    }

    private func acceptInbound(connection: NWConnection, id: String) {
        let session = InboundSession(connection: connection, id: id,
                                     receiveDirectory: receiveDirectory)
        inboundSessions[id] = session

        Task { [weak self] in
            let stream = await session.events()
            for await event in stream {
                guard let self else { return }
                switch event {
                case .offerReceived(let offer):
                    self.onOfferReceived?(offer)
                case .progress(let fraction):
                    self.onIncomingProgress?(id, fraction)
                case .finished(let urls):
                    self.onIncomingFinished?(id, urls, nil)
                case .failed(let error):
                    self.onIncomingFinished?(id, [], error)
                }
            }
            self?.inboundSessions.removeValue(forKey: id)
        }
    }

    // MARK: Sending

    public func startDiscovery() { browser.start() }

    /// The phone's own name, read from its Bluetooth announcement.
    public func noteBluetoothName(endpointID: String, name: String) {
        browser.noteBluetoothName(endpointID: endpointID, name: name)
    }
    public func stopDiscovery() { browser.stop() }

    /// Connects to `device` and offers `files`. The transfer id is returned so
    /// the caller can correlate events and cancel.
    ///
    /// The id is the device id, which means one in-flight transfer per device.
    /// That invariant is enforced below rather than assumed: without the guard a
    /// second send would overwrite the first session in the map, so cancelling
    /// would reach the wrong one and the first would leak. Supporting genuinely
    /// concurrent transfers to a single device would mean giving each its own id
    /// and threading that through the app's transfer rows.
    @discardableResult
    public func send(files: [OutgoingFile], to device: BridgeDropDevice) -> String {
        let transferID = device.id
        guard outboundSessions[transferID] == nil else {
            onOutgoingEvent?(transferID,
                             .failed(.localFailure("already sending to \(device.name)")))
            return transferID
        }
        let parameters = NWParameters.tcp
        // Stay on Wi-Fi. A cached address, or the peer-to-peer interface, is
        // what timed out once both phones were visible: the port had moved,
        // or the route was not the network the phone is actually on.
        parameters.includePeerToPeer = false
        parameters.requiredInterfaceType = .wifi
        let connection: NWConnection
        if let endpoint = browser.wifiEndpoint(for: device.id) {
            connection = NWConnection(to: endpoint, using: parameters)
        } else if let address = browser.address(for: device.id),
                  QuickShareAddress.sharesSubnet(address.host),
                  let ip = IPv4Address(address.host),
                  let port = NWEndpoint.Port(rawValue: address.port) {
            connection = NWConnection(host: .ipv4(ip), port: port, using: parameters)
        } else {
            onOutgoingEvent?(transferID, .failed(.localFailure("device is no longer reachable")))
            return transferID
        }
        let localEndpointID = String(decoding: endpointID, as: UTF8.self)
        let session = OutboundSession(connection: connection, id: transferID, files: files,
                                      localName: deviceName, localEndpointID: localEndpointID)
        outboundSessions[transferID] = session

        Task { [weak self] in
            let stream = await session.events()
            for await event in stream {
                self?.onOutgoingEvent?(transferID, event)
            }
            self?.outboundSessions.removeValue(forKey: transferID)
        }
        return transferID
    }

    public func cancelTransfer(id: String) {
        if let outbound = outboundSessions[id] {
            Task { await outbound.cancel() }
        }
        if let inbound = inboundSessions[id] {
            Task { await inbound.cancel() }
        }
    }
}
