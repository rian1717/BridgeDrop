import Foundation
import Network

/// Length-prefixed framing over a TCP connection: a 4-byte big-endian length
/// followed by that many bytes.
///
/// Wraps `NWConnection`'s callback API in async/await so the session state
/// machines read as straight-line code instead of nested completion handlers.
/// One actor owns the socket, so there is no shared mutable state to race.
public actor FrameChannel {

    /// Largest frame we will accept or send. Frames are protocol control
    /// messages and payload chunks, all far below this.
    public static let maxFrameLength = 5 * 1024 * 1024

    private let connection: NWConnection
    private var isClosed = false
    /// Set when the peer half-closes or the socket errors; surfaced to whoever
    /// reads next.
    private var terminalError: KERNPORTError?

    public init(connection: NWConnection) {
        self.connection = connection
    }

    /// Brings the connection up, resuming once it is ready or has failed.
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // NWConnection can report .ready or .failed more than once across a
            // lifetime; only the first transition may resume the continuation.
            let resumed = OneShot()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case .failed(let error):
                    if resumed.claim() {
                        continuation.resume(throwing: KERNPORTError.localFailure(
                            "connection failed: \(error.localizedDescription)"))
                    }
                case .cancelled:
                    if resumed.claim() {
                        continuation.resume(throwing: KERNPORTError.connectionLost)
                    }
                default:
                    break
                }
            }
            connection.start(queue: Self.queue)
        }
    }

    private static let queue = DispatchQueue(label: "com.kernport.frame-channel", qos: .userInitiated)

    // MARK: Receiving

    /// Reads the next frame. Throws `.connectionLost` at end of stream.
    public func receiveFrame() async throws -> Data {
        if let terminalError { throw terminalError }
        let header = try await receiveExactly(4)
        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        // Bound the allocation before asking for the body.
        guard length > 0, length <= Self.maxFrameLength else {
            throw KERNPORTError.protocolViolation("frame length out of range (\(length))")
        }
        return try await receiveExactly(length)
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        var accumulated = Data()
        accumulated.reserveCapacity(count)
        while accumulated.count < count {
            let chunk = try await receiveSome(min: 1, max: count - accumulated.count)
            accumulated.append(chunk)
        }
        return accumulated
    }

    private func receiveSome(min: Int, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let resumed = OneShot()
            connection.receive(minimumIncompleteLength: min, maximumLength: max) { data, _, isComplete, error in
                guard resumed.claim() else { return }
                if let error {
                    continuation.resume(throwing: KERNPORTError.localFailure(
                        "receive failed: \(error.localizedDescription)"))
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                // No data and complete means the peer closed.
                if isComplete {
                    continuation.resume(throwing: KERNPORTError.connectionLost)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    // MARK: Sending

    public func send(frame: Data) async throws {
        guard frame.count <= Self.maxFrameLength else {
            throw KERNPORTError.internalFailure("outgoing frame too large")
        }
        let length = UInt32(frame.count)
        var out = Data(capacity: frame.count + 4)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(frame)
        try await sendRaw(out)
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OneShot()
            connection.send(content: data, completion: .contentProcessed { error in
                guard resumed.claim() else { return }
                if let error {
                    continuation.resume(throwing: KERNPORTError.localFailure(
                        "send failed: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: Teardown

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
    }
}

/// Guards a continuation against being resumed more than once.
///
/// Network.framework can invoke a handler again after a state change, and
/// resuming a continuation twice is undefined behaviour, so every callback path
/// claims this first.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
