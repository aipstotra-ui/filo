import AppKit
import SwiftUI

/// The floating suggestion popup window. Non-activating, so showing it never
/// steals focus from whatever app the user is in; it becomes key ONLY when the
/// user clicks into it (so Return/Esc and typing work), never on show — we call
/// `orderFrontRegardless()`, never `makeKey…` or `NSApp.activate` (spec §6.5).
final class SuggestionPanel: NSPanel {
    /// Reports key-state changes so the controller can pause the auto-dismiss
    /// countdown while the user is interacting.
    var onKeyChange: ((Bool) -> Void)?

    /// Esc, from anywhere inside the panel.
    ///
    /// Founder decision 5 says Esc must ALWAYS be answered, never inert. The
    /// SwiftUI footer covers it with a `.cancelAction` button in most states —
    /// but not in the completed state, whose only button is the default-action
    /// "OK", so Esc there reached nothing at all (A6). Handling it on the window
    /// makes the guarantee structural: it holds in every state the content view
    /// can be in, including ones added later.
    var onCancel: (() -> Void)?

    init(contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Rounded corners: the window is transparent outside the content's
        // rounded shape; the SwiftUI content paints the opaque window material.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        animationBehavior = .utilityWindow
    }

    // A borderless panel is non-key by default; allow key (only on user click)
    // so the field, Return, and Esc work. Never main — it must not front the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        onKeyChange?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyChange?(false)
    }

    /// The end of the responder chain for Esc. A `.cancelAction` button in the
    /// content view consumes the key first when there is one; this catches every
    /// state where there is not.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Places a popup and drives its entrance animation. The real `PanelPresenting`
/// behind `PopupController`. Owns at most one panel at a time.
@MainActor
final class SuggestionPanelController: PanelPresenting {
    /// Margin from the screen's visible edges (below the menu bar / notch).
    private static let margin: CGFloat = 14

    private var panel: SuggestionPanel?
    private var screenChangeObserver: NSObjectProtocol?
    /// The live state of the popup on screen. Held here so `update(activity:)`
    /// can re-render the panel in place rather than tearing it down and putting
    /// a new one up — which would lose the user's edited text and re-run the
    /// entrance animation.
    private var state: PopupViewState?
    /// The hosting view, retained so a state change can be re-measured. Without
    /// it the panel kept the height it was born with, and the failure message —
    /// three or four wrapped lines at 312 pt — was drawn outside the window,
    /// taking the footer buttons with it (F4/A1/D1).
    private var hosting: NSHostingView<PopupContentView>?

    init() {}

    func show(_ suggestion: PopupSuggestion, callbacks: PopupCallbacks) {
        hide()   // never two popups at once

        let state = PopupViewState()
        self.state = state
        let content = PopupContentView(
            suggestion: suggestion,
            state: state,
            onAccept: callbacks.onAccept,
            onDismiss: callbacks.onDismiss,
            onHoverChanged: callbacks.onHoverChanged
        )
        let hosting = NSHostingView(rootView: content)
        hosting.layout()
        let size = hosting.fittingSize
        self.hosting = hosting

        let panel = SuggestionPanel(contentSize: size)
        panel.contentView = hosting
        panel.onKeyChange = callbacks.onKeyChanged
        panel.onCancel = callbacks.onDismiss
        self.panel = panel

        let target = Self.targetFrame(for: size)
        animateIn(panel, to: target)
        postArrivalAnnouncement(suggestion, from: hosting)
        observeScreenChanges(for: panel)
    }

    func update(activity: PopupActivity) {
        state?.activity = activity
        resizeToFitContent()
    }

