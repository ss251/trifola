import SwiftUI
import AppKit
import Combine
import TrifolaKit

@MainActor
final class AppPreferencesModel: ObservableObject {
    @Published var value: AppPreferences {
        didSet {
            guard value != oldValue, !restoring else { return }
            let requested = value
            guard store.save(requested) else {
                pendingValue = requested
                restoring = true
                value = oldValue
                restoring = false
                persistenceError = "Settings were not saved at \(store.url.path)."
                return
            }
            pendingValue = nil
            persistenceError = nil
        }
    }
    @Published private(set) var persistenceError: String?

    private let store: AppPreferencesStore
    private var pendingValue: AppPreferences?
    private var restoring = false

    var persistenceLocation: URL { store.url.deletingLastPathComponent() }

    init(store: AppPreferencesStore = AppPreferencesStore()) {
        self.store = store
        self.value = store.load()
    }

    func retryPersistence() {
        guard let pendingValue else { return }
        guard store.save(pendingValue) else {
            persistenceError = "Settings still could not be saved at \(store.url.path)."
            return
        }
        restoring = true
        value = pendingValue
        restoring = false
        self.pendingValue = nil
        persistenceError = nil
    }
}

/// One reusable, low-frequency persistence receipt. It deliberately stays inline
/// instead of becoming a transient toast: the failed action remains visible until
/// Retry succeeds or the user changes it again.
struct InlinePersistenceBanner: View {
    let message: String
    let retry: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.amber)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            TapButton("Reveal folder", action: reveal)
                .foregroundStyle(Theme.muted)
            TapButton("Retry", action: retry)
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, Theme.rowVerticalInset)
        .background(Theme.amber.opacity(0.10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Persistence error")
    }
}

/// A standard macOS Settings surface. It observes only low-frequency preference,
/// notification, and machine-config objects — never the session/fleet services.
struct TrifolaSettingsView: View {
    @ObservedObject var menuPresence: MenuBarPresence
    @ObservedObject var notifier: BlockedNotifierService
    @ObservedObject var preferences: AppPreferencesModel
    @ObservedObject var workspaceAccess: WorkspaceAccessCoordinator
    @ObservedObject var machines: MachineStore
    @ObservedObject var agency: AgencyController

    private struct PersistenceIssue {
        let message: String
        let location: URL
        let retry: () -> Void
    }

    private var persistenceIssue: PersistenceIssue? {
        if let message = preferences.persistenceError {
            return PersistenceIssue(message: message,
                                    location: preferences.persistenceLocation,
                                    retry: preferences.retryPersistence)
        }
        if let message = notifier.persistenceError {
            return PersistenceIssue(message: message,
                                    location: notifier.persistenceLocation,
                                    retry: notifier.retryPersistence)
        }
        if let message = menuPresence.persistenceError {
            return PersistenceIssue(message: message,
                                    location: menuPresence.persistenceLocation,
                                    retry: menuPresence.retryPersistence)
        }
        if let message = machines.persistenceError {
            return PersistenceIssue(message: message,
                                    location: machines.persistenceLocation,
                                    retry: machines.retryPersistence)
        }
        if let message = agency.persistenceError {
            return PersistenceIssue(message: message,
                                    location: agency.persistenceLocation,
                                    retry: agency.retryPersistence)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let issue = persistenceIssue {
                InlinePersistenceBanner(
                    message: issue.message,
                    retry: issue.retry,
                    reveal: { NSWorkspace.shared.open(issue.location) })
            }
            TabView {
                GeneralSettings(
                    menuPresence: menuPresence,
                    workspaceAccess: workspaceAccess)
                    .tabItem { Label("General", systemImage: "gear") }
                AttentionSettings(notifier: notifier, preferences: preferences)
                    .tabItem { Label("Attention", systemImage: "bell") }
                QuotaAccessSettings(preferences: preferences)
                    .tabItem { Label("Quota", systemImage: "gauge.with.dots.needle.67percent") }
                MachineSettings(machines: machines)
                    .tabItem { Label("Machines", systemImage: "desktopcomputer") }
                AboutSettings()
                    .tabItem { Label("About", systemImage: "info.circle") }
            }
        }
        .frame(width: 520, height: 420)
    }
}

private struct QuotaAccessSettings: View {
    @ObservedObject var preferences: AppPreferencesModel

