import Foundation

/// Platform-neutral description of the one BLOCKED notification category. The app
/// translates this into `UNNotificationCategory`; keeping the contract here lets the
/// registration and response routing run under unit tests with a fake center.
public struct NotificationActionDescriptor: Sendable, Hashable, Equatable {
    public let identifier: String
    public let title: String
    public let opensApp: Bool

    public init(identifier: String, title: String, opensApp: Bool) {
        self.identifier = identifier
        self.title = title
        self.opensApp = opensApp
    }
}

public struct NotificationCategoryDescriptor: Sendable, Hashable, Equatable {
    public let identifier: String
    public let actions: [NotificationActionDescriptor]

    public init(identifier: String, actions: [NotificationActionDescriptor]) {
        self.identifier = identifier
        self.actions = actions
    }
}

public protocol NotificationCategoryCenter: AnyObject {
    func install(categories: Set<NotificationCategoryDescriptor>)
}

public protocol NotificationAuthorizationCenter: NotificationCategoryCenter {
    func requestAuthorization()
}

public enum BlockedNotificationCategory {
    public static let identifier = "blocked"
    public static let showAction = "blocked.show"
    public static let snoozeAction = "blocked.snooze-1h"

    public static let descriptor = NotificationCategoryDescriptor(
        identifier: identifier,
        actions: [
            NotificationActionDescriptor(identifier: showAction,
                                         title: "Show", opensApp: true),
            NotificationActionDescriptor(identifier: snoozeAction,
                                         title: "Snooze 1h", opensApp: false),
        ])

    public static func register(on center: NotificationCategoryCenter) {
        center.install(categories: [descriptor])
    }

    public enum Route: Sendable, Equatable {
        case show
        case snoozeOneHour
        case dismiss
    }

    /// Default notification clicks share Show's inspect path. Unknown action ids
    /// are ignored so future system actions never accidentally mutate agency state.
    public static func route(actionIdentifier: String, defaultActionIdentifier: String) -> Route {
        switch actionIdentifier {
        case showAction, defaultActionIdentifier: return .show
        case snoozeAction: return .snoozeOneHour
        default: return .dismiss
        }
    }
}

/// One-way opt-in gate for every notification-center side effect. A fresh launch
/// with the persisted toggle off neither registers categories nor requests system
/// authorization; the first explicit opt-in performs both exactly once.
public final class BlockedNotificationOptIn {
    private var activated = false

    public init() {}

    public func activateIfEnabled(_ enabled: Bool,
                                  on center: NotificationAuthorizationCenter) {
        guard enabled, !activated else { return }
        activated = true
        BlockedNotificationCategory.register(on: center)
        center.requestAuthorization()
    }
}
