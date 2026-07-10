import Testing
@testable import TrifolaKit

@Suite("BLOCKED notification actions")
struct NotificationActionsTests {
    private final class FakeCenter: NotificationAuthorizationCenter {
        var categories: Set<NotificationCategoryDescriptor> = []
        var authorizationRequestCount = 0
        func install(categories: Set<NotificationCategoryDescriptor>) {
            self.categories = categories
        }
        func requestAuthorization() {
            authorizationRequestCount += 1
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

    @Test func launchWithOptInOffPerformsNoNotificationCenterWork() {
        let center = FakeCenter()
        let optIn = BlockedNotificationOptIn()

        optIn.activateIfEnabled(false, on: center)

        #expect(center.authorizationRequestCount == 0)
        #expect(center.categories.isEmpty)
    }

    @Test func optInInstallsCategoryAndRequestsAuthorizationExactlyOnce() {
        let center = FakeCenter()
        let optIn = BlockedNotificationOptIn()

        optIn.activateIfEnabled(true, on: center)
        optIn.activateIfEnabled(true, on: center)

        #expect(center.authorizationRequestCount == 1)
        #expect(center.categories == [BlockedNotificationCategory.descriptor])
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
