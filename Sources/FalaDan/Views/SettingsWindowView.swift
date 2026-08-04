import AppKit
import Combine
import SwiftUI

enum FalaDanSettingsTab: Hashable {
    case general
    case shortcuts
    case integrations
}

private extension FalaDanSettingsTab {
    static let contentWidth: CGFloat = 520

    var contentSize: NSSize {
        switch self {
        case .general:
            return NSSize(width: Self.contentWidth, height: 500)
        case .shortcuts:
            return NSSize(width: Self.contentWidth, height: 390)
        case .integrations:
            return NSSize(width: Self.contentWidth, height: 500)
        }
    }
}

@MainActor
final class FalaDanSettingsNavigation: ObservableObject {
    static let shared = FalaDanSettingsNavigation()
    @Published var selectedTab: FalaDanSettingsTab = .general
    private init() {}
}

struct FalaDanSettingsView: View {
    @ObservedObject private var nav = FalaDanSettingsNavigation.shared

    var body: some View {
        Group {
            switch nav.selectedTab {
            case .general:
                GeneralSettingsPage()
            case .shortcuts:
                ShortcutSettingsPage()
            case .integrations:
                IntegrationSettingsPage()
            }
        }
        .frame(
            width: nav.selectedTab.contentSize.width,
            height: nav.selectedTab.contentSize.height,
            alignment: .top
        )
    }
}

@MainActor
final class FalaDanSettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = FalaDanSettingsWindowController()

    private let nav = FalaDanSettingsNavigation.shared
    private var navObserver: AnyCancellable?

    private struct TabSpec {
        let tab: FalaDanSettingsTab
        let id: NSToolbarItem.Identifier
        let label: String
        let symbol: String
    }

    private static let specs: [TabSpec] = [
        TabSpec(tab: .general, id: .init("general"), label: "General", symbol: "gearshape"),
        TabSpec(tab: .shortcuts, id: .init("shortcuts"), label: "Shortcuts", symbol: "keyboard"),
        TabSpec(tab: .integrations, id: .init("integrations"), label: "Integrations", symbol: "terminal"),
    ]

    private static func spec(for tab: FalaDanSettingsTab) -> TabSpec? {
        specs.first { $0.tab == tab }
    }

    private static func spec(for id: NSToolbarItem.Identifier) -> TabSpec? {
        specs.first { $0.id == id }
    }

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func open(appState: AppState) {
        if window == nil {
            configureWindow(appState: appState)
        }

        resizeWindow(for: nav.selectedTab, animate: false)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func configureWindow(appState: AppState) {
        let rootView = FalaDanSettingsView()
            .environment(appState)
        let host = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: host)
        window.title = "FalaDan Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FalaDanSettingsWindow")
        window.center()

        let toolbar = NSToolbar(identifier: "FalaDanSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = Self.spec(for: nav.selectedTab)?.id

        window.toolbar = toolbar
        window.toolbarStyle = .preference
        self.window = window

        navObserver = nav.$selectedTab.sink { [weak self, weak toolbar] tab in
            let newID = Self.spec(for: tab)?.id
            if toolbar?.selectedItemIdentifier != newID {
                toolbar?.selectedItemIdentifier = newID
            }
            self?.resizeWindow(for: tab, animate: true)
        }
    }

    private func resizeWindow(for tab: FalaDanSettingsTab, animate: Bool) {
        guard let window else { return }

        let contentRect = window.contentRect(forFrameRect: window.frame)
        let targetContentRect = NSRect(origin: contentRect.origin, size: tab.contentSize)
        var targetFrame = window.frameRect(forContentRect: targetContentRect)
        targetFrame.origin.x = window.frame.midX - targetFrame.width / 2
        targetFrame.origin.y = window.frame.maxY - targetFrame.height

        if animate, window.isVisible {
            window.animator().setFrame(targetFrame, display: true)
        } else {
            window.setFrame(targetFrame, display: true)
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.specs.map(\.id)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.specs.map(\.id)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.specs.map(\.id)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let spec = Self.spec(for: id) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.action = #selector(selectTab(_:))
        item.label = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        return item
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        if let spec = Self.spec(for: sender.itemIdentifier) {
            nav.selectedTab = spec.tab
        }
    }
}

