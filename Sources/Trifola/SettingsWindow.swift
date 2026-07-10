import SwiftUI
import TrifolaKit

@MainActor
final class AppPreferencesModel: ObservableObject {
    @Published var value: AppPreferences {
        didSet {
            guard value != oldValue else { return }
            store.save(value)
        }
    }

    private let store: AppPreferencesStore

    init(store: AppPreferencesStore = AppPreferencesStore()) {
        self.store = store
        self.value = store.load()
    }
}

/// A standard macOS Settings surface. It observes only low-frequency preference,
/// notification, and machine-config objects — never the session/fleet services.
struct TrifolaSettingsView: View {
    @ObservedObject var menuPresence: MenuBarPresence
    @ObservedObject var notifier: BlockedNotifierService
    @ObservedObject var preferences: AppPreferencesModel
    @ObservedObject var machines: MachineStore

    var body: some View {
        TabView {
            GeneralSettings(menuPresence: menuPresence)
                .tabItem { Label("General", systemImage: "gear") }
            AttentionSettings(notifier: notifier, preferences: preferences)
                .tabItem { Label("Attention", systemImage: "bell") }
            MachineSettings(machines: machines)
                .tabItem { Label("Machines", systemImage: "desktopcomputer") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 430)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var menuPresence: MenuBarPresence
    private let location = ClaudeConfigLocation.resolve()

    var body: some View {
        Form {
            Toggle("Show the menu-bar strip", isOn: menuPresence.boundEnabled)
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
        }
        .formStyle(.grouped)
    }
}

private struct AttentionSettings: View {
    @ObservedObject var notifier: BlockedNotifierService
    @ObservedObject var preferences: AppPreferencesModel

    var body: some View {
        Form {
            Toggle("Notify when a session becomes blocked", isOn: Binding(
                get: { notifier.enabled }, set: { notifier.enabled = $0 }))
            Text("Notifications are opt-in. The attention strip and menu-bar signal remain visible either way.")
                .font(.footnote).foregroundStyle(.secondary)

            Toggle("Quiet hours", isOn: preferenceBinding(
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
    @ObservedObject var machines: MachineStore
    @State private var name = ""
    @State private var host = ""
    @State private var user = NSUserName()
    @State private var validation: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "flask").foregroundStyle(.orange)
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
                            Button("Test connection") { machines.testConnection(remote) }
                            Button(role: .destructive) { machines.removeRemote(remote) } label: {
                                Image(systemName: "trash")
                            }
                        }
                        if let test = machines.connectionTests[remote.name] {
                            connectionResult(test)
                        }
                    }
                }
            }

            Section("Add a host") {
                TextField("Name (for example, devcube)", text: $name)
                TextField("Host or Tailscale name", text: $host)
                TextField("SSH user", text: $user)
                HStack {
                    if let validation {
                        Text(validation).font(.footnote).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Add host") {
                        if machines.addRemote(name: name, host: host, user: user) {
                            name = ""; host = ""; validation = nil
                        } else {
                            validation = "Enter unique, non-empty host details."
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func connectionResult(_ result: MachineStore.ConnectionTestResult) -> some View {
        switch result.state {
        case .testing:
            Label("Testing…", systemImage: "ellipsis")
                .font(.caption).foregroundStyle(.secondary)
        case .reachable:
            Label("Reachable", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .unreachable:
            Label("Unreachable · \(result.error ?? "no response")",
                  systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }
}

private struct AboutSettings: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "development build"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: AppBrand.markImage(size: 48, state: .running, template: false))
            Text("Trifola").font(.title2.weight(.semibold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("MIT License")
            Text("An independent project — not affiliated with Anthropic.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
