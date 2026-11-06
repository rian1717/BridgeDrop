import Darwin
import Foundation
import Network

/// LAN address of this Mac, for the pairing QR. Bonjour is the durable
/// discovery path; the address just lets the first scan connect immediately.
enum LANAddress {
    static func preferredIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = cursor {
            defer { cursor = iface.pointee.ifa_next }
            let flags = Int32(iface.pointee.ifa_flags)
            let usable = (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0
            guard usable, let address = iface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = Self.cstring(host)
            let name = Self.cstring(iface.pointee.ifa_name)
            if name == "en0" { return ip }
            if name.hasPrefix("en"), fallback == nil { fallback = ip }
        }
        return fallback
    }

    private static func cstring(_ bytes: UnsafePointer<CChar>) -> String {
        var copy: [CChar] = []
        var index = 0
        while bytes[index] != 0 {
            copy.append(bytes[index])
            index += 1
        }
        return String(decoding: copy.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func cstring(_ bytes: [CChar]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Receives clipboard snapshots from a paired Android companion and puts them
/// on the Mac pasteboard. Bound to the LAN, not the internet: peers must be
/// on a private address and must present the pairing token.
@MainActor
final class ClipboardServer {
    nonisolated static let port: UInt16 = 47822
    private static let requestTimeout: TimeInterval = 120
    private static let maxRequestBytes = ClipboardDecode.maxBytes + 64 * 1024

    private let token: String
    private let pairCode: String
    private let deviceName: String
    private var listener: NWListener?
    private var pendingConnections: Set<ObjectIdentifier> = []
    private var pairAttempts: [Date] = []
    var onApplied: ((String) -> Void)?
    var onListening: ((Bool) -> Void)?
    /// The phone told us its name while pairing.
    var onPairedPhone: ((String) -> Void)?
    /// A phone on the Wi-Fi asked to pair without the 8-digit code.
    /// Call the closure with false to refuse. The token is not sent until this allows it.
    var approveUncodedPair: ((String, @escaping (Bool) -> Void) -> Void)?
    /// The phone asked to be removed from My devices.
    var onUnpairedPhone: ((String) -> Void)?
    /// A phone the user removed. Its copies are refused until it pairs again.
    var phoneIsRemoved: (String) -> Bool = { _ in false }
    /// Fires once, as soon as a copy starts arriving, before the pasteboard changes.
    var onIncoming: (() -> Void)?
    var onFailed: (() -> Void)?
    private var announcedIncoming: Set<ObjectIdentifier> = []

    init(token: String, pairCode: String, deviceName: String) {
        self.token = token
        self.pairCode = pairCode
        self.deviceName = deviceName
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Wi-Fi and Ethernet only. Peer-to-peer would accept a nearby device
        // that is not on this network.
        params.includePeerToPeer = false
        guard let port = NWEndpoint.Port(rawValue: Self.port),
              let listener = try? NWListener(using: params, on: port) else {
            NSLog("KERNPORT clipboard: could not bind port \(Self.port)")
            onListening?(false)
            return
        }
        self.listener = listener
        listener.service = NWListener.Service(
            name: String(deviceName.prefix(63)),
            type: "_kernport._tcp")
        listener.newConnectionHandler = { [weak self] (connection: NWConnection) in
            guard let self else { connection.cancel(); return }
            guard Self.isPrivateLAN(connection.endpoint) else {
                connection.cancel()
                return
            }
            connection.start(queue: .main)
            MainActor.assumeIsolated {
                self.armIdleTimeout(connection)
                self.receive(connection, buffer: Data())
            }
        }
        listener.stateUpdateHandler = { [weak self] (state: NWListener.State) in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.onListening?(true)
                case .failed: self?.onListening?(false)
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Accept loopback and private LAN peers. A public address is never a phone
    /// on this network, so it cannot write the pasteboard.
    nonisolated static func isPrivateLAN(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return isPrivateIPv4(address)
        case .ipv6(let address): return isPrivateIPv6(address)
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    nonisolated static func isPrivateIPv4(_ address: IPv4Address) -> Bool {
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 4 else { return false }
        switch bytes[0] {
        case 10, 127: return true
        case 192: return bytes[1] == 168
        case 169: return bytes[1] == 254
        case 172: return (16...31).contains(bytes[1])
        default: return false
        }
    }

    nonisolated static func isPrivateIPv6(_ address: IPv6Address) -> Bool {
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 16 else { return false }
        if bytes == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] { return true }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
        if (bytes[0] & 0xfe) == 0xfc { return true }
        return false
    }

    private func armIdleTimeout(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        pendingConnections.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            guard let self, self.pendingConnections.contains(id) else { return }
            self.pendingConnections.remove(id)
            connection.cancel()
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var next = buffer
                if let data { next.append(data) }
                self.noteIncomingIfNeeded(next, connection)
                if Self.declaredLength(next) > ClipboardDecode.maxBytes || next.count > Self.maxRequestBytes {
                    self.pendingConnections.remove(ObjectIdentifier(connection))
                    self.respond(connection, Self.http(413, ["ok": false, "error": "too_large"]))
                    return
                }
                if let request = HTTPRequest(next) {
                    self.pendingConnections.remove(ObjectIdentifier(connection))
                    self.route(request) { response in
                        self.respond(connection, response)
                    }
                } else if done || error != nil {
                    self.pendingConnections.remove(ObjectIdentifier(connection))
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: next)
                }
            }
        }
    }

    private func route(_ request: HTTPRequest, respond: @escaping (Data) -> Void) {
        switch (request.method, request.path) {
        case ("POST", "/clip/pair"):
            guard allowPairAttempt() else {
                respond(Self.http(429, ["ok": false, "error": "slow_down"])); return
            }
            let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let code = body["code"] as? String
            let phone = (body["device"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A typed code has to match. A phone that only sends its name must be
            // approved on the Mac before it receives the token.
            if let code, !code.isEmpty {
                guard ControlServer.constantTimeEqual(code, pairCode) else {
                    respond(Self.http(401, ["ok": false, "error": "bad_code"])); return
                }
                finishPair(phone, respond)
            } else if let phone, !phone.isEmpty {
                guard let approve = approveUncodedPair else {
                    respond(Self.http(401, ["ok": false, "error": "denied"])); return
                }
                approve(phone) { allowed in
                    Task { @MainActor in
                        if allowed {
                            self.finishPair(phone, respond)
                        } else {
                            respond(Self.http(401, ["ok": false, "error": "denied"]))
                        }
                    }
                }
            } else {
                respond(Self.http(401, ["ok": false, "error": "bad_code"]))
            }
        case ("POST", "/clip/unpair"):
            guard authorized(request) else {
                respond(Self.http(401, ["ok": false, "error": "unauthorized"])); return
            }
            let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let phone = (body["device"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let phone, !phone.isEmpty {
                onUnpairedPhone?(phone)
            }
            respond(Self.http(200, ["ok": true]))
        case ("POST", "/clip/status"):
            guard authorized(request) else {
                respond(Self.http(401, ["ok": false, "error": "unauthorized"])); return
            }
            let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let phone = (body["device"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let phone, !phone.isEmpty, phoneIsRemoved(phone) {
                respond(Self.http(401, ["ok": false, "error": "removed"]))
                return
            }
            respond(Self.http(200, ["ok": true, "name": deviceName]))
        case ("GET", "/clip/health"):
            guard authorized(request) else {
                respond(Self.http(401, ["ok": false, "error": "unauthorized"])); return
            }
            respond(Self.http(200, ["ok": true, "name": deviceName]))
        case ("POST", "/clip"):
            guard authorized(request) else {
                respond(Self.http(401, ["ok": false, "error": "unauthorized"])); return
            }
            do {
                if let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                   let phone = (obj["source"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !phone.isEmpty, phoneIsRemoved(phone) {
                    respond(Self.http(401, ["ok": false, "error": "removed"]))
                    return
                }
                let payload = try ClipboardDecode.parse(headers: request.headers, body: request.body)
                let summary = try ClipboardPasteboard.apply(payload)
                onApplied?(summary)
                respond(Self.http(200, ["ok": true]))
            } catch ClipboardDecodeError.tooLarge {
                self.onFailed?()
                respond(Self.http(413, ["ok": false, "error": "too_large"]))
            } catch {
                self.onFailed?()
                respond(Self.http(400, ["ok": false, "error": "bad_clipboard"]))
            }
        default:
            respond(Self.http(404, ["ok": false, "error": "not_found"]))
        }
    }

    private func finishPair(_ phone: String?, _ respond: (Data) -> Void) {
        if let phone, !phone.isEmpty {
            onPairedPhone?(phone)
        }
        respond(Self.http(200, ["ok": true, "token": token, "name": deviceName]))
    }

    private func authorized(_ request: HTTPRequest) -> Bool {
        let header = request.headers["authorization"] ?? ""
        guard header.hasPrefix("Bearer ") else { return false }
        return ControlServer.constantTimeEqual(String(header.dropFirst(7)), token)
    }

    private func allowPairAttempt() -> Bool {
        let now = Date()
        pairAttempts.removeAll { now.timeIntervalSince($0) > 60 }
        guard pairAttempts.count < 8 else { return false }
        pairAttempts.append(now)
        return true
    }

    /// The ring should appear while the bytes are still arriving, not after ⌘V already works.
    private func noteIncomingIfNeeded(_ buffer: Data, _ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard !announcedIncoming.contains(id),
              let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: buffer.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8)
        else { return }
        let requestLine = header.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        guard requestLine.hasPrefix("POST /clip ") else { return }
        announcedIncoming.insert(id)
        onIncoming?()
    }

    private func respond(_ connection: NWConnection, _ bytes: Data) {
        announcedIncoming.remove(ObjectIdentifier(connection))
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func declaredLength(_ buffer: Data) -> Int {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: buffer.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) else {
            return 0
        }
        for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        }
        return 0
    }

    private static func http(_ status: Int, _ object: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
