import AppKit
import ApplicationServices
import Foundation
import TrifolaKit

/// Generic Accessibility workspace targeting for terminal owners that do not
/// expose an exact scripting interface. The adapter never triggers a TCC prompt:
/// `AXIsProcessTrusted()` is the only trust query, and the injected handler owns
/// the optional at-value explainer.
@MainActor
final class AccessibilityWorkspaceTargeter: WorkspaceTargeting {
    typealias PermissionHandler = @MainActor @Sendable (String) async -> WorkspaceAccessAction

    private let permissionHandler: PermissionHandler

    init(permissionHandler: @escaping PermissionHandler) {
        self.permissionHandler = permissionHandler
    }

    func target(_ request: WorkspaceTargetRequest) async -> WorkspaceTargetResult {
        guard !Task.isCancelled else { return .notFound }
        guard let ownerPID = request.target.ownerProcessID else { return .notFound }
        Self.diagnostic(
            "start pid=\(ownerPID)"
            + " app=\(request.target.ownerApplication?.displayName ?? "unknown")")

        if !AXIsProcessTrusted() {
            Self.diagnostic("permission missing")
            let terminalName = request.target.ownerApplication?.displayName
                ?? "your terminal"
            switch await permissionHandler(terminalName) {
            case .retryTargeting:
                // Exactly one fresh, non-prompting check after the user-owned
                // explainer flow. There is no polling loop.
                guard AXIsProcessTrusted() else {
                    return .permissionDenied(.accessibility)
                }
            case .settingsOpened:
                return .settingsOpened
            case .settingsOpenFailed:
                return .settingsOpenFailed
            case .notNow:
                return .permissionDenied(.accessibility)
            case .cancelled:
                // TerminalLaunchFlow checks cancellation immediately after this
                // await and turns the superseded operation into `.cancelled`.
                return Task.isCancelled
                    ? .notFound : .permissionDenied(.accessibility)
            }
        }

        guard !Task.isCancelled else { return .notFound }
        let bundledControlEndpoint = BundledWorkspaceController.endpoint(
            ownerProcessID: ownerPID)
        Self.diagnostic("dispatch=worker")
        return await AXWorkspaceWorker.shared.target(
            request,
            bundledControlEndpoint: bundledControlEndpoint)
    }

    func verify(
        _ request: WorkspaceTargetRequest,
        matchedTitle: String
    ) async -> WorkspaceTargetVerification {
        guard !Task.isCancelled else { return .unavailable }
        return await AXWorkspaceWorker.shared.verify(
            request, matchedTitle: matchedTitle)
    }

    fileprivate nonisolated static func diagnostic(_ message: String) {
        guard ProcessInfo.processInfo.environment["TRIFOLA_AX_DIAGNOSTICS"] == "1"
        else { return }
        FileHandle.standardError.write(Data("[workspace-ax] \(message)\n".utf8))
    }