private struct GeneralSettingsPage: View {
    @Environment(AppState.self) private var appState
    @StateObject private var launchManager = LaunchAtLoginManager.shared
    @State private var vadEnabled = VADSettings.enabled

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Behavior") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { launchManager.isEnabled },
                        set: { launchManager.isEnabled = $0 }
                    )
                )
            }

            Section("Transcription") {
                Toggle(
                    "Trim long silences",
                    isOn: Binding(
                        get: { vadEnabled },
                        set: {
                            vadEnabled = $0
                            VADSettings.enabled = $0
                        }
                    )
                )

                Toggle(isOn: $appState.replacementSettings.enabled) {
                    InfoLabel(
                        title: "Enable replacements",
                        text: "Apply find-and-replace rules to every transcription."
                    )
                }
            }

            Section("About") {
                LabeledContent("Version", value: AppVersionInfo.current.displayString)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
        .onChange(of: appState.replacementSettings) {
            appState.replacementSettings.save()
        }
        .onAppear {
            launchManager.refresh()
            vadEnabled = VADSettings.enabled
        }
    }
}

private struct ShortcutSettingsPage: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                ForEach(CustomShortcutName.allCases, id: \.self) { name in
                    SettingsShortcutRow(name: name)
                }
            }

            Section("Defaults") {
                Button("Reset Shortcuts") {
                    CustomShortcutStorage.saveAll(CustomShortcutStorage.defaultShortcuts())
                    appState.reloadShortcuts()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
    }
}

private struct SettingsShortcutRow: View {
    @Environment(AppState.self) private var appState
    let name: CustomShortcutName
    @State private var isEditing = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name.settingsTitle)
                Text(name.settingsDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isEditing {
                ShortcutRecorderView(
                    shortcut: Binding(
                        get: { CustomShortcutStorage.get(name) },
                        set: { newShortcut in
                            CustomShortcutStorage.set(newShortcut, for: name)
                            appState.reloadShortcuts()
                            isEditing = false
                        }
                    )
                )
                Button("Cancel") { isEditing = false }
                    .buttonStyle(.borderless)
            } else {
                if needsRerecording {
                    // A stored binding no backend can register looks entirely
                    // normal in this row, so without a marker the only symptom
                    // is a shortcut that quietly does nothing.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("This shortcut can no longer be registered. Record a new one.")
                }
                Button(shortcutLabel) { isEditing = true }
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    private var shortcutLabel: String {
        CustomShortcutStorage.get(name)?.compactDisplayString ?? "Not Set"
    }

    private var needsRerecording: Bool {
        CustomShortcutStorage.get(name)?.needsRerecording ?? false
    }
}

private struct IntegrationSettingsPage: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Files") {
                Button("Open FalaDan Folder") {
                    NSWorkspace.shared.selectFile(
                        nil,
                        inFileViewerRootedAtPath: Recording.baseDirectory.deletingLastPathComponent().path
                    )
                }

                if appState.envConfig.isCleanupConfigured {
                    CleanupPromptSettingsRow()
                }

                Button("Open Menu Bar Settings") {
                    SystemSettingsLinks.openMenuBarSettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
    }
}

private struct CleanupPromptSettingsRow: View {
    @Environment(AppState.self) private var appState
    @State private var hasCustomPrompt = CleanupPromptStore.hasCustomPrompt

    var body: some View {
        HStack {
            Button("Edit cleanup prompt", action: edit)

            Spacer()

            if hasCustomPrompt {
                Button("Reset", action: confirmReset)
                    .foregroundStyle(Color.red)
            }
        }
        .onAppear { hasCustomPrompt = CleanupPromptStore.hasCustomPrompt }
    }

    private func edit() {
        do {
            try CleanupPromptStore.seedIfMissing()
            NSWorkspace.shared.open(CleanupPromptStore.fileURL)
            hasCustomPrompt = CleanupPromptStore.hasCustomPrompt
        } catch {
            appState.toast.showError(
                title: "Couldn't Open Prompt File",
                message: error.localizedDescription
            )
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset cleanup prompt?"
        alert.informativeText =
            "This overwrites your edits to cleanup-prompt.md with the bundled default. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try CleanupPromptStore.resetToDefault()
            hasCustomPrompt = false
        } catch {
            appState.toast.showError(
                title: "Reset Failed",
                message: error.localizedDescription
            )
        }
    }
}

private extension CustomShortcutName {
    var settingsTitle: String {
        switch self {
        case .toggleRecording: return "Toggle Recording"
        case .cancelRecording: return "Cancel Recording"
        }
    }

    var settingsDescription: String {
        switch self {
        case .toggleRecording: return "Start or stop normal transcription"
        case .cancelRecording: return "Cancel the active recording"
        }
    }
}
