import Foundation
import ObjectiveC
import XCTest

/// The process never opens the Mac's address book (ContactsSeal.swift says
/// how it used to, and why).
final class ContactsSealTests: XCTestCase {
    func testTheContactsFrameworkIsInTheProcessAndItsStartIsOurs() throws {
        let cls = try XCTUnwrap(objc_lookUpClass("CNContactStore"),
                                "the app links Contacts through AuthenticationServices; if it no longer does, this seal can go")
        let imp = try XCTUnwrap(ContactsSeal.currentImp)
        XCTAssertEqual(imp, ContactsSeal.imp, "CNContactStore's +initialize is not the seal's, so the first message to the class opens the real address book")
        XCTAssertNotNil(class_getClassMethod(cls, NSSelectorFromString("initialize")))
    }

    func testAskingTheClassToInitializeDoesNothingButCount() throws {
        let cls = try XCTUnwrap(objc_lookUpClass("CNContactStore"))
        // The real +initialize is not called with the seal missing: that is the leak.
        guard ContactsSeal.currentImp == ContactsSeal.imp else { return XCTFail("the seal is not in place") }
        // The first message to a class is what runs +initialize, once; this
        // one is that message when no earlier test sent it.
        _ = (cls as AnyObject).description
        let before = ContactsSeal.refusals
        _ = (cls as AnyObject).perform(NSSelectorFromString("initialize"))
        XCTAssertEqual(ContactsSeal.refusals, before + 1)
    }
}
