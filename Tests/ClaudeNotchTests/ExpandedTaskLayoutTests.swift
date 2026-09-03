import Testing
@testable import ClaudeNotch

@Suite struct ExpandedTaskLayoutTests {
    @MainActor @Test func recentTasksUseTheSameThreeRowLimitForEveryProvider() {
        #expect(AppModel.expandedTaskLimit == 3)
    }

    @MainActor @Test func threeTaskRowsReserveEnoughSpaceForTheList() {
        #expect(AppModel.expandedDropHeight(sessionCount: 3, hasStatus: false) == 294)
        #expect(AppModel.expandedDropHeight(sessionCount: 3, hasStatus: true) == 314)
    }

    @MainActor @Test func shorterListsDoNotKeepEmptyTaskSpace() {
        #expect(AppModel.expandedDropHeight(sessionCount: 1, hasStatus: false) == 234)
    }
}
