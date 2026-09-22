import Foundation
import Network

/// Serves the Mac's routing state to remotes and applies their commands.
///
/// Advertised over Bonjour so a phone finds it without anyone typing an IP
/// address, but discovery is not authorisation: the pairing code gates the TLS
/// handshake, so being able to see the service is not the same as being able to
/// use it.
@MainActor
public final class RemoteServer {
    /// Called for each command a paired remote sends.
    public var onCommand: ((RemoteCommand) -> Void)?
    /// Called when the number of connected remotes changes.
    public var onClientsChanged: ((Int) -> Void)?

    public private(set) var isRunning = false
    public private(set) var connectedClients = 0
    public private(set) var pairingCode: String = ""

    private var listener: NWListener?
    private var links: [ObjectIdentifier: RemoteLink] = [:]
    private let queue = DispatchQueue(label: "com.audiosplit.remote-server")
    private var lastSnapshot: RemoteSnapshot?

    public init() {}

    /// A short, human-typeable code. Ambiguous characters are excluded so
    /// nobody has to guess between O and 0 while reading it off a screen.
    public static func generatePairingCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0 ..< 6).map { _ in alphabet.randomElement()! })
    }

    /// `serviceName` is what remotes see in their list of Macs. Passed in
    /// rather than read here: `Host` is macOS-only, and this file has to compile
    /// for iOS even though it only ever runs on the Mac.
    public func start(
        pairingCode: String,
        serviceName: String,
        port: UInt16 = RemoteService.defaultPort
    ) throws {
        stop()
        self.pairingCode = pairingCode

        let parameters = remoteParameters(pairingCode: pairingCode)
        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: port) ?? .any
        )
        listener.service = NWListener.Service(
            name: serviceName,
            type: RemoteService.bonjourType
        )

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let link = RemoteLink(connection: connection, queue: self.queue)
            link.onMessage = { [weak self] message in
                guard case let .command(command) = message else { return }
                Task { @MainActor in self?.onCommand?(command) }
            }
            link.onStateChange = { [weak self] connected in
                Task { @MainActor in
                    guard let self else { return }
                    let key = ObjectIdentifier(link)
                    if connected {
                        self.links[key] = link
                        // A remote that has just connected needs the current
                        // picture immediately, not at the next state change.
                        if let snapshot = self.lastSnapshot {
                            link.send(.snapshot(snapshot))
                        }
                    } else {
                        self.links[key] = nil
                    }
                    self.connectedClients = self.links.count
                    self.onClientsChanged?(self.connectedClients)
                }
            }
            link.start()
        }

        listener.start(queue: queue)
        self.listener = listener
        isRunning = true
    }

    public func stop() {
        for link in links.values { link.cancel() }
        links.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        connectedClients = 0
    }

    /// Push the current state to every paired remote.
    public func broadcast(_ snapshot: RemoteSnapshot) {
        lastSnapshot = snapshot
        guard !links.isEmpty else { return }
        for link in links.values { link.send(.snapshot(snapshot)) }
    }
}
