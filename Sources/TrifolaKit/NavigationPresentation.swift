import Foundation

/// Pure decision for the content column: which surface carries a section
/// change, and which surface owns the first-frame draw probe.
///
/// The invariant this type exists to protect: **the destination view must keep
/// one structural identity across the pending→presented flip.** The 798a2fb
/// regression rendered the destination from different `if/else` branches as
/// `presentedGeneration` caught up with the navigation generation — in SwiftUI
/// a branch change is an identity change, so every section switch mounted the
/// heavy destination, threw it away one main-queue tick later, and mounted a
/// second copy (state reset, scroll reset, a visible double-freeze). Only the
/// shell may come and go; the destination mounts once per section.
public enum NavigationPresentation: Equatable, Sendable {
    /// Commit a cheap placeholder frame this pass; the destination is not
    /// mounted yet. Chosen only while a navigation is pending AND the
    /// destination would be expensive to mount blind (first-ever visit) or has
    /// no snapshot to hydrate from.
    case shell
    /// The destination is (or stays) mounted. While the navigation is still
    /// pending the destination itself carries the first-frame probe.
    case content

    public static func resolve(
        isPending: Bool,
        cold: Bool,
        ready: Bool
    ) -> NavigationPresentation {
        isPending && (cold || !ready) ? .shell : .content
    }

    /// True when the mounted destination should own the first-frame milestone:
    /// exactly the pending passes that resolve to `.content`. After the flip
    /// (`isPending == false`) the probe stays attached but disabled, so the
    /// destination's identity never changes with the probe's activity.
    public static func contentCarriesFirstFrame(
        isPending: Bool,
        cold: Bool,
        ready: Bool
    ) -> Bool {
        isPending && resolve(isPending: isPending, cold: cold, ready: ready) == .content
    }
}
