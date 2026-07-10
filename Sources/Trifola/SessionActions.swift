import SwiftUI
import AppKit
import TrifolaKit

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