    func announce(_ message: String) {
        NSAccessibility.post(
            element: panel ?? (NSApp as Any),
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// Re-measures the content and grows/shrinks the panel around it.
    ///
    /// Top-anchored: the popup's top edge is where the user's eye already is, so
    /// the extra lines of a failure message appear *below* what they were
    /// reading rather than shoving the whole panel upward. Re-clamped to the
    /// screen afterwards, because a taller panel can now overhang the bottom.
    private func resizeToFitContent() {
        guard let panel, let hosting else { return }
        hosting.layout()
        let fitted = hosting.fittingSize
        guard fitted.height > 0, abs(fitted.height - panel.frame.height) > 0.5 else { return }

        var frame = panel.frame
        let top = frame.maxY
        frame.size = fitted
        frame.origin.y = top - fitted.height
        let target = Self.clamped(frame)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().setFrame(target, display: true)
        }
    }

    func hide() {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
        state = nil
        hosting = nil
        guard let closing = panel else { return }
        panel = nil
        closing.onKeyChange = nil
        closing.onCancel = nil
        // Fade the old panel out independently so the queue can advance at once
        // (no wait for the animation). ≤250 ms, honoring Reduce Motion (fade is
        // allowed under Reduce Motion; only the slide is dropped).
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            closing.animator().alphaValue = 0
        }, completionHandler: {
            closing.orderOut(nil)
        })
    }

    // MARK: - Placement

    private func observeScreenChanges(for panel: SuggestionPanel) {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak panel] _ in
            MainActor.assumeIsolated {
                guard let panel else { return }
                panel.setFrame(Self.targetFrame(for: panel.frame.size), display: true)
            }
        }
    }

    /// Top-right of the screen under the pointer (else the main/first screen),
    /// clamped inside its `visibleFrame` (which already excludes the menu bar,
    /// notch band, and Dock).
    private static func targetFrame(for size: NSSize) -> NSRect {
        let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }
        return PopupPositioner.topRightFrame(in: visibleFrame, size: size, margin: margin)
    }

    /// Keeps an already-placed frame fully inside its screen after a resize.
    /// Uses the screen the panel is on, not the one under the pointer — the
    /// pointer may be anywhere by the time a move finishes.
    private static func clamped(_ frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return frame }
        return PopupPositioner.clamp(frame, inside: visibleFrame)
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    // MARK: - Entrance animation

    private func animateIn(_ panel: SuggestionPanel, to target: NSRect) {
        panel.alphaValue = 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Reduce Motion: cross-fade in place, no slide.
            panel.setFrame(target, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        } else {
            var start = target
            start.origin.x += 12   // slide in ~12 px from the right while fading up
            panel.setFrame(start, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    // MARK: - VoiceOver arrival announcement

    /// Posts a high-priority arrival announcement (a11y must-fix #1). NOTE: an
    /// announcement from a non-key `.accessory` panel while a different app is
    /// frontmost is known to be unreliable; this is implemented per Apple's API
    /// but MUST be verified live with VoiceOver. It is not "fixed" by making the
    /// panel key on show — that would violate the non-activating requirement.
    private func postArrivalAnnouncement(_ suggestion: PopupSuggestion, from element: NSView) {
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: Self.announcement(for: suggestion),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// The spoken arrival text. Pure and static so it is unit-testable and reuses
    /// the canonical "No folder fits…" string verbatim (a11y must-fix #9).
    static func announcement(for suggestion: PopupSuggestion) -> String {
        switch suggestion.destination {
        case .folder(let name, _):
            return "Suggestion ready. Suggested name \(suggestion.suggestedFilename), destination \(name)."
        case .noFolderFits:
            return "Suggestion ready. Suggested name \(suggestion.suggestedFilename). No folder fits — leaving it in Downloads."
        case .quiet:
            return "Suggestion ready. Suggested name \(suggestion.suggestedFilename)."
        }
    }
}

/// Pure geometry for placing the popup — no screen, no state, so it is unit-
/// testable. Places `size` at the top-right of `visibleFrame` inset by `margin`
/// (AppKit's bottom-left origin), then clamps it fully inside `visibleFrame`.
enum PopupPositioner {
    static func topRightFrame(in visibleFrame: CGRect, size: CGSize, margin: CGFloat) -> CGRect {
        let x = visibleFrame.maxX - size.width - margin
        let y = visibleFrame.maxY - size.height - margin
        return clamp(
            CGRect(x: x, y: y, width: size.width, height: size.height), inside: visibleFrame
        )
    }

    /// Pushes `frame` fully inside `visibleFrame` without resizing it. Shared
    /// with the resize path, which has to re-clamp after the panel grows: a
    /// failure message adds three or four lines, and a popup near the bottom of
    /// a short screen would otherwise hang off it (F4).
    static func clamp(_ frame: CGRect, inside visibleFrame: CGRect) -> CGRect {
        var frame = frame
        if frame.maxX > visibleFrame.maxX { frame.origin.x = visibleFrame.maxX - frame.width }
        if frame.minX < visibleFrame.minX { frame.origin.x = visibleFrame.minX }
        if frame.maxY > visibleFrame.maxY { frame.origin.y = visibleFrame.maxY - frame.height }
        if frame.minY < visibleFrame.minY { frame.origin.y = visibleFrame.minY }
        return frame
    }
}

/// Production reader of the assistive-technology state (spec §2, §6.3). Sampled
/// fresh each time the auto-dismiss timer is (re)considered — on show and on
/// every hover/key change — which is correct for continuously-on VoiceOver or
/// Full Keyboard Access (the real case). `isVoiceOverEnabled` is KVO-observable
/// should live mid-popup updates ever be wanted.
@MainActor
final class SystemAccessibilityStatus: AccessibilityStatusReading {
    init() {}

    var wantsPersistentInteraction: Bool {
        if NSWorkspace.shared.isVoiceOverEnabled { return true }
        return Self.fullKeyboardAccessEnabled
    }

    /// Full Keyboard Access has no dedicated public API; the documented
    /// workaround is the global `AppleKeyboardUIMode` default — bit 1 (value 2)
    /// set means it is on. Best-effort; VoiceOver is the primary signal.
    private static var fullKeyboardAccessEnabled: Bool {
        (UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 2) != 0
    }
}
