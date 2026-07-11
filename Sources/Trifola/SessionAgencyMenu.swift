import SwiftUI
import TrifolaKit

/// The same agency controls on every session-bearing surface. Keeping the menu in
/// one view prevents Fleet, Sessions, and Attention from drifting semantically.
struct SessionAgencyMenu: View {
    @EnvironmentObject var services: AppServices
    let session: SessionSummary
    var includesOpenTerminal = false

    var body: some View {
        let now = services.now
        let state = services.agency.suppressionState
        let snoozed = state.isSnoozed(sessionID: session.id, at: now)
        let muted = state.isMuted(projectKey: session.project)
        let defaultMinutes = services.preferences.value.defaultSnoozeDurationMinutes

        Group {
            if includesOpenTerminal {
                Button(session.provider == .codex ? "Show transcript" : "Open terminal") {
                    services.openTerminal(session)
                }
                Divider()
            }
            if snoozed {
                Button("Un-snooze") {
                    services.agency.perform(.unsnooze(sessionID: session.id), now: now)
                }
            } else {
                Button("Snooze 1h") {
                    services.agency.snoozeOneHour(session, now: now)
                }
                if defaultMinutes != 60 {
                    Button("Snooze default (\(formatSnoozeDuration(defaultMinutes)))") {
                        services.agency.snooze(
                            session,
                            until: now.addingTimeInterval(TimeInterval(defaultMinutes * 60)),
                            now: now)
                    }
                }
                Button("Snooze until tomorrow") {
                    services.agency.snooze(
                        session,
                        until: AttentionSuppressionReducer.startOfTomorrow(after: now),
                        now: now)
                }
            }
            if muted {
                Button("Unmute project") {
                    services.agency.perform(.unmute(projectKey: session.project), now: now)
                }
            } else {
                Button("Mute project") {
                    services.agency.perform(.mute(projectKey: session.project), now: now)
                }
            }
        }
    }
}

func formatSnoozeDuration(_ minutes: Int) -> String {
    if minutes % 60 == 0 { return "\(minutes / 60)h" }
    return "\(minutes)m"
}

struct SuppressionMark: View {
    var body: some View {
        Image(systemName: "bell.slash")
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.faint)
            .help("Snoozed or muted — still visible, excluded from alerts")
    }
}
