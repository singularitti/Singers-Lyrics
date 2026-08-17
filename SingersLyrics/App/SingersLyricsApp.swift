import SwiftUI

@main
struct SingersLyricsApp: App {
    @NSApplicationDelegateAdaptor(SingersLyricsApplicationDelegate.self) private var applicationDelegate
    @State private var appModel: AppModel
    @State private var musicModel: MusicPlaybackModel
    private let metadataLookup: any TrackMetadataLookingUp
    private let isUnitTestHost: Bool

    init() {
        let processInfo = ProcessInfo.processInfo
        let arguments = processInfo.arguments
        let isUITesting = arguments.contains("--ui-testing")
        let hasXCTestConfiguration = processInfo.environment["XCTestConfigurationFilePath"] != nil
        let isAutomatedTesting = isUITesting || hasXCTestConfiguration
        let isUnitTestHost = hasXCTestConfiguration && !isUITesting
        if arguments.contains("--reset-ui-testing-preferences") {
            for key in PreferenceKey.all {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let store: any LibraryStoring = isAutomatedTesting ? InMemoryLibraryStore() : JSONLibraryStore()
        let music: any MusicControlling = isAutomatedTesting ? InertMusicController() : AppleMusicController()
        let appModel = AppModel(store: store)
        let musicModel = MusicPlaybackModel(controller: music)
        let metadataLookup: any TrackMetadataLookingUp = isAutomatedTesting
            ? UITestTrackMetadataService()
            : ITunesTrackMetadataService()
        _appModel = State(initialValue: appModel)
        _musicModel = State(initialValue: musicModel)
        self.metadataLookup = metadataLookup
        self.isUnitTestHost = isUnitTestHost
        applicationDelegate.configure(
            isUITesting: isUITesting,
            suppressesMainWindow: isUnitTestHost
        ) {
            AnyView(MainAppView(
                appModel: appModel,
                musicModel: musicModel,
                metadataLookup: metadataLookup
            ))
        }
    }

    var body: some Scene {
        Window("Singers Lyrics", id: "main") {
            MainAppView(
                appModel: appModel,
                musicModel: musicModel,
                metadataLookup: metadataLookup
            )
        }
        .defaultLaunchBehavior(isUnitTestHost ? .suppressed : .presented)
        .defaultSize(width: 1_380, height: 820)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SingersLyricsCommands(model: appModel)
        }

        Settings {
            SettingsView()
                .frame(width: 460)
                .padding()
        }
    }
}

@MainActor
private final class SingersLyricsApplicationDelegate: NSObject, NSApplicationDelegate {
    private var makeMainView: (() -> AnyView)?
    private var fallbackWindowController: NSWindowController?
    private var isUITesting = false
    private var suppressesMainWindow = false

    func configure(
        isUITesting: Bool,
        suppressesMainWindow: Bool,
        makeMainView: @escaping () -> AnyView
    ) {
        self.isUITesting = isUITesting
        self.suppressesMainWindow = suppressesMainWindow
        self.makeMainView = makeMainView
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        presentMainWindowIfNeeded()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            presentMainWindowIfNeeded()
        }
        return true
    }

    private func presentMainWindowIfNeeded() {
        guard !suppressesMainWindow else { return }
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            return
        }
        if let fallbackWindowController {
            fallbackWindowController.showWindow(nil)
            fallbackWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let makeMainView else { return }

        let hostingController = NSHostingController(rootView: makeMainView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_380, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Singers Lyrics"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.minSize = NSSize(
            width: AppLayoutMetrics.minimumWindowWidth,
            height: AppLayoutMetrics.minimumWindowHeight
        )
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if isUITesting {
            window.setContentSize(NSSize(width: 1_380, height: 820))
            window.center()
        } else {
            window.setFrameAutosaveName("SingersLyricsMainWindow")
            if !window.setFrameUsingName("SingersLyricsMainWindow") {
                window.setContentSize(NSSize(width: 1_380, height: 820))
                window.center()
            }
        }

        let controller = NSWindowController(window: window)
        fallbackWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct MainAppView: View {
    let appModel: AppModel
    let musicModel: MusicPlaybackModel
    let metadataLookup: any TrackMetadataLookingUp
    @AppStorage(PreferenceKey.appearance) private var appearance = Appearance.system.rawValue

    var body: some View {
        AppRootView(metadataLookup: metadataLookup)
            .environment(appModel)
            .environment(musicModel)
            .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
    }
}

private struct AppRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let metadataLookup: any TrackMetadataLookingUp

    var body: some View {
        ContentView(metadataLookup: metadataLookup)
            .task {
                await model.load()
                await model.backfillLinkedTrackMetadata(using: metadataLookup)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active else { return }
                Task { await model.flush() }
            }
    }
}

struct SingersLyricsCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Song from Apple Music…") {
                model.isCreatingSong = true
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(after: .textEditing) {
            Button("Emoji & Symbols…") {
                NSApp.orderFrontCharacterPalette(nil)
            }
            .keyboardShortcut(" ", modifiers: [.control, .command])
        }
    }
}
