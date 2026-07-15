import Foundation
import Testing
@testable import TrifolaKit

// Pins the content-column phase decision behind the section-switch jank fix.
// The 798a2fb regression rendered the destination from different if/else
// branches as the presented generation caught up — a SwiftUI identity change
// that mounted every screen twice per switch (double freeze + visible flash).
// These tests pin the pure decision so the shape can't silently drift back:
// the shell appears ONLY while a navigation is pending into a cold or
// not-ready destination; everything else is `.content`, whose identity the
// view layer keeps stable by parameterizing (never detaching) its probes.
@Suite("Navigation presentation — shell only for pending cold/not-ready")
struct NavigationPresentationTests {

    @Test("pending + cold → shell, regardless of readiness")
    func pendingColdShowsShell() {
        #expect(NavigationPresentation.resolve(
            isPending: true, cold: true, ready: false) == .shell)
        #expect(NavigationPresentation.resolve(
            isPending: true, cold: true, ready: true) == .shell)
    }

    @Test("pending + warm + not ready → shell (no snapshot to hydrate from)")
    func pendingNotReadyShowsShell() {
        #expect(NavigationPresentation.resolve(
            isPending: true, cold: false, ready: false) == .shell)
    }

    @Test("pending + warm + ready → content (the common revisit; never a shell flash)")
    func warmReadyRevisitIsContent() {
        #expect(NavigationPresentation.resolve(
            isPending: true, cold: false, ready: true) == .content)
    }

    @Test("settled navigations are always content — the flip must not restructure")
    func settledIsAlwaysContent() {
        for cold in [true, false] {
            for ready in [true, false] {
                #expect(NavigationPresentation.resolve(
                    isPending: false, cold: cold, ready: ready) == .content)
            }
        }
    }

    @Test("destination carries first-frame exactly on the pending warm+ready pass")
    func firstFrameCarrier() {
        #expect(NavigationPresentation.contentCarriesFirstFrame(
            isPending: true, cold: false, ready: true))
        // Shell passes: the shell owns first-frame, not the destination.
        #expect(!NavigationPresentation.contentCarriesFirstFrame(
            isPending: true, cold: true, ready: false))
        #expect(!NavigationPresentation.contentCarriesFirstFrame(
            isPending: true, cold: false, ready: false))
        // Settled: the probe stays attached but must be inert.
        #expect(!NavigationPresentation.contentCarriesFirstFrame(
            isPending: false, cold: false, ready: true))
    }
}
