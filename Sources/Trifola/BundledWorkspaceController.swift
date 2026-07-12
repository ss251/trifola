import AppKit
import Foundation
import Security
import TrifolaKit

struct BundledWorkspaceEndpoint: Sendable, Equatable {
    let ownerProcessID: Int32
    let bundleURL: URL
    let executableURL: URL
}

struct BundledWorkspaceSelection: Sendable, Equatable {
    let endpoint: BundledWorkspaceEndpoint
    let target: WorkspaceBundledControlTarget
    let sessionProcessID: Int32
}

/// A verified tab-level selection: the surface whose resume binding carries
/// the exact session id, plus the window that hosted it at selection time.
struct BundledSurfaceSelection: Sendable, Equatable {
    let endpoint: BundledWorkspaceEndpoint
    let target: WorkspaceBundledSurfaceTarget
}

/// Narrow refinement for a running terminal that ships its own structured
/// workspace controller. Discovery is capability-based and the controller is
/// never searched on PATH: it must be a signed, same-team executable sealed
/// inside the exact owner application's bundle.
enum BundledWorkspaceController {
    private static let maximumWindowCount = 16
    private static let commandTimeout: TimeInterval = 1.5
    private static let operationTimeout: TimeInterval = 5
    private static let metadataOutputLimit = 2 * 1_024 * 1_024

    @MainActor
    static func endpoint(ownerProcessID: Int32) -> BundledWorkspaceEndpoint? {
        guard ownerProcessID > 0,
              let owner = NSRunningApplication(
                processIdentifier: pid_t(ownerProcessID)),
              !owner.isTerminated,
              let rawBundleURL = owner.bundleURL else { return nil }
        let bundleURL = rawBundleURL.resolvingSymlinksInPath()
            .standardizedFileURL
        guard let bundle = Bundle(url: bundleURL),
              let executableName = bundle.object(
                forInfoDictionaryKey: "CFBundleExecutable") as? String,
              !executableName.isEmpty,
              URL(fileURLWithPath: executableName).lastPathComponent
                == executableName else { return nil }

        let binURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let executableURL = binURL
            .appendingPathComponent(executableName, isDirectory: false)
            .standardizedFileURL
        guard executableURL.deletingLastPathComponent() == binURL,
              validExecutable(at: executableURL),
              signingTeamIdentifier(at: bundleURL)
                == signingTeamIdentifier(at: executableURL),
              signingTeamIdentifier(at: executableURL) != nil else { return nil }
        return BundledWorkspaceEndpoint(
            ownerProcessID: ownerProcessID,
            bundleURL: bundleURL,
            executableURL: executableURL)
    }

