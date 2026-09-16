import Foundation
import os

/// A menu bar app has no console, so route-level events go to unified logging
/// and, when launched with `open --stdout`, to standard error as well.
///
/// Control path only. Nothing here may be called from an IOProc.
enum Diagnostics {
    private static let logger = Logger(subsystem: "com.audiosplit.AudioSplit", category: "routing")

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("[audiosplit] \(message)\n".utf8))
    }
}
