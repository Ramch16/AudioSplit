import AudioSplitEngine
import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey.
///
/// Uses Carbon's `RegisterEventHotKey`, which is the only way to get a global
/// shortcut without asking for Accessibility access. An `NSEvent` global monitor
/// would work too, but it requires the user to grant input monitoring — a much
/// bigger ask than this feature is worth, and one that would put AudioSplit in
/// the same privacy category as a keylogger.
@MainActor
final class HotKeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?

    /// Carbon dispatches to a C callback with no context of its own, so the
    /// active monitor is reachable through this.
    private static weak var active: HotKeyMonitor?

    private static let signature = OSType(0x4153_504C) // 'ASPL'

    deinit {
        MainActor.assumeIsolated { unregister() }
    }

    /// Register `binding`, replacing whatever was registered before.
    /// Returns false if the combination is already taken by something else.
    @discardableResult
    func register(_ binding: HotKeyBinding, action: @escaping () -> Void) -> Bool {
        unregister()
        guard binding.isEnabled else { return true }

        self.action = action
        Self.active = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var identifier = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard identifier.signature == HotKeyMonitor.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon calls back on the main thread.
                MainActor.assumeIsolated { HotKeyMonitor.active?.action?() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard handlerStatus == noErr else { return false }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        action = nil
    }
}