    /// Tab-exact selection: enumerate the host's workspaces and surfaces, join
    /// by the session id carried in a surface's resume binding, focus that
    /// surface, and verify the host's own current-surface read. Attempted only
    /// when the sealed controller ALSO advertises the surface methods; every
    /// existing gate (signature, capability version, bounded IO, fail-closed)
    /// applies unchanged.
    static func selectSurface(
        endpoint: BundledWorkspaceEndpoint,
        sessionID: String
    ) -> BundledSurfaceSelection? {
        guard endpointIsCurrentAndValid(endpoint) else { return nil }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(operationTimeout * 1_000_000_000)

        guard let capabilities = run(
            endpoint,
            arguments: ["capabilities"],
            maxOutputBytes: 512 * 1_024,
            deadline: deadline),
              WorkspaceBundledControlPolicy
                .supportsExpectedCapabilities(capabilities),
              WorkspaceBundledControlPolicy
                .supportsSurfaceCapabilities(capabilities) else {
            diagnostic("surface-capabilities=unsupported")
            return nil
        }
        guard let workspaceList = run(
            endpoint,
            arguments: ["rpc", "workspace.list", "{}"],
            maxOutputBytes: 512 * 1_024,
            deadline: deadline),
              let workspaceIDs = WorkspaceBundledControlPolicy
                .workspaceIDs(from: workspaceList) else {
            diagnostic("surface-workspace-list=invalid")
            return nil
        }
        var lists: [String: Data] = [:]
        lists.reserveCapacity(workspaceIDs.count)
        for workspaceID in workspaceIDs {
            guard let parameters = jsonObject(["workspace_id": workspaceID]),
                  let list = run(
                    endpoint,
                    arguments: ["rpc", "surface.list", parameters],
                    maxOutputBytes: 512 * 1_024,
                    deadline: deadline) else {
                diagnostic("surface-list=failed")
                return nil
            }
            lists[workspaceID] = list
        }
        guard let target = WorkspaceBundledControlPolicy.surfaceTarget(
            fromSurfaceListsByWorkspaceID: lists,
            sessionID: sessionID) else {
            diagnostic("surface-join=no-unique-match")
            return nil
        }
        diagnostic("surface-join=\(target.surfaceID)")
        guard endpointIsCurrentAndValid(endpoint) else { return nil }

        // Front the hosting window BEFORE focusing and verifying: the host's
        // current-surface read answers for the frontmost window, so a tab in a
        // window on another Space verifies only after its window is current
        // (observed live: the same tab verified when its window happened to be
        // front and timed out when it was not). The window is found through
        // the same structured system.top join the workspace tier trusts.
        guard let windowList = run(
            endpoint,
            arguments: ["rpc", "window.list", "{}"],
            maxOutputBytes: 256 * 1_024,
            deadline: deadline),
              let windowIDs = WorkspaceBundledControlPolicy.windowIDs(
                from: windowList),
              windowIDs.count <= maximumWindowCount else {
            diagnostic("surface-window-list=invalid")
            return nil
        }
        var snapshots: [String: Data] = [:]
        snapshots.reserveCapacity(windowIDs.count)
        for windowID in windowIDs {
            guard let parameters = jsonObject(["window_id": windowID]),
                  let snapshot = run(
                    endpoint,
                    arguments: ["rpc", "system.top", parameters],
                    maxOutputBytes: metadataOutputLimit,
                    deadline: deadline) else {
                diagnostic("surface-window-snapshot=failed")
                return nil
            }
            snapshots[windowID] = snapshot
        }
        guard let hostWindowID = WorkspaceBundledControlPolicy.windowID(
            containingWorkspace: target.workspaceID,
            inSnapshotsByWindowID: snapshots) else {
            diagnostic("surface-window-join=no-unique-window")
            return nil
        }
        guard run(endpoint,
                  arguments: ["focus-window", "--window", hostWindowID],
                  maxOutputBytes: 8 * 1_024,
                  deadline: deadline) != nil,
              run(endpoint,
                  arguments: [
                      "workspace", "select", target.workspaceID,
                      "--window", hostWindowID,
                  ],
                  maxOutputBytes: 8 * 1_024,
                  deadline: deadline) != nil else {
            diagnostic("surface-window-front=failed")
            return nil
        }

        guard let focusParameters = jsonObject(["surface_id": target.surfaceID]),
              run(endpoint,
                  arguments: ["rpc", "surface.focus", focusParameters],
                  maxOutputBytes: 8 * 1_024,
                  deadline: deadline) != nil else {
            diagnostic("surface-focus=failed")
            return nil
        }
        // The host applies focus asynchronously: an immediate current-surface
        // read can race the switch and fail a REAL success (observed live —
        // same click shape verified on retry). Poll briefly, like the AX
        // title check does, inside the same operation deadline.
        var verifiedRead: Data?
        for attempt in 0..<10 {
            guard let current = run(
                endpoint,
                arguments: ["rpc", "surface.current", "{}"],
                maxOutputBytes: 8 * 1_024,
                deadline: deadline) else { break }
            if WorkspaceBundledControlPolicy.surfaceFocusVerifies(
                currentSurfaceOutput: current, target: target) {
                verifiedRead = current
                break
            }
            if attempt < 9 { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard verifiedRead != nil else {
            diagnostic("surface-verify=failed")
            return nil
        }
        diagnostic("surface-selection=verified")
        return BundledSurfaceSelection(endpoint: endpoint, target: target)
    }

    /// Re-verify a surface selection at the post-condition stage.
    static func verifySurface(_ selection: BundledSurfaceSelection) -> Bool {
        guard endpointIsCurrentAndValid(selection.endpoint) else { return false }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(operationTimeout * 1_000_000_000)
        guard let current = run(
            selection.endpoint,
            arguments: ["rpc", "surface.current", "{}"],
            maxOutputBytes: 8 * 1_024,
            deadline: deadline) else { return false }
        return WorkspaceBundledControlPolicy.surfaceFocusVerifies(
            currentSurfaceOutput: current, target: selection.target)
    }

    static func select(
        endpoint: BundledWorkspaceEndpoint,
        sessionProcessID: Int32,
        matchedTitle: String?
    ) -> BundledWorkspaceSelection? {
        guard endpointIsCurrentAndValid(endpoint), sessionProcessID > 0 else {
            diagnostic("endpoint=invalid")
            return nil
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(operationTimeout * 1_000_000_000)

        guard let capabilities = run(
            endpoint,
            arguments: ["capabilities"],
            maxOutputBytes: 512 * 1_024,
            deadline: deadline),
              WorkspaceBundledControlPolicy
                .supportsExpectedCapabilities(capabilities) else {
            diagnostic("capabilities=unsupported")
            return nil
        }
        guard let windowList = run(
            endpoint,
            arguments: ["rpc", "window.list", "{}"],
            maxOutputBytes: 256 * 1_024,
            deadline: deadline),
              let windowIDs = WorkspaceBundledControlPolicy.windowIDs(
                from: windowList),
              windowIDs.count <= maximumWindowCount else {
            diagnostic("window-list=invalid")
            return nil
        }
        diagnostic("window-list=count-\(windowIDs.count)")

        var snapshots: [String: Data] = [:]
        snapshots.reserveCapacity(windowIDs.count)
        for windowID in windowIDs {
            guard let parameters = jsonObject(["window_id": windowID]),
                  let snapshot = run(
                    endpoint,
                    arguments: ["rpc", "system.top", parameters],
                    maxOutputBytes: metadataOutputLimit,
                    deadline: deadline) else {
                diagnostic("resource-snapshot=failed")
                return nil
            }
            snapshots[windowID] = snapshot
        }
        guard let target = WorkspaceBundledControlPolicy.target(
            from: snapshots,
            ownerProcessID: endpoint.ownerProcessID,
            sessionProcessID: sessionProcessID,
            matchedTitle: matchedTitle) else {
            diagnostic("pid-join=no-unique-match")
            return nil
        }
        diagnostic(
            "pid-join=\(target.windowRef)/\(target.workspaceRef)")
        guard endpointIsCurrentAndValid(endpoint) else {
            diagnostic("endpoint=changed-before-select")
            return nil
        }
        guard run(
            endpoint,
            arguments: [
                "workspace", "select", target.workspaceID,
                "--window", target.windowID,
            ],
            maxOutputBytes: 8 * 1_024,
            deadline: deadline) != nil else {
            diagnostic("select=failed")
            return nil
        }
        guard run(
            endpoint,
            arguments: ["focus-window", "--window", target.windowID],
            maxOutputBytes: 8 * 1_024,
            deadline: deadline) != nil else {
            diagnostic("focus-window=failed")
            return nil
        }

        let selection = BundledWorkspaceSelection(
            endpoint: endpoint,
            target: target,
            sessionProcessID: sessionProcessID)
        guard verify(selection, deadline: deadline) else {
            diagnostic("selection=unverified")
            return nil
        }
        diagnostic("selection=verified")
        return selection
    }

    static func verify(_ selection: BundledWorkspaceSelection) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(operationTimeout * 1_000_000_000)
        return verify(selection, deadline: deadline)
    }

    private static func verify(
        _ selection: BundledWorkspaceSelection,
        deadline: UInt64
    ) -> Bool {
        let endpoint = selection.endpoint
        let target = selection.target
        guard endpointIsCurrentAndValid(endpoint) else {
            diagnostic("verify=endpoint-invalid")
            return false
        }
        guard let currentWindow = run(
                endpoint,
                arguments: ["--id-format", "uuids", "current-window"],
                maxOutputBytes: 4 * 1_024,
                deadline: deadline),
              let currentWorkspace = run(
                endpoint,
                arguments: [
                    "--id-format", "uuids", "current-workspace",
                    "--window", target.windowID,
                ],
                maxOutputBytes: 4 * 1_024,
                deadline: deadline),
              let parameters = jsonObject(["window_id": target.windowID]),
              let snapshot = run(
                endpoint,
                arguments: ["rpc", "system.top", parameters],
                maxOutputBytes: metadataOutputLimit,
                deadline: deadline) else {
            diagnostic("verify=read-failed")
            return false
        }
        let verified = WorkspaceBundledControlPolicy.verifies(
            target,
            currentWindowOutput: currentWindow,
            currentWorkspaceOutput: currentWorkspace,
            targetWindowSnapshot: snapshot,
            ownerProcessID: endpoint.ownerProcessID,
            sessionProcessID: selection.sessionProcessID)
        diagnostic("verify=\(verified ? "exact" : "mismatch")")
        return verified
    }

    private static func run(
        _ endpoint: BundledWorkspaceEndpoint,
        arguments: [String],
        maxOutputBytes: Int,
        deadline: UInt64
    ) -> Data? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return nil }
        let remaining = TimeInterval(deadline - now) / 1_000_000_000
        return BoundedWorkspaceCommand.run(
            executableURL: endpoint.executableURL,
            arguments: arguments,
            timeout: min(commandTimeout, remaining),
            maxOutputBytes: maxOutputBytes)
    }

