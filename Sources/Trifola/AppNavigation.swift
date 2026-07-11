import Foundation
import SwiftUI
import TrifolaKit

/// Low-frequency navigation state, isolated from the store-owned application
/// model. A destination change publishes this object only; it must never fan out
/// through `AppServices.objectWillChange` and remount every data projection.
@MainActor
final class AppNavigation: ObservableObject {
    private static let sectionOverride =
        (ProcessInfo.processInfo.environment["TRIFOLA_SECTION"]
            ?? ProcessInfo.processInfo.environment["CMC_SECTION"])
            .flatMap(AppSection.init(rawValue:))

    /// `TRIFOLA_SECTION=spend` (etc.) opens the app on a given screen. The
    /// persisted value is otherwise the restoration source for the next launch.
    @Published private(set) var section: AppSection = .overview
    private(set) var firstAppearanceSection: AppSection? = .overview
    private(set) var navigationOrigin: NavOrigin = .programmatic
    private(set) var navigationCold = false
    private(set) var seenSections: Set<AppSection> = [.overview]

    private var navigationStart: (section: AppSection, nanoseconds: UInt64)?
    private(set) var navigationMetricGeneration = 0
    private(set) var navigationMetricJourney: NavigationMetricJourney?

    init() {
        let persistedSectionRaw = UserDefaults.standard.string(
            forKey: AppRestorationKeys.section) ?? ""
        let restoredSection = Self.sectionOverride
            ?? AppSection(rawValue: persistedSectionRaw)
            ?? .overview
        section = restoredSection
        firstAppearanceSection = restoredSection
        seenSections = [restoredSection]

        if Self.sectionOverride == nil,
           !persistedSectionRaw.isEmpty,
           AppSection(rawValue: persistedSectionRaw) == nil {
            UserDefaults.standard.removeObject(forKey: AppRestorationKeys.section)
        }
    }

    /// The only section mutation point. Signposts begin before the published
    /// write, so the interval includes the exact sidebar-click-to-draw path.
    func select(_ newSection: AppSection, origin: NavOrigin) {
        guard section != newSection else { return }

        let isCold = !seenSections.contains(newSection)
        navigationCold = isCold
        NavigationMetrics.cancel(navigationMetricJourney)
        navigationMetricGeneration += 1
        navigationMetricJourney = NavigationMetrics.beginNavigation(
            to: newSection.navigationMetricScreen,
            generation: navigationMetricGeneration,
            cold: isCold)
        navigationOrigin = origin

        if Perf.enabled {
            navigationStart = (newSection, DispatchTime.now().uptimeNanoseconds)
        }

        let isFirstAppearance = seenSections.insert(newSection).inserted
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = origin != .pointer
        withTransaction(transaction) {
            firstAppearanceSection = isFirstAppearance ? newSection : nil
            section = newSection
        }
        let rawValue = newSection.rawValue
        let key = AppRestorationKeys.section
        Task.detached(priority: .utility) {
            UserDefaults.standard.set(rawValue, forKey: key)
        }
    }

    /// Destination-mount end of the opt-in stderr span. AppKit draw probes own
    /// the acceptance intervals and remain attached to the content shell.
    func navigationDidAppear(_ appearedSection: AppSection) {
        guard Perf.enabled,
              let start = navigationStart,
              start.section == appearedSection else { return }
        navigationStart = nil
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.nanoseconds)
            / 1_000_000
        FileHandle.standardError.write(Data(
            "[perf] main:nav.switch.\(appearedSection.rawValue) \(String(format: "%.1f", ms))ms\n".utf8))
    }
}
