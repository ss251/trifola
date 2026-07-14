import Combine
import SwiftUI
import TrifolaKit

@MainActor
final class AutomationAccessCoordinator: ObservableObject {
    struct Prompt: Identifiable, Equatable {
        let id: UUID
        let terminalName: String
    }

    @Published private(set) var pendingPrompt: Prompt?

    private let sessionGate: PermissionFlowSessionGate
    private var continuation: CheckedContinuation<TerminalAutomationPreparation, Never>?

    init(sessionGate: PermissionFlowSessionGate) {
        self.sessionGate = sessionGate
    }

    func prepare(
        terminalName: String,
        hasSeenPrimer: Bool
    ) async -> TerminalAutomationPreparation {
        guard !Task.isCancelled else { return .cancelled }
        if hasSeenPrimer { return .proceed }
        guard sessionGate.claim(.automation) else { return .deferToActivation }

        cancelPendingPrompt()
        let requestID = UUID()
        let cleanName = terminalName.trimmingCharacters(in: .whitespacesAndNewlines)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                self.continuation = continuation
                self.pendingPrompt = Prompt(
                    id: requestID,
                    terminalName: cleanName.isEmpty ? "your terminal" : cleanName)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingPrompt(id: requestID)
            }
        }
    }

    func resolvePrompt(with action: TerminalAutomationPreparation) {
        guard continuation != nil else { return }
        let continuation = continuation
        self.continuation = nil
        pendingPrompt = nil
        continuation?.resume(returning: action)
    }

    func cancelPendingPrompt() {
        cancelPendingPrompt(id: nil)
    }

    private func cancelPendingPrompt(id: UUID?) {
        if let id, pendingPrompt?.id != id { return }
        let continuation = continuation
        self.continuation = nil
        pendingPrompt = nil
        continuation?.resume(returning: .cancelled)
    }
}

enum OnboardingStage: Equatable {
    case welcome(ProviderCorpusPresence)
    case automation(terminalName: String)
}

/// One branded panel primitive powers both live first-run beats and the
/// `--render-onboarding` evidence surface. It intentionally resembles Trifola,
/// not a macOS permission alert.
struct OnboardingOverlay: View {
    let stage: OnboardingStage
    var continueAction: () -> Void = {}
    var deferAction: (() -> Void)?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Theme.ink.opacity(reduceTransparency ? 0.24 : 0.14)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            panel
                .frame(width: 460)
                .padding(Theme.gutter)
        }
        .accessibilityElement(children: .contain)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Theme.blockGap) {
            HStack(alignment: .top, spacing: Theme.sectionGap) {
                BrandMark(state: .idle, size: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.micro) {
                    Text(eyebrow)
                        .font(Theme.Typography.metadataMedium)
                        .foregroundStyle(Theme.accent)
                        .textCase(.uppercase)
                    Text(title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.ink)
                }
            }

            VStack(alignment: .leading, spacing: Theme.sectionGap) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    OnboardingMessage(
                        symbol: message.symbol,
                        title: message.title,
                        detail: message.detail)
                }
            }

            HStack(spacing: Theme.intraCell) {
                if let deferAction {
                    QuietTapButton("Not now", size: .regular, action: deferAction)
                }
                Spacer()
                ProminentTapButton("Continue", size: .large, action: continueAction)
                    .accessibilityHint(continueHint)
            }
        }
        .padding(Theme.gutter)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusOverlay, style: .continuous)
                .fill(Theme.surfaceWindow)
            RoundedRectangle(cornerRadius: Theme.radiusOverlay, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 28, y: 14)
    }

    private var eyebrow: String {
        switch stage {
        case .welcome: "Welcome to Trifola"
        case .automation: "Exact terminal jump"
        }
    }

    private var title: String {
        switch stage {
        case .welcome: "Your fleet is already here"
        case .automation: "Jump straight to the right tab?"
        }
    }

    private var continueHint: String {
        switch stage {
        case .welcome: "Dismiss this welcome and keep using the live board"
        case .automation:
            "Continue to the real macOS Automation permission when it is needed"
        }
    }

    private var messages: [(symbol: String, title: String, detail: String)] {
        switch stage {
        case .welcome(let presence):
            let copy = FirstLaunchWelcomeCopy(corpusPresence: presence)
            return [
                ("externaldrive", "Local paths", copy.reads),
                ("eye", "Read-only", "Sessions, costs, and attention are already live on the board behind this panel."),
                ("lock.shield", "Stays on this Mac", FirstLaunchWelcomeCopy.never),
            ]
        case .automation(let terminalName):
            let copy = TerminalAutomationPrimerCopy(terminalName: terminalName)
            return [
                ("arrow.up.forward.app", "Why Trifola asks", copy.reason),
                ("hand.raised", "You stay in control", copy.denialFallback),
            ]
        }
    }
}

private struct OnboardingMessage: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.sectionGap) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.accent.opacity(0.10)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct OnboardingPresentationHost: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var automationAccess: AutomationAccessCoordinator

    var body: some View {
        OnboardingPresenter(
            corpusPresence: services.providerCorpusPresence,
            preferences: services.preferences,
            automationAccess: automationAccess,
            completeWelcome: services.completeFirstLaunchWelcome)
    }
}

private struct OnboardingPresenter: View {
    let corpusPresence: ProviderCorpusPresence
    @ObservedObject var preferences: AppPreferencesModel
    @ObservedObject var automationAccess: AutomationAccessCoordinator
    let completeWelcome: () -> Void

    var body: some View {
        ZStack {
            if FirstLaunchOnboardingPolicy.shouldPresentWelcome(
                corpusPresence: corpusPresence,
                hasCompletedWelcome: preferences.value
                    .hasCompletedFirstLaunchWelcome) {
                OnboardingOverlay(
                    stage: .welcome(corpusPresence),
                    continueAction: completeWelcome)
            } else if let prompt = automationAccess.pendingPrompt {
                OnboardingOverlay(
                    stage: .automation(terminalName: prompt.terminalName),
                    continueAction: {
                        automationAccess.resolvePrompt(with: .proceed)
                    },
                    deferAction: {
                        automationAccess.resolvePrompt(with: .deferToActivation)
                    })
            }
        }
    }
}