    private static func jsonObject(_ value: [String: String]) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func endpointIsCurrentAndValid(
        _ endpoint: BundledWorkspaceEndpoint
    ) -> Bool {
        guard let owner = NSRunningApplication(
            processIdentifier: pid_t(endpoint.ownerProcessID)),
              !owner.isTerminated,
              owner.bundleURL?.resolvingSymlinksInPath().standardizedFileURL
                == endpoint.bundleURL,
              endpoint.executableURL.deletingLastPathComponent()
                == endpoint.bundleURL
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("bin", isDirectory: true)
                    .resolvingSymlinksInPath().standardizedFileURL,
              validExecutable(at: endpoint.executableURL),
              let bundleTeam = signingTeamIdentifier(at: endpoint.bundleURL),
              let executableTeam = signingTeamIdentifier(
                at: endpoint.executableURL),
              bundleTeam == executableTeam else { return false }
        return true
    }

    private static func validExecutable(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isExecutableKey,
        ]) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && values.isExecutable == true
    }

    private static func signingTeamIdentifier(at url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[
                kSecCodeInfoTeamIdentifier as String] as? String else {
            return nil
        }
        let trimmed = team.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func diagnostic(_ message: String) {
        guard ProcessInfo.processInfo.environment[
            "TRIFOLA_AX_DIAGNOSTICS"] == "1" else { return }
        FileHandle.standardError.write(
            Data("[workspace-control] \(message)\n".utf8))
    }
}

