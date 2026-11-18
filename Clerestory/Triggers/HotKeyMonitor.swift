import AppKit
import Carbon
import OSLog

/// UX3 Hotkey single-click/double-click discrimination (pure logic, decoupled from AppKit for unit
/// testing): First press enters 'pending single-click'; double-click is confirmed if second press is
/// within the window (first press is canceled); second press outside the window is considered a new first
/// press. Timeout is confirmed by caller (HotKeyMonitor's delayed task) via `confirmPending()` to confirm
/// single-click.
struct DoublePressDiscriminator: Sendable, Equatable {
    /// Result of a single press determination.
    enum PressResult: Sendable, Equatable {
        /// First press: Wait for second press within the window (timing starts when the window is launched
        /// by the caller).
        case firstPressPending
        /// Second press within the window: Double-click is confirmed.
        case doublePress
    }

    /// Double-click recognition window (seconds). Approximately 0.3s — same order of magnitude as system
    /// double-click interval.
    let window: TimeInterval
    /// Whether a single click is pending (determined at the time of the delayed task expiration).
    private(set) var hasPending = false
    private var lastPressTime: TimeInterval?

    init(window: TimeInterval) {
        self.window = window
    }

    /// Record a single press (`time` is a monotonic clock, e.g., ProcessInfo.systemUptime).
    mutating func press(at time: TimeInterval) -> PressResult {
        if hasPending, let lastPressTime, time - lastPressTime <= window {
            hasPending = false
            self.lastPressTime = nil
            return .doublePress
        }
        hasPending = true
        lastPressTime = time
        return .firstPressPending
    }

    /// Confirm the single click via the delayed task; reset the pending state.
    mutating func confirmPending() {
        hasPending = false
        lastPressTime = nil
    }

    /// Discard the pending single click (called when disabled/re-registered, invalidating the semantics of
    /// unexpired delayed tasks).
    mutating func reset() {
        hasPending = false
        lastPressTime = nil
    }
}

/// Global hot key monitor (S7): toggles the shelf from any app.
/// UX3: Single click = toggle; double click (recognizing the second press within the window) = save
/// clipboard to shelf,
/// the core `DoublePressDiscriminator` is of pure type (see top of this file).
///
/// Backend choice (deviates deliberately from plan §2.3's "NSEvent first"):
/// - **Carbon `RegisterEventHotKey` — primary.** Needs no Accessibility
///   permission, the registration result is programmatically detectable
///   (`eventHotKeyExistsErr` on conflict), and the hot key is consumed by the
///   system so the foreground app never sees it.
/// - **`NSEvent` global monitor — best-effort fallback.** Registration always
///   "succeeds"; whether events actually arrive cannot be probed, and the
///   event cannot be consumed, so ⌘⇧Space would also reach the foreground
///   app. Used only when Carbon registration fails.
///
/// Registration state (`isActive` / `activeBackend` / `registrationError`) is
/// observable so the S8 settings page can surface conflicts.
@MainActor
@Observable
final class HotKeyMonitor {
    /// Event backend currently delivering the hot key.
    enum Backend: String, Sendable {
        case carbon, nsEvent
    }

    /// Whether a backend is actively listening.
    private(set) var isActive = false
    /// Backend in use while `isActive` is true.
    private(set) var activeBackend: Backend?
    /// Human-readable registration failure (e.g. shortcut conflict), for the
    /// settings page. Nil when Carbon registration succeeded or the monitor
    /// is disabled.
    private(set) var registrationError: String?

    private var shortcut: SettingsStore.HotKeyShortcut?
    /// Constructed only on first registration (`requireActionBox()`); closures need weak self references
    /// via instance
    /// method `handlePress` to arbitrate single/double clicks, which cannot be captured in `init` (self is
    /// not fully
    /// initialized), and the `@Observable` macro disallows lazy properties, so it is constructed on
    /// demand.
    private var actionBox: HotKeyActionBox?
    private var enabled = false
    private let hotKeyIdentifier: UInt32

    /// UX3: Single click action (toggle shelf).
    private let onPress: @MainActor @Sendable () -> Void
    /// UX3: Double click action (save clipboard to shelf).
    private let onDoublePress: @MainActor @Sendable () -> Void
    /// UX3: Double click recognition toggle (synchronize with `hotKeyDoublePressSavesClipboard`).
    /// When disabled, single click has zero delay and is immediate.
    private var doublePressEnabled = false
    private var discriminator: DoublePressDiscriminator
    /// Generation timestamp for delayed single click tasks: increments on each press/cancellation, used to
    /// identify whether
    /// an expired task has been replaced by an updated press (to avoid a confirmed double click followed
    /// by an additional single click).
    private var pressGeneration: UInt64 = 0

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handlerUserData: UnsafeMutableRawPointer?
    private var nsEventMonitor: Any?

