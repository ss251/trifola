import SwiftUI
import AppKit
import TrifolaKit

/// WHY a session's primary action is transcript-only. Three different truths
/// used to share one unexplained label, so by-design behavior (a Codex row, a
/// session that simply is not running) read as breakage.
enum TranscriptOnlyReason: Equatable {
    case codexSession
    case remoteSession
    case notRunning
    case headless
    case unresolvable
}

enum SessionOpenActionPresentation: Equatable {
    case resolving
    case iTerm2
    case terminal
    case transcript(TranscriptOnlyReason)
    case session

    init(resolution: TerminalLinkResolution) {
        switch resolution {
        case .target(let target):
            switch target.ownerApplication {
            case .iTerm2?: self = .iTerm2
            case .terminal?: self = .terminal
            case .ghostty?, .other?: self = .session
            case nil: self = .transcript(.headless)
            }
        case .notLive:
            self = .transcript(.notRunning)
        case .ambiguous, .failed:
            self = .transcript(.unresolvable)
        }
    }

    var label: String {
        switch self {
        case .resolving: return "Checking terminal…"
        case .iTerm2: return "Open in iTerm2"
        case .terminal: return "Open Terminal"
        case .transcript: return "Show transcript"
        case .session: return "Open session"
        }
    }

    /// Short visible reason rendered beside the action when it is
    /// transcript-only — the tooltip alone was too discoverable-hostile.
    var caption: String? {
        switch self {
        case .transcript(.codexSession):
            return "Codex session — workspace jump isn't supported yet"
        case .transcript(.remoteSession):
            return "Remote session"
        case .transcript(.notRunning):
            return "Not running — no live terminal"
        case .transcript(.headless):
            return "Runs headless — no terminal window"
        case .transcript(.unresolvable):
            return "No confident terminal match"
        case .resolving, .iTerm2, .terminal, .session:
            return nil
        }
    }

    var icon: String {
        switch self {
        case .resolving: "ellipsis.circle"
        case .transcript: "doc.text"
        case .iTerm2, .terminal, .session: "terminal"
        }
    }

    var help: String {
        switch self {
        case .resolving:
            return "Checking the live session registry and terminal process"
        case .iTerm2:
            return "Bring this exact live iTerm2 session forward; show its transcript if unavailable"
        case .terminal:
            return "Bring this exact live Terminal session forward; show its transcript if unavailable"
        case .transcript(let reason):
            let base = "Show this session's local read-only transcript"
            switch reason {
            case .codexSession:
                return base + " — Codex threads can't be joined to the Claude live registry yet, so jumping to a terminal could target the wrong one"
            case .remoteSession:
                return base + " — this session runs on another machine"
            case .notRunning:
                return base + " — the session has no live process to jump to"
            case .headless:
                return base + " — the live process has no terminal window"
            case .unresolvable:
                return base + " — no single live terminal could be confidently matched"
            }
        case .session:
            return "Jump to this exact workspace when Accessibility is granted and a confident match exists; otherwise bring the owning terminal app forward"
        }
    }
}

/// The action cluster attached to every session: copy the `claude --resume`
/// one-liner, reveal the transcript in Finder.
struct SessionActions: View {
    let session: SessionSummary
    var compact = false

    @State private var feedback: String? = nil
    @State private var feedbackDismissTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            QuietTapButton(action: {
                let cmd = SessionResume.command(sessionID: session.id, cwd: session.cwd)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
                flash("Resume command copied")
            }) {
                Label(compact ? "Copy" : "Copy resume", systemImage: "doc.on.doc")
                    .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            }
            .accessibilityLabel("Copy resume command")
            .accessibilityHint("Copy the claude resume command for this session")
            .help("Copy `claude --resume \(session.shortID)…` to the clipboard")

            if !compact {
                QuietTapButton(action: {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: session.filePath)])
                }) {
                    Label("Reveal", systemImage: "folder")
                }
                .help("Reveal the transcript .jsonl in Finder")
            }
        }
        .overlay(alignment: .top) {
            if let feedback {
                Toast(text: feedback)
                    .offset(y: -44)
                    .allowsHitTesting(false)
            }
        }
        .motion(Theme.Motion.move, value: feedback)
        .onDisappear { feedbackDismissTask?.cancel() }
    }

    private func flash(_ text: String) {
        feedback = text
        feedbackDismissTask?.cancel()
        feedbackDismissTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            feedback = nil
        }
    }
}

/// Type-erased label style so we can switch styles with a ternary.
struct AnyLabelStyle: LabelStyle {
    private let _makeBody: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) {
        _makeBody = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View {
        _makeBody(configuration)
    }
}
