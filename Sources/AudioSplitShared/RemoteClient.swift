import Foundation
import Network

/// Finds Macs running AudioSplit and talks to one of them.
///
/// The remote holds no routing logic of its own. It renders whatever snapshot
/// the Mac sends and forwards intent back — which is the only arrangement iOS
/// permits, since nothing on the phone can see another app's audio.
@MainActor
public final class RemoteClient {
    public struct DiscoveredMac: Identifiable, Hashable, Sendable {
        public let name: String
        let endpoint: NWEndpoint
        public var id: String { name }
    }

    public enum ConnectionState: Equatable, Sendable {
        case idle
        case searching
        case connecting
        case connected
        /// Almost always a wrong pairing code: a PSK mismatch surfaces as a
        /// handshake failure, not as a rejection we can read.
        case failed(String)
    }

    public private(set) var discovered: [DiscoveredMac] = []
    public private(set) var state: ConnectionState = .idle
    public private(set) var snapshot: RemoteSnapshot?

    public var onChange: (() -> Void)?

    private var browser: NWBrowser?
    private var link: RemoteLink?
    private let queue = DispatchQueue(label: "com.audiosplit.remote-client")

    public init() {}

    /// Browse for Macs advertising AudioSplit. Safe to call repeatedly.
    public func startDiscovery() {
        browser?.cancel()
        self.state = .searching
        self.onChange?()

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: RemoteService.bonjourType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                self.discovered = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return DiscoveredMac(name: name, endpoint: result.endpoint)
                }
                .sorted { $0.name < $1.name }
                self.onChange?()
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    public func connect(to mac: DiscoveredMac, pairingCode: String) {
        link?.cancel()
        self.state = .connecting
        self.onChange?()

        let connection = NWConnection(
            to: mac.endpoint,
            using: remoteParameters(pairingCode: pairingCode)
        )
        let link = RemoteLink(connection: connection, queue: queue)
        link.onMessage = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                switch message {
                case let .snapshot(snapshot):
                    guard snapshot.version == RemoteSnapshot.currentVersion else {
                        self.state = .failed(
                            "This Mac is running a different version of AudioSplit."
                        )
                        self.onChange?()
                        return
                    }
                    self.snapshot = snapshot
                    self.state = .connected
                case let .failure(reason):
                    self.state = .failed(reason)
                case .command:
                    // Commands only travel towards the Mac.
                    break
                }
                self.onChange?()
            }
        }
        link.onStateChange = { [weak self] connected in
            Task { @MainActor in
                guard let self else { return }
                if !connected, self.state != .connected {
                    self.state = .failed("Could not connect. Check the pairing code.")
                } else if !connected {
                    self.state = .failed("Lost connection to the Mac.")
                }
                self.onChange?()
            }
        }
        link.start()
        self.link = link
    }

    public func disconnect() {
        link?.cancel()
        link = nil
        snapshot = nil
        self.state = .idle
        self.onChange?()
    }

    public func send(_ command: RemoteCommand) {
        link?.send(.command(command))
    }
}
