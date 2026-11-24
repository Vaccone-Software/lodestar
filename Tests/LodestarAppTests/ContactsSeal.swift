import Foundation
import ObjectiveC
import Synchronization

// The suite never reaches the Mac's Contacts. The way it did: the app links
// AuthenticationServices (swift-huggingface's OAuth manager), which links
// ContactsUI and ContactsUICore. XCTest builds its suite by asking the
// runtime for every class (objc_copyClassList), and realizing
// ContactsUICore's Swift `ContactCardDetailsState` messages CNContactStore
// for the first time, whose `+initialize` opens the shared address book on a
// background queue: a connection to contactsd and a read of
// ~/Library/Application Support/AddressBook, from a process that never
// asked for a contact. It happens only when a run is not narrowed to named
// classes, and it is the process's own doing, not a test's.
//
// So the class's `+initialize` is replaced, before XCTest builds the suite,
// with one that does nothing and counts. Nothing in Sources or Tests uses
// Contacts; if one did, it would meet a store that never opened. Only this
// one class method of this one class changes, in the test process only.

enum ContactsSeal {
    private static let refused = Atomic<Int>(0)
    private static let installedImp = Mutex<IMP?>(nil)

    /// How many times the framework's `+initialize` was asked for and refused.
    static var refusals: Int { refused.load(ordering: .relaxed) }

    /// The implementation this seal put in place, when the class exists.
    static var imp: IMP? { installedImp.withLock { $0 } }

    /// The class method as the runtime has it now.
    static var currentImp: IMP? {
        guard let cls = objc_lookUpClass("CNContactStore"),
              let method = class_getClassMethod(cls, NSSelectorFromString("initialize")) else { return nil }
        return method_getImplementation(method)
    }

    static func install() {
        guard installedImp.withLock({ $0 }) == nil,
              objc_lookUpClass("CNContactStore") != nil,
              let meta = objc_getMetaClass("CNContactStore") as? AnyClass else { return }
        let block: @convention(block) (AnyObject) -> Void = { _ in refused.add(1, ordering: .relaxed) }
        let imp = imp_implementationWithBlock(block)
        // The metaclass by name: handing the class itself to anything that
        // takes `Any` sends it a message, and the first message is the
        // `+initialize` being avoided.
        // Replaces the class's own method, never NSObject's: the metaclass
        // gets the override whether or not it had one.
        class_replaceMethod(meta, NSSelectorFromString("initialize"), imp, "v@:")
        installedImp.withLock { $0 = imp }
    }
}

// A constructor in the bundle's own image, like LeakGuard's: it runs when
// xctest loads the bundle, before XCTest lists the classes.
@section("__DATA,__mod_init_func")
@used
private let installContactsSeal: @convention(c) () -> Void = { ContactsSeal.install() }