    var body: some View {
        Form {
            Section("Plan quota access") {
                Text("Quota is optional and off by default. Each provider has an independent read boundary.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TapToggle("Claude quota", isOn: preferenceBinding(
                    get: { $0.claudeQuotaAccessEnabled },
                    set: { $0.claudeQuotaAccessEnabled = $1 }))
                Text("Reads ~/.claude/.credentials.json, may ask macOS Keychain for the Claude Code OAuth token, then makes one HTTPS request to Anthropic's usage endpoint.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TapToggle("Codex quota", isOn: preferenceBinding(
                    get: { $0.codexQuotaAccessEnabled },
                    set: { $0.codexQuotaAccessEnabled = $1 }))
                Text("Reads rate-limit events from local ~/.codex/sessions rollout files only. No network request and no Codex process.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("Turning a provider off clears its in-memory quota snapshot. Session, cost, and attention data are unaffected.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func preferenceBinding(
        get: @escaping (AppPreferences) -> Bool,
        set: @escaping (inout AppPreferences, Bool) -> Void
    ) -> Binding<Bool> {
        Binding(get: { get(preferences.value) }, set: { newValue in
            var copy = preferences.value
            set(&copy, newValue)
            preferences.value = copy
        })
    }
}

private struct GeneralSettings: View {
    @ObservedObject var menuPresence: MenuBarPresence
    @ObservedObject var workspaceAccess: WorkspaceAccessCoordinator
    private let location = ClaudeConfigLocation.resolve()

    var body: some View {
        Form {
            TapToggle("Show the menu-bar strip", isOn: menuPresence.boundEnabled)
            LabeledContent("Claude config root") {
                Text(location.url.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text("\(location.explainer). Trifola reads this location and never writes Claude configuration.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Section("Terminal workspace jumps") {
                LabeledContent("Accessibility") {
                    Text(workspaceAccess.status.label)
                        .foregroundStyle(workspaceAccess.status == .granted
                            ? Color.green : Color.secondary)
                }
                Text(WorkspaceAccessCopy.settingsExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if workspaceAccess.status != .granted {
                    TapButton(WorkspaceAccessCopy.openSettingsButton) {
                        _ = workspaceAccess.openAccessibilitySettings()
                    }
                    .help("Open System Settings → Privacy & Security → Accessibility")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { workspaceAccess.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                workspaceAccess.refreshStatus()
            }
    }
}

private struct AttentionSettings: View {
    @ObservedObject var notifier: BlockedNotifierService
    @ObservedObject var preferences: AppPreferencesModel

    var body: some View {
        Form {
            TapToggle("Notify when a session becomes blocked", isOn: Binding(
                get: { notifier.enabled }, set: { notifier.setEnabled($0) }))
            LabeledContent("macOS permission") {
                Text(notifier.authorizationStatus.label)
                    .foregroundStyle(permissionColor)
            }
            if let note = notifier.authorizationNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(notifier.authorizationStatus == .denied ? .red : .secondary)
            }
            if notifier.authorizationStatus == .denied {
                TapButton("Open System Settings") {
                    _ = notifier.openSystemNotificationSettings()
                }
                .help("Open macOS Notifications settings for Trifola")
            }
            Text("Notifications are opt-in. The attention strip and menu-bar signal remain visible either way.")
                .font(.footnote).foregroundStyle(.secondary)

            TapToggle("Quiet hours", isOn: preferenceBinding(
                get: { $0.quietHours.enabled }, set: { $0.quietHours.enabled = $1 }))
            HStack {
                DatePicker("From", selection: minuteDateBinding(\.quietHours.startMinute),
                           displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: minuteDateBinding(\.quietHours.endMinute),
                           displayedComponents: .hourAndMinute)
            }
            .disabled(!preferences.value.quietHours.enabled)
            Text("Quiet hours suppress banners only. Strip and glyph signals stay truthful, and snoozes still apply.")
                .font(.footnote).foregroundStyle(.secondary)

            Picker("Default snooze", selection: preferenceBinding(
                get: { $0.defaultSnoozeDurationMinutes },
                set: { $0.defaultSnoozeDurationMinutes = $1 })) {
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("2 hours").tag(120)
                Text("8 hours").tag(480)
            }
        }
        .formStyle(.grouped)
        .onAppear { notifier.refreshAuthorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                notifier.refreshAuthorizationStatus()
            }
    }

    private var permissionColor: Color {
        switch notifier.authorizationStatus {
        case .allowed: .green
        case .denied: .red
        case .notDetermined, .unavailable: .secondary
        }
    }

    private func preferenceBinding<Value>(
        get: @escaping (AppPreferences) -> Value,
        set: @escaping (inout AppPreferences, Value) -> Void
    ) -> Binding<Value> {
        Binding(get: { get(preferences.value) }, set: { newValue in
            var copy = preferences.value
            set(&copy, newValue)
            preferences.value = copy
        })
    }

    private func minuteDateBinding(_ keyPath: WritableKeyPath<AppPreferences, Int>) -> Binding<Date> {
        Binding(get: {
            let minute = preferences.value[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: minute / 60,
                                         minute: minute % 60,
                                         second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            var copy = preferences.value
            copy[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            preferences.value = copy
        })
    }
}

private struct MachineSettings: View {
    private struct RemovalContext: Identifiable {
        let remote: RemoteConfig
        let mirrorBytes: UInt64
        let mirrorPath: String
        var id: String { remote.id }
    }

    @ObservedObject var machines: MachineStore
    @State private var name = ""
    @State private var host = ""
    @State private var user = NSUserName()
    @State private var validation: String?
    @State private var removal: RemovalContext?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "flask").font(.body.weight(.medium)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Experimental").font(.headline)
                        Text("Remote transcript mirroring is read-only and best-effort. A down host leaves this Mac fully usable.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Configured hosts") {
                if machines.config.remotes.isEmpty {
                    Text("No remote machines configured.").foregroundStyle(.secondary)
                }
                ForEach(machines.config.remotes) { remote in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(remote.name).font(.headline)
                                Text("\(remote.user)@\(remote.host)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            TapButton("Test connection") { machines.testConnection(remote) }
                                .foregroundStyle(Theme.ink)
                            TapButton(action: { prepareRemoval(remote) }) {
                                Image(systemName: "trash")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.muted)
                            }
                            .accessibilityLabel("Remove \(remote.name)")
                            .accessibilityHint("Choose whether to retain or delete its local transcript mirror")
                        }
                        if let test = machines.connectionTests[remote.name] {
                            connectionResult(test)
                        }
                        if let status = machines.statuses.first(where: { $0.machine.id == remote.name }) {
                            Text(status.indicator)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Section("Add a host") {
                TextField("Name (for example, mac-studio)", text: $name)
                TextField("Host or Tailscale name", text: $host)
                TextField("SSH user", text: $user)
                HStack {
                    if let validation {
                        Text(validation).font(.footnote).foregroundStyle(.red)
                    }
                    Spacer()
                    TapButton("Add host") {
                        switch machines.addRemote(name: name, host: host, user: user) {
                        case .success:
                            name = ""; host = ""; validation = nil
                        case .failure(let error):
                            validation = error.localizedDescription
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            removal.map { "Remove \($0.remote.name)?" } ?? "Remove host?",
            isPresented: Binding(
                get: { removal != nil },
                set: { if !$0 { removal = nil } }),
            titleVisibility: .visible,
            presenting: removal
        ) { context in
            Button("Remove host only") {
                performRemoval(context.remote, removeLocalMirror: false)
            }
            Button("Remove host + local mirror (\(formattedBytes(context.mirrorBytes)))",
                   role: .destructive) {
                performRemoval(context.remote, removeLocalMirror: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { context in
            Text("The read-only local mirror at \(context.mirrorPath) uses \(formattedBytes(context.mirrorBytes)). Removing the host only retains those local files.")
        }
    }

    @ViewBuilder
    private func connectionResult(_ result: MachineStore.ConnectionTestResult) -> some View {
        switch result.state {
        case .testing:
            Label("Testing…", systemImage: "ellipsis")
                .font(.caption).foregroundStyle(.secondary)
        case .reachable:
            Label("SSH port reachable", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .unreachable:
            Label("SSH port unreachable · \(result.error ?? "no response")",
                  systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        case .unknown:
            Label("SSH port unverified · \(result.error ?? "no result")",
                  systemImage: "questionmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func prepareRemoval(_ remote: RemoteConfig) {
        removal = RemovalContext(
            remote: remote,
            mirrorBytes: machines.mirrorSize(for: remote),
            mirrorPath: machines.mirrorLocation(for: remote)?.path ?? "local mirror")
    }

    private func performRemoval(_ remote: RemoteConfig, removeLocalMirror: Bool) {
        removal = nil
        if case .failure(let error) = machines.removeRemote(
            remote, removeLocalMirror: removeLocalMirror) {
            validation = error.localizedDescription
        } else {
            validation = nil
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
            countStyle: .file)
    }
}

private struct AboutSettings: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "development build"
    }

    var body: some View {
        VStack(spacing: Theme.sectionGap) {
            Image(nsImage: AppBrand.appIcon())
                .resizable()
                .frame(width: 64, height: 64)
            Text("Trifola")
                .font(.title2.weight(.semibold))
            Text("Version \(version)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("MIT License")
            Text("An independent project — not affiliated with Anthropic.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