    private let logger = Logger(subsystem: "com.nininunz.Clerestory", category: "HotKey")

    /// Four-character signature for our hot key IDs ('OYHK').
    private nonisolated static let hotKeySignature = OSType(0x4F59_484B)

    init(shortcut: SettingsStore.HotKeyShortcut? = .default,
         hotKeyIdentifier: UInt32 = 1,
         doublePressWindow: TimeInterval = 0.3,
         onPress: @escaping @MainActor @Sendable () -> Void,
         onDoublePress: @escaping @MainActor @Sendable () -> Void) {
        self.shortcut = shortcut
        self.hotKeyIdentifier = hotKeyIdentifier
        self.onPress = onPress
        self.onDoublePress = onDoublePress
        self.discriminator = DoublePressDiscriminator(window: doublePressWindow)
    }

    // MARK: - Lifecycle

    /// Enables/disables the monitor. No-op when the state doesn't change.
    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled {
            register()
        } else {
            unregister()
            registrationError = nil
        }
    }

    /// Hot-updates the shortcut; re-registers immediately when enabled.
    /// A nil shortcut (cleared in the S8 recorder) unregisters and stays
    /// inactive until a new shortcut is recorded.
    func updateShortcut(_ shortcut: SettingsStore.HotKeyShortcut?) {
        guard shortcut != self.shortcut else { return }
        self.shortcut = shortcut
        if enabled {
            register()
        }
    }

    /// UX3: Synchronized double click recognition toggle
    /// (`SettingsStore.hotKeyDoublePressSavesClipboard`).
    func setDoublePressEnabled(_ enabled: Bool) {
        guard enabled != doublePressEnabled else { return }
        doublePressEnabled = enabled
        // Cancel old delayed single clicks when the setting switches, to prevent the next key press from
        // triggering immediately after
        // the double click recognition is turned off, causing the shelf to toggle continuously.
        pressGeneration &+= 1
        discriminator.reset()
    }

    /// UX3: Unified entry point for presses (Carbon processor and NSEvent are both routed through
    /// `actionBox` here). When double click recognition is enabled, single clicks are delayed by one
    /// recognition window; when disabled, they are immediate.
    private func handlePress() {
        guard doublePressEnabled else {
            onPress()
            return
        }
        switch discriminator.press(at: ProcessInfo.processInfo.systemUptime) {
        case .doublePress:
            // Discarded delayed single click task (generation timestamp invalid), immediate double click.
            pressGeneration &+= 1
            onDoublePress()
        case .firstPressPending:
            pressGeneration &+= 1
            let generation = pressGeneration
            let window = discriminator.window
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(window * 1000)))
                guard let self, !Task.isCancelled else { return }
                // A second press already exists within the window (double click confirmed, generation
                // timestamp invalid) or the state is
                // reset → no single click is issued.
                guard self.discriminator.hasPending, self.pressGeneration == generation else { return }
                self.discriminator.confirmPending()
                self.onPress()
            }
        }
    }

    // MARK: - Registration

    /// Return shared action box (construct if not exists). Carbon processor holds it via `Unmanaged`
    /// passRetained/balanced-release;
    /// repeated registration reuses the same instance, with retain/release balanced incrementally.
    private func requireActionBox() -> HotKeyActionBox {
        if let actionBox { return actionBox }
        let box = HotKeyActionBox(identifier: hotKeyIdentifier) { [weak self] in
            self?.handlePress()
        }
        actionBox = box
        return box
    }

    private func register() {
        unregister()
        guard let shortcut else {
            // Cleared shortcut: no registration, but no error either — the
            // settings page shows "Not Set" instead of a conflict banner.
            registrationError = nil
            return
        }
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: hotKeyIdentifier)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode,
                                         Self.carbonModifiers(for: shortcut),
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else {
            logger.warning("RegisterEventHotKey failed with OSStatus \(status); falling back to NSEvent global monitor")
            registrationError = String(localized: "Hot key registration failed (OSStatus \(status)); another app may already hold this shortcut.")
            installNSEventFallback()
            return
        }
        hotKeyRef = ref
        installCarbonHandler()
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passRetained(requireActionBox()).toOpaque()
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetEventDispatcherTarget(),
                                         Self.carbonEventHandler,
                                         1,
                                         &eventType,
                                         userData,
                                         &ref)
        guard status == noErr, let ref else {
            Unmanaged<HotKeyActionBox>.fromOpaque(userData).release()
            logger.error("InstallEventHandler failed with OSStatus \(status)")
            registrationError = String(localized: "Hot key event handler installation failed (OSStatus \(status)).")
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
                self.hotKeyRef = nil
            }
            installNSEventFallback()
            return
        }
        handlerRef = ref
        handlerUserData = userData
        isActive = true
        activeBackend = .carbon
        registrationError = nil
    }

    /// Best-effort fallback when Carbon registration fails. Note: an NSEvent
    /// global monitor cannot be probed for actual delivery and cannot consume
    /// the event — the foreground app still receives the key combination.
    private func installNSEventFallback() {
        guard let shortcut else { return }
        let actionBox = requireActionBox()
        nsEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard HotKeyMonitor.matches(event, shortcut: shortcut) else { return }
            Task { @MainActor in
                actionBox.action()
            }
        }
        if nsEventMonitor != nil {
            isActive = true
            activeBackend = .nsEvent
        }
    }

    private func unregister() {
        // UX3: Cancel pending confirmations and click on unexpired delayed tasks (clear status when
        // disabling/re-registering).
        pressGeneration &+= 1
        discriminator.reset()
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if let handlerUserData {
            Unmanaged<HotKeyActionBox>.fromOpaque(handlerUserData).release()
            self.handlerUserData = nil
        }
        if let nsEventMonitor {
            NSEvent.removeMonitor(nsEventMonitor)
            self.nsEventMonitor = nil
        }
        isActive = false
        activeBackend = nil
    }

    // MARK: - Matching & modifier mapping (pure, unit-testable)

    /// Carbon event callback. Multiple monitors share the dispatcher, so
    /// each handler must check the signature and registration ID. The callback is a plain C
    /// function without actor isolation; the action hops to the MainActor
    /// explicitly instead of assuming a thread.
    private nonisolated static let carbonEventHandler: EventHandlerUPP = { _, event, userData in
        guard let userData, let event else { return OSStatus(eventNotHandledErr) }
        let box = Unmanaged<HotKeyActionBox>.fromOpaque(userData).takeUnretainedValue()
        var identifier = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
              matches(identifier, registeredIdentifier: box.identifier) else {
            return OSStatus(eventNotHandledErr)
        }
        Task { @MainActor in
            box.action()
        }
        return noErr
    }

    nonisolated static func matches(_ eventID: EventHotKeyID, registeredIdentifier: UInt32) -> Bool {
        eventID.signature == hotKeySignature && eventID.id == registeredIdentifier
    }

    /// Maps the persisted shortcut to Carbon modifier bits (`cmdKey` etc.).
    nonisolated static func carbonModifiers(for shortcut: SettingsStore.HotKeyShortcut) -> UInt32 {
        var modifiers: UInt32 = 0
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        if shortcut.shift { modifiers |= UInt32(shiftKey) }
        if shortcut.option { modifiers |= UInt32(optionKey) }
        if shortcut.control { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    /// Exact match on key code + device-independent modifiers (NSEvent
    /// fallback path only; the Carbon path matches by registration).
    nonisolated static func matches(_ event: NSEvent,
                                    shortcut: SettingsStore.HotKeyShortcut) -> Bool {
        var flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        flags.subtract([.capsLock, .function, .numericPad])
        var expected: NSEvent.ModifierFlags = []
        if shortcut.command { expected.insert(.command) }
        if shortcut.shift { expected.insert(.shift) }
        if shortcut.option { expected.insert(.option) }
        if shortcut.control { expected.insert(.control) }
        return flags == expected && UInt32(event.keyCode) == shortcut.keyCode
    }
}

/// A `Sendable` box around the press route so the Carbon C callback (no actor isolation) can reach the
/// MainActor without strongly capturing the monitor (UX3 onwards, the route closure is called via `weak
/// self` to invoke `handlePress` to arbitrate single/double tap).
/// Immutable after creation; reference lifetime is managed explicitly via `Unmanaged` across
/// install/remove of the event handler.
private final class HotKeyActionBox: @unchecked Sendable {
    let action: @MainActor @Sendable () -> Void
    let identifier: UInt32

    init(identifier: UInt32, _ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
        self.identifier = identifier
    }
}
