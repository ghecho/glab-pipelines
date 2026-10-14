import AppKit
import SwiftUI

/// Lets another program, such as a SketchyBar item, show the menubar state and open the panel.
/// This matters when the macOS menu bar is hidden. Both directions use distributed notifications,
/// so the listener needs no polling and the app needs no URL scheme.
///
/// - `…state`: the app posts it when the state changes. The object is `error`, `none`, or a
///   `PipelineState` raw value.
/// - `…panel`: the app posts it when the panel opens or closes. The object is `open` or `closed`.
/// - `…requestState`: post it to get `…state` and `…panel` notifications now, for a listener that
///   starts late.
/// - `…togglePanel`: post it to open or close the panel under the mouse. The object is the distance
///   in points from the top of the screen to the top of the panel, such as the height of the bar.
@MainActor
final class Bridge: NSObject {
    static let stateChanged = Notification.Name("tech.vitenskap.glab.pipelines.state")
    static let requestState = Notification.Name("tech.vitenskap.glab.pipelines.requestState")
    static let togglePanel = Notification.Name("tech.vitenskap.glab.pipelines.togglePanel")
    static let panelChanged = Notification.Name("tech.vitenskap.glab.pipelines.panel")

    private static var state = "none"
    private static var shared: Bridge?

    private let panel: FloatingPanel

    private init(model: AppModel) {
        panel = FloatingPanel(model: model)
    }

    /// macOS holds back distributed notifications while an app is inactive, and a menubar app is
    /// inactive almost always. Only the selector form of addObserver can opt out of that.
    static func start(model: AppModel) {
        let bridge = Bridge(model: model)
        shared = bridge
        let center = DistributedNotificationCenter.default()
        center.addObserver(bridge, selector: #selector(onRequestState), name: requestState, object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(bridge, selector: #selector(onTogglePanel), name: togglePanel, object: nil, suspensionBehavior: .deliverImmediately)
    }

    static func publish(_ newState: String) {
        state = newState
        post()
    }

    private static func post() {
        DistributedNotificationCenter.default()
            .postNotificationName(stateChanged, object: state, userInfo: nil, deliverImmediately: true)
    }

    fileprivate static func postPanel(open: Bool) {
        DistributedNotificationCenter.default()
            .postNotificationName(panelChanged, object: open ? "open" : "closed", userInfo: nil, deliverImmediately: true)
    }

    @objc private func onRequestState() {
        Self.post()
        Self.postPanel(open: panel.isVisible)
    }

    @objc private func onTogglePanel(_ notification: Notification) {
        panel.toggle(top: (notification.object as? String).flatMap(Double.init) ?? 0)
    }
}

/// The panel in a window of its own. MenuBarExtra has no API to open its window, and it ignores
/// both the accessibility press action and synthetic clicks, so the bridge cannot reuse it.
/// This window looks like it and closes the same way, when it loses focus.
private final class FloatingPanel: NSPanel {
    init(model: AppModel) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        let host = NSHostingView(rootView: PanelView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
    }

    /// The top edge the panel hangs from while open. MenuBarExtra pins its window to the status
    /// item, but this window has no anchor of its own: Auto Layout resizes it around a fixed bottom
    /// edge, and FitWindowToContent keeps whatever top it finds, so each expand or collapse moved it.
    private var top: CGFloat?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let top { frame.origin.y = top - frame.height }
        super.setFrame(frame, display: flag)
    }

    // A borderless window cannot take keys by default, and the Watch… field needs them.
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    override func orderOut(_ sender: Any?) {
        let wasVisible = isVisible
        super.orderOut(sender)
        if wasVisible { Bridge.postPanel(open: false) }
    }

    func toggle(top: CGFloat) {
        if isVisible {
            orderOut(nil)
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let size = contentView?.fittingSize else { return }
        let margin: CGFloat = 8
        let x = min(max(mouse.x - size.width / 2, screen.frame.minX + margin), screen.frame.maxX - size.width - margin)
        self.top = screen.frame.maxY - top
        setFrame(NSRect(x: x, y: 0, width: size.width, height: size.height), display: true)
        makeKeyAndOrderFront(nil)
        Bridge.postPanel(open: true)
    }
}
