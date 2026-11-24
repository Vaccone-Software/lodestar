import XCTest
@testable import LodestarCore

final class PermissionsTests: XCTestCase {
    func testAnAdministratorIsTheAdminGroup() {
        XCTAssertTrue(Permissions.isAdministrator(groups: [20, 12, 80, 33]))
        XCTAssertFalse(Permissions.isAdministrator(groups: [20, 12, 61]),
                       "a standard account is told before it goes looking for the switch")
        XCTAssertFalse(Permissions.isAdministrator(groups: []))
    }
}
