import AudioSplitShared
import Foundation

/// Routes on disk, as JSON in Application Support.
///
/// Only declarative state is persisted: bundle IDs, device UIDs, volume, mute.
/// Never PIDs, process object IDs, aggregate IDs or tap UIDs — those are all
/// runtime identities that change on every launch, and writing them down would
/// mean restoring routes that point at nothing.
public struct RouteDocument: Codable, Sendable {
    /// Bumped when the shape changes in a way older builds cannot read.
    public static let currentVersion = 1

    public var version: Int
    public var routes: [Route]
    public var preferences: Preferences

    public init(
        version: Int = RouteDocument.currentVersion,
        routes: [Route],
        preferences: Preferences = Preferences()
    ) {
        self.version = version
        self.routes = routes
        self.preferences = preferences
    }

    // Files written before preferences existed decode with defaults rather than
    // failing and costing the user their routes.
    private enum CodingKeys: String, CodingKey {
        case version, routes, preferences
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? RouteDocument.currentVersion
        routes = try container.decodeIfPresent([Route].self, forKey: .routes) ?? []
        preferences = try container.decodeIfPresent(Preferences.self, forKey: .preferences)
            ?? Preferences()
    }
}

/// Loads and saves the route list.
public struct Store: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")

        return base
            .appendingPathComponent("AudioSplit", isDirectory: true)
            .appendingPathComponent("routes.json", isDirectory: false)
    }

    /// Read the saved routes. A missing file is not an error — it is a first run.
    ///
    /// A file we cannot parse is moved aside rather than deleted. Losing a
    /// user's routes silently is worse than starting empty with the evidence
    /// still on disk.
    public func load() throws -> RouteDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return RouteDocument(routes: [])
        }

        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode(RouteDocument.self, from: data)
        } catch {
            let quarantine = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            throw StoreError.unreadable(movedTo: quarantine, underlying: error)
        }
    }

    /// Write the routes, replacing the file atomically so a crash mid-write
    /// cannot leave a half-written list behind.
    public func save(_ routes: [Route], preferences: Preferences = Preferences()) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            RouteDocument(routes: routes, preferences: preferences)
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public enum StoreError: Error, CustomStringConvertible {
        case unreadable(movedTo: URL, underlying: any Error)

        public var description: String {
            switch self {
            case let .unreadable(url, underlying):
                "Could not read saved routes (\(underlying)). "
                    + "The file was moved to \(url.lastPathComponent) and AudioSplit started empty."
            }
        }
    }
}
