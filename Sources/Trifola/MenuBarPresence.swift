import SwiftUI
import TrifolaKit

/// Owns JUST the menu-bar-strip on/off flag — deliberately split out of `AppServices`.
///
/// PERF (the render-storm fix, 2026-07-08): the App scene's `.commands` (the macOS
/// main menu) and `MenuBarExtra(isInserted:)` bind to this flag. When that flag lived
/// on `AppServices` — which republishes on *every* session refresh through the
/// nested-store forwarder — macOS rebuilt the ENTIRE main menu
/// (`AppDelegate.makeMainMenu`) and the status item on every single data publish. At
/// fleet scale those rebuilds never finished before the next publish, pegging the main
/// thread at ~99% CPU forever (an `NSRunLoop.flushObservers → AppGraph.graphDidChange →
/// scenesDidChange → makeMainMenu` loop, confirmed by `sample`). This object publishes
/// ONLY when the toggle actually flips, so the menu is rebuilt only when it truly
/// changes — the scene no longer observes the high-frequency `AppServices`.
///
/// `CMC_MENUBAR=0/1` still pins the value for one launch (snapshot/CI) without touching
/// the persisted preference; a user ⌘-drag out of the bar flips + persists it.
@MainActor
final class MenuBarPresence: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            // Only persist a REAL flip. `MenuBarExtra(isInserted:)` writes the
            // binding back on every scene update (often the same value); without
            // this guard each redundant write hit the disk and — via @Published —
            // rebuilt the whole main menu + status item, an ~99% CPU scene-rebuild
            // loop. The scene binds through `boundEnabled` (below), which filters
            // no-op writes so @Published never even republishes on an unchanged
            // value; this guard is the belt to that binding's braces.
            guard oldValue != enabled, !Self.envOverridden else { return }
            MenuBarPreferencesStore().save(MenuBarPreferences(enabled: enabled))
        }
    }

    /// A binding that drops redundant writes. `MenuBarExtra(isInserted:)` and any
    /// other scene-level binder must go through this — a plain `$enabled` lets a
    /// same-value write from the framework republish `@Published` and re-enter the
    /// menu-rebuild storm (see `enabled`'s didSet). Only a genuine change flips it.
    var boundEnabled: Binding<Bool> {
        Binding(get: { self.enabled },
                set: { newValue in
                    if newValue != self.enabled { self.enabled = newValue }
                })
    }

    /// True when CMC_MENUBAR pinned the value for this launch (don't persist flips).
    static let envOverridden = ProcessInfo.processInfo.environment["CMC_MENUBAR"] != nil

    init() {
        switch ProcessInfo.processInfo.environment["CMC_MENUBAR"] {
        case "0": enabled = false
        case "1": enabled = true
        default: enabled = MenuBarPreferencesStore().load().enabled
        }
    }
}
