import AppKit
import SwiftUI

/// Owns the titlebar layout without publishing toolbar geometry into SwiftUI.
/// Column anchors and toolbar children are placed in the same AppKit layout pass.
@MainActor
final class ColumnToolbarLayout: NSObject, NSToolbarDelegate {
    enum Column { case sidebar, workspace, editor, player }

    private weak var sidebar: NSView?
    private weak var workspace: NSView?
    private weak var editor: NSView?
    private weak var player: NSView?
    private weak var window: NSWindow?
    private var previousToolbar: NSToolbar?
    private let itemIdentifier = NSToolbarItem.Identifier("columnControls")
    private lazy var toolbarView = ColumnToolbarView()
    private lazy var toolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: "SingersLyrics.columnToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        toolbar.itemIdentifiers = [itemIdentifier]
        toolbar.isVisible = true
        return toolbar
    }()

    var showsSidebarToggle = false
    var sidebarIsVisible = false
    var showsEditor = true
    var showsPlayer = true
    var onToggleSidebar: (() -> Void)?

    func update(title: String?, artist: String?, actions: AnyView) {
        toolbarView.actions.rootView = actions
        toolbarView.setTitle(title, artist: artist)
        toolbarView.toggle.toolTip = sidebarIsVisible ? "Hide Sidebar" : "Show Sidebar"
        toolbarView.toggle.setAccessibilityLabel(toolbarView.toggle.toolTip)
        toolbarView.onToggleSidebar = { [weak self] in self?.onToggleSidebar?() }
        toolbarView.onLayout = { [weak self] in self?.layoutToolbar() }
        layoutToolbar()
    }

    func setAnchor(_ view: NSView, for column: Column) {
        switch column {
        case .sidebar: sidebar = view
        case .workspace: workspace = view
        case .editor: editor = view
        case .player: player = view
        }
        layoutToolbar()
    }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        previousToolbar = window.toolbar
        window.toolbar = toolbar
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutToolbar), name: NSWindow.didResizeNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutToolbar), name: NSWindow.didUpdateNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(splitViewDidResize), name: NSSplitView.didResizeSubviewsNotification, object: nil
        )
        layoutToolbar()
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        if let window, window.toolbar === toolbar { window.toolbar = previousToolbar }
        window = nil
        previousToolbar = nil
    }

    @objc private func splitViewDidResize(_ notification: Notification) {
        guard let splitView = notification.object as? NSSplitView, splitView.window === window else { return }
        layoutToolbar()
    }

    @objc func layoutToolbar() {
        guard let window, toolbarView.window === window, toolbarView.bounds.width > 0 else { return }
        let toolbarFrame = toolbarView.convert(toolbarView.bounds, to: nil)
        let inset = AppLayoutMetrics.metadataHeaderHorizontalInset
        let right = toolbarFrame.maxX
        let sidebarFrame = sidebarIsVisible ? frame(of: sidebar) : nil
        let editorFrame = showsEditor ? frame(of: editor) : nil
        let playerFrame = showsPlayer ? frame(of: player) : nil

        let toggleX = sidebarFrame.map { $0.maxX - inset - 28 } ?? toolbarFrame.minX
        toolbarView.toggle.isHidden = !showsSidebarToggle
        place(toolbarView.toggle, from: toggleX, to: toggleX + 28, in: toolbarFrame)

        // In split mode the complete action block belongs to the player column.
        // The hosted view reduces search width within this exact allocation.
        let actionsLeft: CGFloat
        if let playerFrame {
            actionsLeft = max(playerFrame.minX + inset, toolbarFrame.minX)
        } else {
            let workspaceLeft = frame(of: workspace)?.minX ?? toolbarFrame.minX
            actionsLeft = max(workspaceLeft + inset, right - AppLayoutMetrics.maximumToolbarActionsWidth)
        }
        place(toolbarView.actions, from: actionsLeft, to: right, in: toolbarFrame)

        toolbarView.title.isHidden = editorFrame == nil || toolbarView.title.stringValue.isEmpty
        if let editorFrame {
            let leadingClearance = sidebarIsVisible || !showsSidebarToggle ? 0 : 44.0
            let titleLeft = max(editorFrame.minX, toolbarFrame.minX + leadingClearance) + inset
            let titleRight = min(editorFrame.maxX - inset, actionsLeft - inset)
            place(toolbarView.title, from: titleLeft, to: max(titleLeft, titleRight), in: toolbarFrame)
        }
    }

    private func frame(of view: NSView?) -> CGRect? {
        guard let view, view.window === window, !view.isHiddenOrHasHiddenAncestor, !view.bounds.isEmpty else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    private func place(_ view: NSView, from left: CGFloat, to right: CGFloat, in toolbarFrame: CGRect) {
        let height = view === toolbarView.title
            ? toolbarView.title.intrinsicContentSize.height
            : AppLayoutMetrics.toolbarControlHeight
        let frame = CGRect(
            x: left - toolbarFrame.minX,
            y: (toolbarView.bounds.height - height) / 2,
            width: max(0, right - left),
            height: height
        )
        if view.frame != frame { view.frame = frame }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [itemIdentifier] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [itemIdentifier] }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == self.itemIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Workspace"
        item.paletteLabel = "Workspace"
        item.view = flag ? toolbarView : ColumnToolbarView()
        item.isBordered = false
        return item
    }
}

