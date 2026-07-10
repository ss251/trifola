import Testing
@testable import TrifolaKit

@Suite("BLOCKED notification actions")
struct NotificationActionsTests {
    private final class FakeCenter: NotificationCategoryCenter {
        var categories: Set<NotificationCategoryDescriptor> = []
        func install(categories: Set<NotificationCategoryDescriptor>) {
            self.categories = categories
        }
    }

    @Test func registersExactlyOneCategoryWithShowAndSnooze() {
        let center = FakeCenter()
        BlockedNotificationCategory.register(on: center)

        #expect(center.categories == [BlockedNotificationCategory.descriptor])
        #expect(center.categories.first?.actions.map(\.identifier) == [
            BlockedNotificationCategory.showAction,
            BlockedNotificationCategory.snoozeAction,
        ])
        #expect(center.categories.first?.actions.first?.opensApp == true)
        #expect(center.categories.first?.actions.last?.opensApp == false)
    }

    @Test func routesExplicitAndDefaultActions() {
        #expect(BlockedNotificationCategory.route(
            actionIdentifier: BlockedNotificationCategory.showAction,
            defaultActionIdentifier: "system.default") == .show)
        #expect(BlockedNotificationCategory.route(
            actionIdentifier: "system.default",
            defaultActionIdentifier: "system.default") == .show)
        #expect(BlockedNotificationCategory.route(
            actionIdentifier: BlockedNotificationCategory.snoozeAction,
            defaultActionIdentifier: "system.default") == .snoozeOneHour)
        #expect(BlockedNotificationCategory.route(
            actionIdentifier: "system.dismiss",
            defaultActionIdentifier: "system.default") == .dismiss)
    }
}