    /// The verified sidebar's inactive rows do not expose a working AXPress,
    /// so its bounded pointer fallback must run only after the owning app is
    /// actually foreground. Permission denial never reaches this helper.
    fileprivate static func foregroundOwnerForPointer(_ pid: Int32) async -> Bool {
        guard let application = NSRunningApplication(
            processIdentifier: pid_t(pid)) else { return false }
        if application.isActive { return true }
        diagnostic("pointer=foreground-request")
        NSApp.yieldActivation(to: application)
        let accepted = application.activate(
            from: NSRunningApplication.current,
            options: [.activateAllWindows])
            || application.activate(options: [.activateAllWindows])
        guard accepted else {
            diagnostic("pointer=foreground-rejected")
            return false
        }
        for _ in 0..<10 {
            guard !Task.isCancelled else { return false }
            if application.isActive {
                diagnostic("pointer=foreground-confirmed")
                do {
                    // `isActive` flips before the target window necessarily
                    // finishes ordering above Trifola. Let one bounded AppKit
                    // settle elapse so the point click cannot hit our window.
                    try await Task.sleep(for: .milliseconds(100))
                    return !Task.isCancelled && application.isActive
                } catch {
                    return false
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        diagnostic("pointer=foreground-unverified")
        return application.isActive
    }
}

/// Serializes all AX discovery/selection work away from SwiftUI's main actor.
/// AX calls can block until their per-element messaging timeout, so this actor
/// is also the cancellation boundary for superseded Open-session attempts.
private actor AXWorkspaceWorker {
    static let shared = AXWorkspaceWorker()

    private struct PendingVerification {
        let ownerPID: Int32
        let sessionID: String
        let matchedTitle: String
        let allowsObservedStatusMarker: Bool
        let expectedWindow: AXUIElement?
        let bundledControlEndpoint: BundledWorkspaceEndpoint?
        let bundledControlSelection: BundledWorkspaceSelection?
        var bundledSurfaceSelection: BundledSurfaceSelection? = nil
        let allowsBundledControlFallback: Bool
    }

    private var pendingVerification: PendingVerification?

    func target(
        _ request: WorkspaceTargetRequest,
        bundledControlEndpoint: BundledWorkspaceEndpoint?
    ) async -> WorkspaceTargetResult {
        AccessibilityWorkspaceTargeter.diagnostic("worker=entered")
        guard !Task.isCancelled,
              let ownerPID = request.target.ownerProcessID else { return .notFound }
        pendingVerification = nil

        // Surface-exact tier: the host's own surface (tab) records can carry
        // the EXACT session id they resume — stronger than any title or PID
        // inference, immune to renames, and tab-precise. Attempt it before
        // any AX work; every gate inside is capability-shaped and fail-closed.
        if let bundledControlEndpoint, !Task.isCancelled,
           let surface = BundledWorkspaceController.selectSurface(
               endpoint: bundledControlEndpoint,
               sessionID: request.identity.sessionID) {
            AccessibilityWorkspaceTargeter.diagnostic(
                "bundled-surface=selected title=\(surface.target.title)")
            pendingVerification = PendingVerification(
                ownerPID: ownerPID,
                sessionID: request.identity.sessionID,
                matchedTitle: surface.target.title,
                allowsObservedStatusMarker: true,
                expectedWindow: nil,
                bundledControlEndpoint: bundledControlEndpoint,
                bundledControlSelection: nil,
                bundledSurfaceSelection: surface,
                allowsBundledControlFallback: false)
            return .targeted(matchedTitle: surface.target.title)
        }

        let application = AXUIElementCreateApplication(pid_t(ownerPID))
        AXWorkspaceTree.prepare(application)

        var roleValue: CFTypeRef?
        let readiness = AXUIElementCopyAttributeValue(
            application, kAXRoleAttribute as CFString, &roleValue)
        if readiness == .apiDisabled {
            return .permissionDenied(.accessibility)
        }
        if readiness == .notImplemented {
            return .failed(.accessibility(
                "The owning application does not support Accessibility targeting"))
        }
        guard readiness == .success else {
            return .failed(.accessibility(
                "Accessibility tree unavailable (AX error \(readiness.rawValue))"))
        }

        let traversal = AXWorkspaceTree.read(
            application: application,
            bounds: .init(maxDepth: 8, maxNodes: 1_500, maxDuration: 0.75))
        AccessibilityWorkspaceTargeter.diagnostic(
            "traversal nodes=\(traversal.nodes.count)"
            + " nodeLimit=\(traversal.hitNodeLimit)"
            + " timeLimit=\(traversal.hitTimeLimit)"
            + " depthLimit=\(traversal.hitDepthLimit)"
            + " readFailure=\(traversal.hitReadFailure)"
            + " ignoredInvalid=\(traversal.ignoredInvalidElementCount)"
            + " shallowReadDepth=\(String(describing: traversal.shallowestReadFailureDepth))"
            + " pendingDepth=\(String(describing: traversal.minimumUnvisitedDepth))")
        guard !Task.isCancelled else { return .notFound }
        let discovery = AXWorkspaceTree.candidateRecords(from: traversal.nodes)
        let genericComplete = WorkspaceAXSafetyPolicy.genericTraversalIsComplete(
            hitNodeLimit: traversal.hitNodeLimit,
            hitTimeLimit: traversal.hitTimeLimit,
            hitDepthLimit: traversal.hitDepthLimit,
            hitReadFailure: traversal.hitReadFailure
                || discovery.hitGenericReadFailure)
        let refinedComplete = !discovery.malformedRefinedSurface
            && !discovery.refinedRecords.isEmpty
            && WorkspaceAXSafetyPolicy.scopedSurfaceTraversalIsComplete(
                surfaceDepth: WorkspaceSidebarRefinementPolicy.expectedDepth,
                shallowestReadFailureDepth:
                    traversal.shallowestReadFailureDepth,
                minimumUnvisitedDepth: traversal.minimumUnvisitedDepth)
        let records: [AXCandidateRecord]
        if genericComplete && !discovery.malformedRefinedSurface {
            records = discovery.genericRecords + discovery.refinedRecords
        } else if refinedComplete {
            records = discovery.refinedRecords
        } else {
            AccessibilityWorkspaceTargeter.diagnostic(
                "selection=refused-incomplete-tree")
            return .noConfidentMatch
        }
        AccessibilityWorkspaceTargeter.diagnostic(
            "candidates=\(records.count)"
            + " genericComplete=\(genericComplete)"
            + " refinedComplete=\(refinedComplete)")
        guard !records.isEmpty else { return .notFound }
        let selection = WorkspaceCandidateScorer.select(
            from: records.map(\.candidate), for: request.identity)
        guard case .matched(let match) = selection,
              let record = records.first(where: {
                  $0.candidate.id == match.candidate.id
              }),
              let rawTitle = match.candidate.confirmationTitle else {
            // Workspace names are arbitrary (they needn't resemble a session's
            // cwd/project), so a title miss is the COMMON case in workspace
            // apps — and exactly where the PID join is strongest: the live
            // session PID maps to one workspace UUID with the same signature,
            // capability, uniqueness, and post-condition gates. Only attempt
            // it against a fully-enumerated workspace surface.
            if refinedComplete, let bundledControlEndpoint, !Task.isCancelled {
                AccessibilityWorkspaceTargeter.diagnostic(
                    "bundled-control=pid-only-attempt")
                if let selection = BundledWorkspaceController.select(
                    endpoint: bundledControlEndpoint,
                    sessionProcessID: request.target.processID,
                    matchedTitle: nil) {
                    let title = selection.target.matchedTitle
                    AccessibilityWorkspaceTargeter.diagnostic(
                        "bundled-control=pid-only-selected title=\(title)")
                    pendingVerification = PendingVerification(
                        ownerPID: ownerPID,
                        sessionID: request.identity.sessionID,
                        matchedTitle: title,
                        allowsObservedStatusMarker: true,
                        expectedWindow: nil,
                        bundledControlEndpoint: bundledControlEndpoint,
                        bundledControlSelection: selection,
                        allowsBundledControlFallback: true)
                    return .targeted(matchedTitle: title)
                }
                AccessibilityWorkspaceTargeter.diagnostic(
                    "bundled-control=pid-only-failed")
            }
            AccessibilityWorkspaceTargeter.diagnostic(
                "selection=no-confident-match")
            return .noConfidentMatch
        }

        let matchedTitle = AXWorkspaceTree.cleanedConfirmationTitle(rawTitle)
        guard !matchedTitle.isEmpty, !Task.isCancelled else {
            return .noConfidentMatch
        }
        AccessibilityWorkspaceTargeter.diagnostic(
            "selection title=\(matchedTitle) score=\(match.score)"
            + " evidence=\(match.evidence.map(\.rawValue).joined(separator: ","))")
        let allowsBundledControlFallback: Bool
        var actuation: AXActuationResult?
        switch record.activationKind {
        case .accessibilityAction:
            allowsBundledControlFallback = false
            actuation = AXWorkspaceTree.actuate(record, ownerPID: ownerPID)
        case .shapeScopedPointer:
            allowsBundledControlFallback = true
            if await AccessibilityWorkspaceTargeter
                .foregroundOwnerForPointer(ownerPID) {
                guard !Task.isCancelled else { return .notFound }
                actuation = AXWorkspaceTree.actuate(
                    record, ownerPID: ownerPID)
            } else {
                AccessibilityWorkspaceTargeter.diagnostic(
                    "pointer=foreground-unavailable")
            }
        }
        AccessibilityWorkspaceTargeter.diagnostic(
            "actuation selected=\(actuation?.didSelect ?? false)"
            + " raised=\(actuation?.didRaise ?? false)")

        var bundledSelection: BundledWorkspaceSelection?
        if actuation?.didSelect != true,
           allowsBundledControlFallback,
           let bundledControlEndpoint {
            AccessibilityWorkspaceTargeter.diagnostic(
                "bundled-control=attempt")
            bundledSelection = BundledWorkspaceController.select(
                endpoint: bundledControlEndpoint,
                sessionProcessID: request.target.processID,
                matchedTitle: matchedTitle)
            AccessibilityWorkspaceTargeter.diagnostic(
                "bundled-control=\(bundledSelection == nil ? "failed" : "selected")")
        }
        guard actuation?.didSelect == true || bundledSelection != nil else {
            return .failed(.accessibility(
                "Matched workspace could not be activated through its verified Accessibility or bundled control surface"))
        }
        pendingVerification = PendingVerification(
            ownerPID: ownerPID,
            sessionID: request.identity.sessionID,
            matchedTitle: matchedTitle,
            allowsObservedStatusMarker:
                record.allowsObservedStatusMarker,
            expectedWindow: record.window,
            bundledControlEndpoint: bundledControlEndpoint,
            bundledControlSelection: bundledSelection,
            allowsBundledControlFallback: allowsBundledControlFallback)
        return .targeted(matchedTitle: matchedTitle)
    }

    func verify(
        _ request: WorkspaceTargetRequest,
        matchedTitle: String
    ) -> WorkspaceTargetVerification {
        guard let ownerPID = request.target.ownerProcessID else {
            return .unavailable
        }
        guard let pendingVerification,
              pendingVerification.ownerPID == ownerPID,
              pendingVerification.sessionID == request.identity.sessionID,
              pendingVerification.matchedTitle == matchedTitle else {
            return .unavailable
        }
        self.pendingVerification = nil
        let application = AXUIElementCreateApplication(pid_t(ownerPID))
        AXWorkspaceTree.prepare(application)
        if let surfaceSelection = pendingVerification.bundledSurfaceSelection {
            return verifySurfaceSelection(
                surfaceSelection,
                application: application,
                pending: pendingVerification)
        }
        if let bundledSelection = pendingVerification
            .bundledControlSelection {
            return verifyBundledSelection(
                bundledSelection,
                application: application,
                pending: pendingVerification)
        }

        var observedMismatch = false
        for attempt in 0..<10 {
            guard !Task.isCancelled else { return .unavailable }
            switch AXWorkspaceTree.verifyFocusedTitle(
                application: application,
                matchedTitle: matchedTitle,
                allowsObservedStatusMarker:
                    pendingVerification.allowsObservedStatusMarker,
                expectedWindow: pendingVerification.expectedWindow) {
            case .verified:
                AccessibilityWorkspaceTargeter.diagnostic(
                    "verification=verified")
                return .verified
            case .failed:
                observedMismatch = true
            case .unavailable:
                break
            }
            if attempt < 9 { Thread.sleep(forTimeInterval: 0.05) }
        }
        if pendingVerification.allowsBundledControlFallback,
           let endpoint = pendingVerification.bundledControlEndpoint,
           !Task.isCancelled {
            AccessibilityWorkspaceTargeter.diagnostic(
                "bundled-control=verification-fallback")
            if let selection = BundledWorkspaceController.select(
                endpoint: endpoint,
                sessionProcessID: request.target.processID,
                matchedTitle: matchedTitle) {
                return verifyBundledSelection(
                    selection,
                    application: application,
                    pending: pendingVerification)
            }
        }
        AccessibilityWorkspaceTargeter.diagnostic(
            "verification=\(observedMismatch ? "failed" : "unavailable")")
        return observedMismatch
            ? .failed("AX post-condition did not confirm the matched workspace")
            : .unavailable
    }

    private func verifySurfaceSelection(
        _ selection: BundledSurfaceSelection,
        application: AXUIElement,
        pending: PendingVerification
    ) -> WorkspaceTargetVerification {
        guard !Task.isCancelled,
              BundledWorkspaceController.verifySurface(selection) else {
            AccessibilityWorkspaceTargeter.diagnostic(
                "bundled-surface=post-condition-failed")
            return .failed(
                "Bundled surface control did not confirm the exact tab and workspace")
        }
        // The host's own current-surface read is the authoritative post-
        // condition at tab depth: it names the exact surface AND workspace
        // UUIDs through the same signature-gated channel that performed the
        // focus. The workspace tier's AX window-title equality is NOT a valid
        // invariant here — a window is titled by its workspace, never by the
        // tab — and requiring it downgraded real successes (live finding:
        // tab focused, host verified, toast claimed failure). The focused
        // title is still read once as pure diagnostics.
        switch AXWorkspaceTree.verifyFocusedTitle(
            application: application,
            matchedTitle: pending.matchedTitle,
            allowsObservedStatusMarker: pending.allowsObservedStatusMarker,
            expectedWindow: nil) {
        case .verified:
            AccessibilityWorkspaceTargeter.diagnostic("bundled-surface=ax-title-agrees")
        case .failed:
            AccessibilityWorkspaceTargeter.diagnostic(
                "bundled-surface=ax-title-differs (window is workspace-titled; informational)")
        case .unavailable:
            AccessibilityWorkspaceTargeter.diagnostic("bundled-surface=ax-title-unavailable")
        }
        AccessibilityWorkspaceTargeter.diagnostic("bundled-surface=verified")
        return .verified
    }

    private func verifyBundledSelection(
        _ selection: BundledWorkspaceSelection,
        application: AXUIElement,
        pending: PendingVerification
    ) -> WorkspaceTargetVerification {
        guard !Task.isCancelled,
              BundledWorkspaceController.verify(selection) else {
            AccessibilityWorkspaceTargeter.diagnostic(
                "bundled-control=post-condition-failed")
            return .failed(
                "Bundled workspace control did not confirm the exact window and workspace")
        }

        var observedMismatch = false
        for attempt in 0..<10 {
            guard !Task.isCancelled else { return .unavailable }
            switch AXWorkspaceTree.verifyFocusedTitle(
                application: application,
                matchedTitle: pending.matchedTitle,
                allowsObservedStatusMarker:
                    pending.allowsObservedStatusMarker,
                expectedWindow: nil) {
            case .verified:
                AccessibilityWorkspaceTargeter.diagnostic(
                    "bundled-control=verified")
                return .verified
            case .failed:
                observedMismatch = true
            case .unavailable:
                break
            }
            if attempt < 9 { Thread.sleep(forTimeInterval: 0.05) }
        }
        AccessibilityWorkspaceTargeter.diagnostic(
            "bundled-control=ax-title-"
            + (observedMismatch ? "mismatch" : "unavailable"))
        return observedMismatch
            ? .failed("AX focused-window title did not confirm the selected workspace")
            : .unavailable
    }
}

// MARK: - Bounded AX tree

private struct AXTraversalBounds {
    let maxDepth: Int
    let maxNodes: Int
    let maxDuration: TimeInterval
}

private struct AXNodeRecord {
    let path: String
    let depth: Int
    let element: AXUIElement
    let ancestors: [AXUIElement]
    let ancestorRoles: [String]
    let ancestorIdentifiers: [String?]
    let role: String
    let title: String?
    let label: String?
    let help: String?
    let document: String?
    let identifier: String?
    let directChildCount: Int
    let childrenReadComplete: Bool

    var parentPath: String? {
        guard let separator = path.lastIndex(of: ".") else { return nil }
        return String(path[..<separator])
    }
}

private struct AXCandidateRecord {
    let candidate: WorkspaceCandidate
    let element: AXUIElement
    let window: AXUIElement?
    let identityFingerprint: String
    let activationKind: AXCandidateActivationKind
    let allowsObservedStatusMarker: Bool
    let pointerLocation: CGPoint?
}

private enum AXCandidateActivationKind {
    case accessibilityAction
    case shapeScopedPointer
}

private struct AXTraversalResult {
    let nodes: [AXNodeRecord]
    let hitNodeLimit: Bool
    let hitTimeLimit: Bool
    let hitDepthLimit: Bool
    let hitReadFailure: Bool
    let ignoredInvalidElementCount: Int
    let shallowestReadFailureDepth: Int?
    let minimumUnvisitedDepth: Int?
}

private struct AXCandidateDiscovery {
    let genericRecords: [AXCandidateRecord]
    let refinedRecords: [AXCandidateRecord]
    let hitGenericReadFailure: Bool
    let malformedRefinedSurface: Bool
}

private struct AXTextRead {
    let value: String?
    let hitReadFailure: Bool
    let elementInvalidated: Bool
}

private struct AXElementListRead {
    let elements: [AXUIElement]
    let hitReadFailure: Bool
}

private struct AXSelectionSupport {
    let isSupported: Bool
    let hitReadFailure: Bool
}

private struct AXActuationResult {
    let didSelect: Bool
    let didRaise: Bool
    let actedElement: AXUIElement?
}

private enum AXVerification: Equatable {
    case verified
    case failed
    case unavailable
}

private enum AXWorkspaceTree {
    /// Observed multi-workspace sidebar shape in v0.64.17. The identifier is
    /// stable while its label carries a leading status glyph and a positional
    /// suffix, so only that generic presentation noise is removed.
    private static let genericChildAttributes: [String] = [
        kAXChildrenAttribute,
        kAXRowsAttribute,
        kAXTabsAttribute,
        kAXContentsAttribute,
    ]
    private static let excludedSubtreeRoles: Set<String> = [
        kAXMenuBarRole,
        kAXMenuRole,
        kAXMenuItemRole,
    ]
    static func prepare(_ element: AXUIElement) {
        // The SDK applies this timeout to one AX object only, not descendants.
        // Every helper calls `prepare` before messaging the specific element.
        AXUIElementSetMessagingTimeout(element, 0.05)
    }

    static func read(
        application: AXUIElement,
        bounds: AXTraversalBounds
    ) -> AXTraversalResult {
        struct PendingNode {
            let element: AXUIElement
            let depth: Int
            let path: String
            let ancestors: [AXUIElement]
            let ancestorRoles: [String]
            let ancestorIdentifiers: [String?]
        }

        let maximumDepth = min(max(0, bounds.maxDepth), 8)
        let maximumNodes = min(max(1, bounds.maxNodes), 1_500)
        let duration = min(max(0.05, bounds.maxDuration), 0.75)
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(duration * 1_000_000_000)
        var pending = [PendingNode(
            element: application,
            depth: 0,
            path: "0",
            ancestors: [],
            ancestorRoles: [],
            ancestorIdentifiers: [])]
        var cursor = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]
        var nodes: [AXNodeRecord] = []
        nodes.reserveCapacity(min(maximumNodes, 256))
        var hitTimeLimit = false
        var hitDepthLimit = false
        var hitReadFailure = false
        var ignoredInvalidElementCount = 0
        var shallowestReadFailureDepth: Int?
        var minimumDiscardedDepth: Int?

        func recordReadFailure(at depth: Int) {
            hitReadFailure = true
            shallowestReadFailureDepth = min(
                shallowestReadFailureDepth ?? depth, depth)
        }

        while cursor < pending.count, nodes.count < maximumNodes {
            guard !Task.isCancelled else { break }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                hitTimeLimit = true
                break
            }
            let node = pending[cursor]
            cursor += 1
            prepare(node.element)
            let hash = CFHash(node.element)
            // CFHash is only a bucket key: distinct AX elements can legally
            // collide, so confirm actual CF identity before deduplicating.
            if seen[hash]?.contains(where: {
                CFEqual($0, node.element)
            }) == true {
                continue
            }
            seen[hash, default: []].append(node.element)

            let roleRead = textRead(
                kAXRoleAttribute, from: node.element, required: true)
            if roleRead.elementInvalidated {
                // A child can disappear after its parent was enumerated. It is
                // no longer an actionable candidate, so omit that stale leaf;
                // errors from still-live elements continue to fail closed.
                ignoredInvalidElementCount += 1
                continue
            }
            let titleRead = textRead(kAXTitleAttribute, from: node.element)
            let labelRead = textRead(kAXDescriptionAttribute, from: node.element)
            let helpRead = textRead(kAXHelpAttribute, from: node.element)
            let documentRead = textRead(kAXDocumentAttribute, from: node.element)
            let identifierRead = textRead(kAXIdentifierAttribute, from: node.element)
            if roleRead.hitReadFailure
                || titleRead.hitReadFailure
                || labelRead.hitReadFailure
                || helpRead.hitReadFailure
                || documentRead.hitReadFailure
                || identifierRead.hitReadFailure {
                recordReadFailure(at: node.depth)
            }
            let role = roleRead.value ?? "AXUnknown"
            let childRead: AXElementListRead
            if excludedSubtreeRoles.contains(role) {
                // Menus are an intentionally excluded action surface, not an
                // incomplete workspace traversal.
                childRead = AXElementListRead(
                    elements: [],
                    hitReadFailure: false)
            } else {
                childRead = childElements(from: node.element, role: role)
                if childRead.hitReadFailure {
                    recordReadFailure(at: node.depth)
                }
            }
            let record = AXNodeRecord(
                path: node.path,
                depth: node.depth,
                element: node.element,
                ancestors: node.ancestors,
                ancestorRoles: node.ancestorRoles,
                ancestorIdentifiers: node.ancestorIdentifiers,
                role: role,
                title: titleRead.value,
                label: labelRead.value,
                help: helpRead.value,
                document: documentRead.value,
                identifier: identifierRead.value,
                directChildCount: childRead.elements.count,
                childrenReadComplete: !childRead.hitReadFailure)
            nodes.append(record)

            guard node.depth < maximumDepth else {
                if !childRead.elements.isEmpty {
                    hitDepthLimit = true
                    let discardedDepth = node.depth + 1
                    minimumDiscardedDepth = min(
                        minimumDiscardedDepth ?? discardedDepth,
                        discardedDepth)
                }
                continue
            }
            for (childIndex, child) in childRead.elements.enumerated() {
                pending.append(PendingNode(
                    element: child,
                    depth: node.depth + 1,
                    path: "\(node.path).\(childIndex)",
                    ancestors: node.ancestors + [node.element],
                    ancestorRoles: node.ancestorRoles + [role],
                    ancestorIdentifiers: node.ancestorIdentifiers
                        + [identifierRead.value]))
            }
        }

        let minimumPendingDepth = cursor < pending.count
            ? pending[cursor...].map(\.depth).min()
            : nil
        let minimumUnvisitedDepth = [
            minimumPendingDepth,
            minimumDiscardedDepth,
        ].compactMap { $0 }.min()

        return AXTraversalResult(
            nodes: nodes,
            hitNodeLimit: nodes.count >= maximumNodes && cursor < pending.count,
            hitTimeLimit: hitTimeLimit,
            hitDepthLimit: hitDepthLimit,
            hitReadFailure: hitReadFailure,
            ignoredInvalidElementCount: ignoredInvalidElementCount,
            shallowestReadFailureDepth: shallowestReadFailureDepth,
            minimumUnvisitedDepth: minimumUnvisitedDepth)
    }

    static func candidateRecords(from nodes: [AXNodeRecord]) -> AXCandidateDiscovery {
        struct RefinedSeed {
            let node: AXNodeRecord
            let entry: WorkspaceSidebarRefinementPolicy.Entry
            let support: AXSelectionSupport
            let pointerLocation: CGPoint?
        }

        var genericRecords: [AXCandidateRecord] = []
        genericRecords.reserveCapacity(nodes.count)
        var refinedSeeds: [String: [RefinedSeed]] = [:]
        var hitGenericReadFailure = false
        var malformedRefinedSurface = false

        for node in nodes {
            let hasRefinedIdentifier = node.identifier?.hasPrefix(
                WorkspaceSidebarRefinementPolicy.identifierPrefix) == true
            let hasRefinedAncestry =
                WorkspaceSidebarRefinementPolicy.hasObservedAncestry(
                   depth: node.depth,
                   parentRole: node.ancestorRoles.last,
                   ancestorRoles: node.ancestorRoles,
                   ancestorIdentifiers: node.ancestorIdentifiers)
            if hasRefinedIdentifier && hasRefinedAncestry {
                guard WorkspaceSidebarRefinementPolicy
                    .hasObservedActivationHelp(node.help) else {
                    malformedRefinedSurface = true
                    continue
                }
                guard let entry = WorkspaceSidebarRefinementPolicy.parse(
                    identifier: node.identifier,
                    label: node.label ?? node.title),
                      let parentPath = node.parentPath else {
                    malformedRefinedSurface = true
                    continue
                }
                let support = selectionSupport(of: node.element)
                guard !support.hitReadFailure else {
                    malformedRefinedSurface = true
                    continue
                }
                let pointerLocation: CGPoint?
                if support.isSupported {
                    pointerLocation = nil
                } else {
                    pointerLocation = point(
                        "AXActivationPoint", from: node.element)
                }
                // The verified v0.64.17 shape describes activation in AXHelp
                // but most inactive rows omit AXPress from CopyActionNames.
                // Attempting the standard press is safe only inside this exact,
                // complete surface; actuation and focused-window verification
                // still fail closed if the target app rejects it.
                refinedSeeds[parentPath, default: []].append(
                    RefinedSeed(
                        node: node,
                        entry: entry,
                        support: support,
                        pointerLocation: pointerLocation))
                continue
            }

            let values = [node.title, node.label, node.document]
                .compactMap(cleanOptional)
            guard !values.isEmpty else { continue }

            var control: AXUIElement?
            var controlRole: String?
            let nodeIndex = node.ancestors.count
            let nearbyIndices = [nodeIndex]
                + Array(node.ancestors.indices.reversed().prefix(3))
            for index in nearbyIndices {
                let element = index == nodeIndex
                    ? node.element : node.ancestors[index]
                let role = index == nodeIndex
                    ? node.role : node.ancestorRoles[index]
                let ancestorRoles = index == nodeIndex
                    ? node.ancestorRoles : Array(node.ancestorRoles.prefix(index))
                guard WorkspaceAXSafetyPolicy.genericControlIsEligible(
                    role: role,
                    ancestorRoles: ancestorRoles,
                    supportsSelection: true) else { continue }
                let support = selectionSupport(of: element)
                if support.hitReadFailure {
                    hitGenericReadFailure = true
                    continue
                }
                guard support.isSupported else { continue }
                control = element
                controlRole = role
                break
            }
            guard let control, let controlRole else { continue }
            let fingerprint = values
                .map(normalizedForComparison)
                .joined(separator: "\u{1f}")
            if genericRecords.contains(where: {
                CFEqual($0.element, control) && $0.identityFingerprint == fingerprint
            }) {
                continue
            }
            let candidateID = [node.identifier, node.path]
                .compactMap(cleanOptional)
                .joined(separator: "#")
            let candidate = WorkspaceCandidate(
                id: candidateID.isEmpty ? node.path : candidateID,
                role: controlRole,
                title: cleanOptional(node.title),
                label: cleanOptional(node.label),
                document: cleanOptional(node.document))
            let record = AXCandidateRecord(
                candidate: candidate,
                element: control,
                window: closestWindow(to: node),
                identityFingerprint: fingerprint,
                activationKind: .accessibilityAction,
                allowsObservedStatusMarker: false,
                pointerLocation: nil)
            // Distinct elements with identical text must remain distinct. The
            // scorer's tie rule is the safety boundary that prevents arbitrary
            // selection when two workspaces share a title.
            genericRecords.append(record)
        }

        let nodesByPath = Dictionary(uniqueKeysWithValues: nodes.map {
            ($0.path, $0)
        })
        var refinedRecords: [AXCandidateRecord] = []
        for (parentPath, seeds) in refinedSeeds {
            guard let parent = nodesByPath[parentPath],
                  WorkspaceSidebarRefinementPolicy.isCompleteSurface(
                      seeds.map(\.entry),
                      directChildCount: parent.directChildCount,
                      parentChildrenReadComplete: parent.childrenReadComplete)
            else {
                malformedRefinedSurface = true
                continue
            }
            for seed in seeds {
                let candidateID = "\(seed.entry.identifier)#\(seed.node.path)"
                let candidate = WorkspaceCandidate(
                    id: candidateID,
                    role: seed.node.role,
                    title: seed.entry.title)
                refinedRecords.append(AXCandidateRecord(
                    candidate: candidate,
                    element: seed.node.element,
                    window: closestWindow(to: seed.node),
                    identityFingerprint: normalizedForComparison(
                        seed.entry.title),
                    activationKind: seed.support.isSupported
                        ? .accessibilityAction : .shapeScopedPointer,
                    allowsObservedStatusMarker: true,
                    pointerLocation: seed.pointerLocation))
            }
        }

        return AXCandidateDiscovery(
            genericRecords: genericRecords.sorted {
                $0.candidate.id < $1.candidate.id
            },
            refinedRecords: refinedRecords.sorted {
                $0.candidate.id < $1.candidate.id
            },
            hitGenericReadFailure: hitGenericReadFailure,
            malformedRefinedSurface: malformedRefinedSurface)
    }

    static func actuate(
        _ record: AXCandidateRecord,
        ownerPID: Int32
    ) -> AXActuationResult {
        var actedElement: AXUIElement?
        var didSelect = false
        var didRaise = false
        switch record.activationKind {
        case .accessibilityAction:
            prepare(record.element)
            if AXUIElementPerformAction(
                record.element, kAXPressAction as CFString) == .success {
                didSelect = true
                actedElement = record.element
            } else {
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(
                    record.element,
                    kAXSelectedAttribute as CFString,
                    &settable) == .success,
                   settable.boolValue,
                   AXUIElementSetAttributeValue(
                       record.element,
                       kAXSelectedAttribute as CFString,
                       kCFBooleanTrue) == .success {
                    didSelect = true
                    actedElement = record.element
                }
            }
        case .shapeScopedPointer:
            guard record.pointerLocation != nil,
                  let window = record.window else {
                AccessibilityWorkspaceTargeter.diagnostic(
                    "pointer=missing-activation-point")
                break
            }
            prepare(window)
            guard AXUIElementPerformAction(
                window, kAXRaiseAction as CFString) == .success else {
                AccessibilityWorkspaceTargeter.diagnostic(
                    "pointer=window-raise-failed")
                break
            }
            didRaise = true
            Thread.sleep(forTimeInterval: 0.05)
            guard let refreshedLocation = point(
                "AXActivationPoint", from: record.element) else {
                AccessibilityWorkspaceTargeter.diagnostic(
                    "pointer=geometry-refresh-failed")
                break
            }
            didSelect = clickShapeScopedPoint(
                refreshedLocation,
                expectedElement: record.element,
                ownerPID: ownerPID)
            if didSelect {
                actedElement = record.element
            }
        }

        if didSelect, !didRaise, let window = record.window {
            prepare(window)
            if AXUIElementPerformAction(
                window, kAXRaiseAction as CFString) == .success {
                didRaise = true
            }
        }
        return AXActuationResult(
            didSelect: didSelect,
            didRaise: didRaise,
            actedElement: actedElement)
    }

    static func verifyFocusedTitle(
        application: AXUIElement,
        matchedTitle: String,
        allowsObservedStatusMarker: Bool,
        expectedWindow: AXUIElement?
    ) -> AXVerification {
        // Focused controls are deliberately excluded: pressing a sidebar row
        // can focus that row without switching the workspace. Only the owning
        // app's focused WINDOW title is a workspace-level post-condition.
        guard let focusedWindow = element(
            kAXFocusedWindowAttribute, from: application),
              let focusedTitle = cleanOptional(text(
                kAXTitleAttribute, from: focusedWindow)) else {
            return .unavailable
        }
        if let expectedWindow, !CFEqual(focusedWindow, expectedWindow) {
            return .failed
        }
        if allowsObservedStatusMarker {
            return WorkspaceSidebarRefinementPolicy
                .focusedWindowTitleMatchesExactly(
                    focusedTitle,
                    expected: matchedTitle)
                ? .verified : .failed
        }
        let expected = normalizedForComparison(matchedTitle)
        return title(focusedTitle, confidentlyMatches: expected)
            ? .verified : .failed
    }

    static func cleanedConfirmationTitle(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func closestWindow(to node: AXNodeRecord) -> AXUIElement? {
        for index in node.ancestorRoles.indices.reversed()
        where node.ancestorRoles[index] == kAXWindowRole {
            return node.ancestors[index]
        }
        return nil
    }

    private static func selectionSupport(
        of element: AXUIElement
    ) -> AXSelectionSupport {
        prepare(element)
        var names: CFArray?
        let actionError = AXUIElementCopyActionNames(element, &names)
        if actionError == .success,
           let actionNames = names as? [String],
           actionNames.contains(kAXPressAction) {
            return AXSelectionSupport(
                isSupported: true, hitReadFailure: false)
        }
        let actionReadFailed = actionError != .success
            && !isBenignAbsence(actionError)
        if actionError == .success, names == nil {
            return AXSelectionSupport(
                isSupported: false, hitReadFailure: true)
        }

        prepare(element)
        var settable = DarwinBoolean(false)
        let selectedError = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedAttribute as CFString,
            &settable)
        let selectedReadFailed = selectedError != .success
            && !isBenignAbsence(selectedError)
        return AXSelectionSupport(
            isSupported: selectedError == .success && settable.boolValue,
            hitReadFailure: actionReadFailed || selectedReadFailed)
    }

    private static func clickShapeScopedPoint(
        _ center: CGPoint,
        expectedElement: AXUIElement,
        ownerPID: Int32
    ) -> Bool {
        guard NSRunningApplication(
            processIdentifier: pid_t(ownerPID))?.isActive == true else {
            AccessibilityWorkspaceTargeter.diagnostic(
                "pointer=owner-not-active")
            return false
        }
        guard center.x.isFinite, center.y.isFinite else {
            AccessibilityWorkspaceTargeter.diagnostic(
                "pointer=invalid-geometry center=\(center)")
            return false
        }
        guard pointIsOnActiveDisplay(center) else {
            AccessibilityWorkspaceTargeter.diagnostic(
                "pointer=off-display center=\(center)")
            return false
        }
        guard hitTest(
            center,
            matches: expectedElement,
            ownerPID: ownerPID) else {
            AccessibilityWorkspaceTargeter.diagnostic(
                "pointer=hit-test-mismatch")
            return false
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let disallowedFlags: CGEventFlags = [
            .maskShift, .maskControl, .maskAlternate, .maskCommand,
            .maskSecondaryFn, .maskHelp,
        ]
        guard CGEventSource.flagsState(.combinedSessionState)
            .intersection(disallowedFlags).isEmpty,
              !CGEventSource.buttonState(
                  .combinedSessionState, button: .left),
              !CGEventSource.buttonState(
                  .combinedSessionState, button: .right),
              !CGEventSource.buttonState(
                  .combinedSessionState, button: .center),
              let originalLocation = CGEvent(source: nil)?.location,
              originalLocation.x.isFinite,
              originalLocation.y.isFinite,
              pointIsOnActiveDisplay(originalLocation) else {
            AccessibilityWorkspaceTargeter.diagnostic(
                "pointer=input-state-unsafe")
            return false
        }
        guard let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: center,
            mouseButton: .left),
              let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: center,
                mouseButton: .left) else {
            AccessibilityWorkspaceTargeter.diagnostic(
                "pointer=event-creation-failed")
            return false
        }
        down.flags = []
        up.flags = []
        guard NSRunningApplication(
            processIdentifier: pid_t(ownerPID))?.isActive == true,
              hitTest(
                  center,
                  matches: expectedElement,
                  ownerPID: ownerPID) else {
            AccessibilityWorkspaceTargeter.diagnostic(
                "pointer=pre-post-state-changed")
            return false
        }
        AccessibilityWorkspaceTargeter.diagnostic(
            "pointer=click center=\(center)")
        // The verified inactive sidebar rows do not expose AXPress. A targeted
        // process post is accepted but ignored by this SwiftUI surface, while a
        // normal foreground HID click follows the same path as a user click.
        // The owner-active and display guards bound that global action; exact
        // focused-window verification remains mandatory before success copy.
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.015)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        if let currentLocation = CGEvent(source: nil)?.location,
           hypot(
               currentLocation.x - center.x,
               currentLocation.y - center.y) <= 2,
           let restore = CGEvent(
               mouseEventSource: source,
               mouseType: .mouseMoved,
               mouseCursorPosition: originalLocation,
               mouseButton: .left) {
            restore.flags = []
            restore.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func hitTest(
        _ point: CGPoint,
        matches expectedElement: AXUIElement,
        ownerPID: Int32
    ) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        prepare(systemWide)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &hit) == .success,
              let hit else { return false }
        var hitPID = pid_t(0)
        guard AXUIElementGetPid(hit, &hitPID) == .success,
              hitPID == pid_t(ownerPID) else { return false }