private enum BoundedWorkspaceCommand {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) -> Data? {
        guard timeout > 0,
              maxOutputBytes >= 0,
              FileManager.default.isExecutableFile(
                atPath: executableURL.path) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = [
            "HOME": NSHomeDirectory(),
            "LANG": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let processDone = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        let result = Locked<(data: Data, exceeded: Bool, failed: Bool)>(
            (Data(), false, false))
        process.terminationHandler = { _ in processDone.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var data = Data()
            var exceeded = false
            var failed = false
            do {
                while true {
                    let remaining = maxOutputBytes - data.count
                    let count = remaining >= 64 * 1_024
                        ? 64 * 1_024 : remaining + 1
                    let chunk = try output.fileHandleForReading.read(
                        upToCount: max(1, count)) ?? Data()
                    if chunk.isEmpty { break }
                    if chunk.count > remaining {
                        exceeded = true
                        kill(process)
                        break
                    }
                    data.append(chunk)
                }
            } catch {
                failed = true
            }
            result.withLock { $0 = (data, exceeded, failed) }
            readerDone.signal()
        }

        let waitDeadline = DispatchTime.now() + timeout
        guard processDone.wait(timeout: waitDeadline) != .timedOut else {
            kill(process)
            _ = processDone.wait(timeout: .now() + 0.25)
            return nil
        }
        guard readerDone.wait(timeout: .now() + 0.25) != .timedOut else {
            kill(process)
            return nil
        }
        let captured = result.withLock { $0 }
        guard process.terminationStatus == 0,
              !captured.exceeded,
              !captured.failed else { return nil }
        return captured.data
    }

    private static func kill(_ process: Process) {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}