@MainActor
private final class ColumnToolbarView: NSView {
    let toggle = NSButton(image: NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: nil)!, target: nil, action: nil)
    let title = NSTextField(labelWithString: "")
    let actions = NSHostingView(rootView: AnyView(EmptyView()))
    var onLayout: (() -> Void)?
    var onToggleSidebar: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            widthAnchor.constraint(lessThanOrEqualToConstant: 10_000),
            heightAnchor.constraint(equalToConstant: AppLayoutMetrics.toolbarControlHeight),
        ])
        // Prefer all available toolbar space, while allowing AppKit to compress
        // this one item freely. Bounds alone give the item a zero fitting width.
        let preferredWidth = widthAnchor.constraint(equalToConstant: 10_000)
        preferredWidth.priority = NSLayoutConstraint.Priority(1)
        preferredWidth.isActive = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toggle.isBordered = false
        toggle.imageScaling = .scaleProportionallyDown
        toggle.target = self
        toggle.action = #selector(toggleSidebar)
        toggle.setAccessibilityIdentifier("sidebarToggleButton")
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.usesSingleLineMode = true
        title.font = NSFont.preferredFont(forTextStyle: .title2)
        title.setAccessibilityIdentifier("songMetadataHeader")
        setAccessibilityElement(false)
        actions.setAccessibilityLabel("Workspace actions")
        actions.sizingOptions = []
        actions.safeAreaRegions = []
        actions.clipsToBounds = true
        addSubview(toggle)
        addSubview(title)
        addSubview(actions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: AppLayoutMetrics.toolbarControlHeight)
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        onLayout?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayout?()
    }

    override var mouseDownCanMoveWindow: Bool { true }
    @objc private func toggleSidebar() { onToggleSidebar?() }

    func setTitle(_ title: String?, artist: String?) {
        guard let title else {
            self.title.stringValue = ""
            return
        }
        let displayTitle = title.isEmpty ? "Untitled" : title
        let artist = artist.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Singer"
        let size = NSFont.preferredFont(forTextStyle: .title2).pointSize
        let value = NSMutableAttributedString(string: displayTitle, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        value.append(NSAttributedString(string: " | ", attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        value.append(NSAttributedString(string: artist, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
        if !self.title.attributedStringValue.isEqual(to: value) { self.title.attributedStringValue = value }
        self.title.setAccessibilityLabel("\(displayTitle) | \(artist)")
        self.title.setAccessibilityTitle("Song title and singer")
    }
}

struct ColumnToolbarAnchor: NSViewRepresentable {
    let layout: ColumnToolbarLayout
    let column: ColumnToolbarLayout.Column

    func makeNSView(context: Context) -> AnchorView { AnchorView(layout: layout, column: column) }
    func updateNSView(_ view: AnchorView, context: Context) { layout.setAnchor(view, for: column) }

    final class AnchorView: NSView {
        weak var toolbarLayout: ColumnToolbarLayout?
        let column: ColumnToolbarLayout.Column

        init(layout: ColumnToolbarLayout, column: ColumnToolbarLayout.Column) {
            toolbarLayout = layout
            self.column = column
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reportFrame() }
        override func layout() { super.layout(); reportFrame() }
        override func setFrameOrigin(_ origin: NSPoint) { super.setFrameOrigin(origin); reportFrame() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); reportFrame() }
        private func reportFrame() { toolbarLayout?.setAnchor(self, for: column) }
    }
}

struct ColumnToolbarInstaller: NSViewRepresentable {
    let layout: ColumnToolbarLayout
    let sidebarIsVisible: Bool
    let showsSidebarToggle: Bool
    let showsEditor: Bool
    let showsPlayer: Bool
    let title: String?
    let artist: String?
    let actions: AnyView
    let onToggleSidebar: () -> Void

    func makeNSView(context: Context) -> InstallerView { InstallerView(layout: layout) }

    func updateNSView(_ view: InstallerView, context: Context) {
        layout.sidebarIsVisible = sidebarIsVisible
        layout.showsSidebarToggle = showsSidebarToggle
        layout.showsEditor = showsEditor
        layout.showsPlayer = showsPlayer
        layout.onToggleSidebar = onToggleSidebar
        layout.update(title: title, artist: artist, actions: actions)
    }

    static func dismantleNSView(_ view: InstallerView, coordinator: Void) { view.toolbarLayout?.detach() }

    final class InstallerView: NSView {
        weak var toolbarLayout: ColumnToolbarLayout?
        init(layout: ColumnToolbarLayout) { toolbarLayout = layout; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { toolbarLayout?.attach(to: window) }
        }
    }
}