        var current: AXUIElement? = hit
        for _ in 0..<5 {
            guard let element = current else { return false }
            if CFEqual(element, expectedElement) { return true }
            current = self.element(kAXParentAttribute, from: element)
        }
        return false
    }

    private static func pointIsOnActiveDisplay(_ point: CGPoint) -> Bool {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else { return false }
        var displays = [CGDirectDisplayID](
            repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(
            displayCount, &displays, &displayCount) == .success else {
            return false
        }
        return displays.prefix(Int(displayCount)).contains {
            CGDisplayBounds($0).contains(point)
        }
    }

    private static func point(
        _ attribute: String,
        from element: AXUIElement
    ) -> CGPoint? {
        prepare(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var result = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &result) ? result : nil
    }

    private static func childElements(
        from element: AXUIElement,
        role: String
    ) -> AXElementListRead {
        let attributes: [String]
        switch role {
        case kAXApplicationRole:
            attributes = [kAXWindowsAttribute]
        case kAXTableRole, kAXListRole, kAXOutlineRole:
            attributes = [kAXChildrenAttribute, kAXRowsAttribute]
        case kAXTabGroupRole:
            attributes = [kAXChildrenAttribute, kAXTabsAttribute]
        case kAXScrollAreaRole:
            attributes = [kAXChildrenAttribute, kAXContentsAttribute]
        default:
            attributes = genericChildAttributes
        }

        var result: [AXUIElement] = []
        var hitReadFailure = false
        for attribute in attributes {
            let read = elementListRead(attribute, from: element)
            hitReadFailure = hitReadFailure || read.hitReadFailure
            for candidate in read.elements where !result.contains(where: {
                CFEqual($0, candidate)
            }) {
                result.append(candidate)
            }
        }
        return AXElementListRead(
            elements: result,
            hitReadFailure: hitReadFailure)
    }

    private static func elementListRead(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXElementListRead {
        prepare(element)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value)
        guard error == .success else {
            return AXElementListRead(
                elements: [],
                hitReadFailure: WorkspaceAXSafetyPolicy
                    .traversalReadCompromisesCompleteness(
                        requiredAttribute: false,
                        benignAbsence: isBenignAbsence(error),
                        invalidatedElement: error == .invalidUIElement))
        }
        guard let value else {
            return AXElementListRead(
                elements: [],
                hitReadFailure: true)
        }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return AXElementListRead(
                elements: [unsafeDowncast(value, to: AXUIElement.self)],
                hitReadFailure: false)
        }
        guard let values = value as? [AXUIElement] else {
            return AXElementListRead(
                elements: [],
                hitReadFailure: true)
        }
        return AXElementListRead(
            elements: values,
            hitReadFailure: false)
    }

    private static func textRead(
        _ attribute: String,
        from element: AXUIElement,
        required: Bool = false
    ) -> AXTextRead {
        prepare(element)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value)
        guard error == .success else {
            return AXTextRead(
                value: nil,
                hitReadFailure: WorkspaceAXSafetyPolicy
                    .traversalReadCompromisesCompleteness(
                        requiredAttribute: required,
                        benignAbsence: isBenignAbsence(error),
                        invalidatedElement: error == .invalidUIElement),
                elementInvalidated: error == .invalidUIElement)
        }
        guard let value else {
            return AXTextRead(
                value: nil,
                hitReadFailure: true,
                elementInvalidated: false)
        }
        guard let string = value as? String else {
            return AXTextRead(
                value: nil,
                hitReadFailure: true,
                elementInvalidated: false)
        }
        return AXTextRead(
            value: string,
            hitReadFailure: false,
            elementInvalidated: false)
    }

    private static func isBenignAbsence(_ error: AXError) -> Bool {
        switch error {
        case .attributeUnsupported, .actionUnsupported, .noValue:
            true
        default:
            false
        }
    }

    private static func title(
        _ raw: String,
        confidentlyMatches expected: String
    ) -> Bool {
        let actual = normalizedForComparison(raw)
        guard !actual.isEmpty, !expected.isEmpty else { return false }
        if actual == expected { return true }

        let separators = CharacterSet(
            charactersIn: "—–|·•:[](){}<>\t\n")
        if actual.components(separatedBy: separators)
            .map(normalizedForComparison)
            .contains(expected) {
            return true
        }

        let path = actual.hasPrefix("file://")
            ? String(actual.dropFirst("file://".count)) : actual
        return normalizedForComparison(
            URL(fileURLWithPath: path).lastPathComponent) == expected
    }

    private static func normalizedForComparison(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func text(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        prepare(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolean(
        _ attribute: String,
        from element: AXUIElement
    ) -> Bool? {
        prepare(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        prepare(element)
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names else { return [] }
        return names as? [String] ?? []
    }

    static func probeActionNames(of element: AXUIElement) -> [String] {
        actionNames(of: element)
    }

    static func probeAttributeNames(of element: AXUIElement) -> [String] {
        prepare(element)
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names else { return [] }
        return names as? [String] ?? []
    }

    static func probeSelected(of element: AXUIElement) -> Bool? {
        boolean(kAXSelectedAttribute, from: element)
    }

    private static func element(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        prepare(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

}

// MARK: - Read-only debug probe

/// Depth-limited, non-prompting diagnostic used by `--probe-ax`. It never
/// performs an AX action or changes application activation.
@MainActor
enum AccessibilityWorkspaceProbe {
    static func dump(processOrApplication query: String) -> Int32 {
        guard AXIsProcessTrusted() else {
            print("AX trusted: false (probe did not prompt)")
            return 77
        }
        guard let pid = resolvePID(query) else {
            FileHandle.standardError.write(Data(
                "trifola: no unique running application matched '\(query)'\n".utf8))
            return 64
        }

        let application = AXUIElementCreateApplication(pid_t(pid))
        AXWorkspaceTree.prepare(application)
        let traversal = AXWorkspaceTree.read(
            application: application,
            bounds: .init(maxDepth: 8, maxNodes: 1_500, maxDuration: 0.75))
        print("AX trusted: true")
        print("PID: \(pid)")
        print("nodes: \(traversal.nodes.count)"
              + " node_limit=\(traversal.hitNodeLimit)"
              + " time_limit=\(traversal.hitTimeLimit)"
              + " depth_limit=\(traversal.hitDepthLimit)"
              + " read_failure=\(traversal.hitReadFailure)"
              + " ignored_invalid=\(traversal.ignoredInvalidElementCount)"
              + " shallow_read_depth=\(String(describing: traversal.shallowestReadFailureDepth))"
              + " pending_depth=\(String(describing: traversal.minimumUnvisitedDepth))")
        for node in traversal.nodes {
            var attributes = ["role=\(quoted(node.role))"]
            if let value = node.title { attributes.append("title=\(quoted(value))") }
            if let value = node.label { attributes.append("label=\(quoted(value))") }
            if let value = node.document { attributes.append("document=\(quoted(value))") }
            if let value = node.identifier { attributes.append("id=\(quoted(value))") }
            if node.identifier?.hasPrefix(
                WorkspaceSidebarRefinementPolicy.identifierPrefix) == true {
                if let value = node.help {
                    attributes.append("help=\(quoted(value))")
                }
                let attributeNames = AXWorkspaceTree.probeAttributeNames(
                    of: node.element)
                if !attributeNames.isEmpty {
                    let joinedAttributes = attributeNames.joined(separator: ",")
                    attributes.append("attrs=\(quoted(joinedAttributes))")
                }
                let actions = AXWorkspaceTree.probeActionNames(of: node.element)
                if !actions.isEmpty {
                    attributes.append("actions=\(quoted(actions.joined(separator: ",")))")
                }
                if let selected = AXWorkspaceTree.probeSelected(of: node.element) {
                    attributes.append("selected=\(selected)")
                }
            }
            let indent = String(repeating: "  ", count: node.depth)
            print("\(indent)[\(node.path)] \(attributes.joined(separator: " "))")
        }
        return 0
    }

    private static func resolvePID(_ query: String) -> Int32? {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pid = Int32(cleaned), pid > 0 { return pid }
        let needle = cleaned.lowercased()
        let exact = NSWorkspace.shared.runningApplications.filter { app in
            let bundleID = app.bundleIdentifier?.lowercased()
            let name = app.localizedName?.lowercased()
                ?? app.bundleURL?.deletingPathExtension()
                    .lastPathComponent.lowercased()
            return bundleID == needle || name == needle
        }
        if exact.count == 1 { return Int32(exact[0].processIdentifier) }
        let partial = NSWorkspace.shared.runningApplications.filter { app in
            let bundleID = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased()
                ?? app.bundleURL?.deletingPathExtension()
                    .lastPathComponent.lowercased() ?? ""
            return bundleID.contains(needle) || name.contains(needle)
        }
        return partial.count == 1 ? Int32(partial[0].processIdentifier) : nil
    }

    private static func quoted(_ raw: String) -> String {
        let clipped = String(raw.prefix(600))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(clipped)\""
    }
}
