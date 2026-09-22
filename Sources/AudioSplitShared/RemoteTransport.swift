import Foundation
import Network

// Transport shared by the Mac (which serves) and a phone or iPad (which
// remotes). Network.framework exists on both platforms, so one implementation
// serves both ends.
//
// Security matters more here than it would for a typical LAN toy: AudioSplit is
// deliberately not sandboxed, and it can mute and re-route every app on the
// machine. An open listener would be a remote control over someone's audio for
// anyone on the same coffee-shop Wi-Fi. So the connection is TLS with a
// pre-shared key derived from a pairing code shown on the Mac. Without the code
// the handshake fails outright — there is no unauthenticated path to reject
// later, and no plaintext on the wire.

/// Frames a JSON message with a 4-byte big-endian length prefix.
///
/// TCP is a stream, not a message queue: without framing, two snapshots sent
/// back to back arrive as one buffer and neither parses.
enum RemoteFraming {
    /// Refuses absurd lengths so a malformed or hostile peer cannot make us
    /// allocate arbitrarily.
    static let maximumFrameBytes = 4 * 1024 * 1024

    static func frame(_ message: RemoteMessage) throws -> Data {
        let payload = try message.encoded()
        guard payload.count <= maximumFrameBytes else {
            throw RemoteError.frameTooLarge(payload.count)
        }
        var header = UInt32(payload.count).bigEndian
        var data = Data(bytes: &header, count: 4)
        data.append(payload)
        return data
    }
}

public enum RemoteError: Error, CustomStringConvertible, Sendable {
    case frameTooLarge(Int)
    case connectionFailed(String)
    case notConnected

    public var description: String {
        switch self {
        case let .frameTooLarge(size): "Message too large to send (\(size) bytes)."
        case let .connectionFailed(reason): reason
        case .notConnected: "Not connected to a Mac running AudioSplit."
        }
    }
}

/// TLS parameters keyed by the pairing code. Both ends must build these the
/// same way or the handshake fails, which is the point.
func remoteParameters(pairingCode: String) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let secret = Data(pairingCode.trimmingCharacters(in: .whitespaces).uppercased().utf8)
    let identity = Data("audiosplit".utf8)

    secret.withUnsafeBytes { secretBytes in
        identity.withUnsafeBytes { identityBytes in
            sec_protocol_options_add_pre_shared_key(
                tls.securityProtocolOptions,
                DispatchData(bytes: secretBytes) as __DispatchData,
                DispatchData(bytes: identityBytes) as __DispatchData
            )
        }
    }
    sec_protocol_options_append_tls_ciphersuite(
        tls.securityProtocolOptions,
        tls_ciphersuite_t.AES_128_GCM_SHA256
    )

    let tcp = NWProtocolTCP.Options()
    // Level meters are useless if they arrive in bursts.
    tcp.noDelay = true

    return NWParameters(tls: tls, tcp: tcp)
}

/// One connection, with message framing on top.
public final class RemoteLink: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()

    public var onMessage: (@Sendable (RemoteMessage) -> Void)?
    public var onStateChange: (@Sendable (Bool) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStateChange?(true)
            case .cancelled, .failed:
                self?.onStateChange?(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    public func send(_ message: RemoteMessage) {
        guard let data = try? RemoteFraming.frame(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        connection.cancel()
    }

    /// Reads until at least one whole frame is available, then keeps going.
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let content, !content.isEmpty {
                buffer.append(content)
                drainFrames()
            }
            if isComplete || error != nil {
                onStateChange?(false)
                return
            }
            receive()
        }
    }

    private func drainFrames() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }
            guard length <= UInt32(RemoteFraming.maximumFrameBytes) else {
                // Unparseable stream; drop the peer rather than guess.
                connection.cancel()
                return
            }
            let total = 4 + Int(length)
            guard buffer.count >= total else { return }

            let payload = buffer.subdata(in: 4 ..< total)
            buffer.removeSubrange(0 ..< total)
            if let message = try? RemoteMessage.decode(payload) {
                onMessage?(message)
            }
        }
    }
}
