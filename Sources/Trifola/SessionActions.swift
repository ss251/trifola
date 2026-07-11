import SwiftUI
import AppKit
import TrifolaKit

enum SessionOpenActionPresentation: Equatable {
    case resolving
    case iTerm2
    case terminal
    case transcript
    case session

    init(resolution: TerminalLinkResolution) {
        switch resolution {
        case .target(let target):
            switch target.ownerApplication {
            case .iTerm2?: self = .iTerm2
            case .terminal?: self = .terminal
            case .ghostty?, .other?: self = .session
            case nil: self = .transcript
            }
        case .notLive, .ambiguous, .failed:
            self = .transcript
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
        case .transcript:
            return "Show this session's local read-only transcript"
        case .session:
            return "Open the terminal app that owns this session; show its transcript if unavailable"
        }
    }
}

/// The action cluster attached to every session: copy the `claude --resume`
/// one-liner, reveal the transcript in Finder.
struct SessionActions: View {
    let session: SessionSummary
    var compact = false

    @State private var feedback: String? = nil

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
                    .id(feedback)
                    .offset(y: -44)
                    .allowsHitTesting(false)
            }
        }
        .motion(Theme.Motion.move, value: feedback)
    }

    private func flash(_ text: String) {
        feedback = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
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
