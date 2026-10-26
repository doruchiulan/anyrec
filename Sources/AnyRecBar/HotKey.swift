import Carbon.HIToolbox

/// ⌘⇧R, from anywhere: the panel's "Record a window". Registered with Carbon because it is
/// the one public API for a key that works while another app is in front and needs no
/// Accessibility grant.
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var current: HotKey?

    init(action: @escaping () -> Void) {
        self.action = action
        HotKey.current = self

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.current?.action() } }
                return noErr
            }, 1, &spec, nil, &handler)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey),
            EventHotKeyID(signature: OSType(0x414E5952), id: 1),
            GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }
}
