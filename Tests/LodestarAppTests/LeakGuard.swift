import AppKit
import ObjectiveC
import XCTest
@testable import LodestarCore

// The guard that fails a test for leaving a static changed. It watches what
// each bundle's LeakRegistry names; Overrides.swift is how a test changes one
// and puts it back. This file is in both test bundles (LodestarCoreTests
// links to it).

/// A static the guard watches: how to take its value, say whether it has
/// moved, and put it back.
struct Watched {
    let name: String
    let take: () -> Taken

    struct Taken {
        /// What it was and what it is, when they differ.
        let moved: () -> (before: String, after: String)?
        let restore: () -> Void
    }

    /// A value as a person reads it: an optional without its wrapper.
    static func describe<Value>(_ value: Value) -> String {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return String(describing: value) }
        return mirror.children.first.map { describe($0.value) } ?? "nil"
    }

    /// A static's value, compared by `same`.
    init<Value>(_ name: String, read: @escaping () -> Value, write: @escaping (Value) -> Void,
                same: @escaping (Value, Value) -> Bool, shown: @escaping (Value) -> String = Watched.describe) {
        self.name = name
        take = {
            let before = read()
            return Taken(moved: { let after = read(); return same(before, after) ? nil : (shown(before), shown(after)) },
                         restore: { write(before) })
        }
    }

    /// A static of a type that compares: `frameOverride`, a delay, a switch.
    static func value<Owner, Value: Equatable>(_ name: String, _ keyPath: ReferenceWritableKeyPath<Owner.Type, Value>) -> Watched {
        let owner = Owner.self
        return Watched(name, read: { owner[keyPath: keyPath] }, write: { owner[keyPath: keyPath] = $0 }, same: ==)
    }

    /// A static holding a closure, which cannot be compared: it is compared by
    /// what `answer` reads off it (what it returns, or only that it is set).
    static func closure<Owner, Function>(_ name: String, _ keyPath: ReferenceWritableKeyPath<Owner.Type, Function>,
                                         answer: @escaping (Function) -> String) -> Watched {
        let owner = Owner.self
        return Watched(name, read: { owner[keyPath: keyPath] }, write: { owner[keyPath: keyPath] = $0 },
                       same: { answer($0) == answer($1) }, shown: answer)
    }

    /// A fixture a test installs once for the whole process, such as the
    /// pronunciation dictionary, which is read from the repository the first
    /// time a stage needs it and never changes. Going from nothing to a
    /// fixture is not a leak; going from one to anything else is.
    static func fixture<Owner, Value: AnyObject>(_ name: String, _ keyPath: ReferenceWritableKeyPath<Owner.Type, Value?>) -> Watched {
        let owner = Owner.self
        return Watched(name, read: { owner[keyPath: keyPath] }, write: { owner[keyPath: keyPath] = $0 },
                       same: { $0 == nil || $0 === $1 }, shown: { $0.map { "\(type(of: $0))" } ?? "none" })
    }

    /// The same, for a fixture that compares by value.
    static func fixture<Owner, Value: Equatable>(_ name: String, _ keyPath: ReferenceWritableKeyPath<Owner.Type, Value?>) -> Watched {
        let owner = Owner.self
        return Watched(name, read: { owner[keyPath: keyPath] }, write: { owner[keyPath: keyPath] = $0 },
                       same: { $0 == nil || $0 == $1 })
    }
}

/// Fails the test that leaves a watched static changed, and puts it back so
/// the next test does not inherit the leak.
///
/// It wraps `XCTestCase.invokeTest`, which runs a test's `setUp`, the test,
/// its teardown blocks and `tearDown`, so the check comes after every way a
/// test can restore a static and the failure belongs to that test. An
/// `XCTestObservation` cannot do this: `testCaseDidFinish` comes after the
/// test's run has stopped, and recording an issue there aborts the process
/// (XCTestRun.m:207), and a teardown block registered from `testCaseWillStart`
/// runs before `tearDown()`, so it would fail every test that restores a
/// static there.
///
/// It is installed when the bundle loads, by a constructor (the section
/// below), because `xctest -XCTest SomeClass` runs only the classes it is
/// given and nothing else in the bundle is guaranteed to run first.
enum LeakGuard {
    /// The statics both bundles' tests change: LodestarCore's.
    static let core: [Watched] = [
        .value("ActivePolicy.frameOverride", \ActivePolicy.Type.frameOverride),
        .value("ActivePolicy.mode", \ActivePolicy.Type.mode),
        .value("Log.stdoutEnabled", \Log.Type.stdoutEnabled),
        .value("Log.fileEnabled", \Log.Type.fileEnabled),
        .closure("Log.listener", \Log.Type.listener) { $0 == nil ? "none" : "a listener" },
        .value("ControlSocket.probeWait", \ControlSocket.Type.probeWait),
        .fixture("CommonWords.frequentListURL", \CommonWords.Type.frequentListURL),
    ]

    /// The leaks `body` made, as one line each, each put back.
    static func leaks(during body: () throws -> Void) rethrows -> [String] {
        let taken = LeakRegistry.watched.map { ($0.name, $0.take()) }
        try body()
        return taken.compactMap { name, taken in
            guard let (before, after) = taken.moved() else { return nil }
            taken.restore()
            return "\(name) was \(before) when this test began and is \(after) after it. Set it with setOverride or "
                + "withOverride, which put it back, or put it back in tearDown."
        }
    }

    nonisolated(unsafe) private(set) static var installed = false

    fileprivate static func install() {
        guard !installed, let method = class_getInstanceMethod(XCTestCase.self, #selector(XCTestCase.invokeTest)) else { return }
        installed = true
        typealias Invoke = @convention(c) (XCTestCase, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Invoke.self)
        let block: @convention(block) (XCTestCase) -> Void = { test in
            let leaks = leaks { original(test, #selector(XCTestCase.invokeTest)) }
            for leak in leaks {
                test.record(XCTIssue(type: .assertionFailure, compactDescription: leak,
                                     sourceCodeContext: XCTSourceCodeContext(location: XCTSourceCodeLocation(
                                        filePath: #filePath, lineNumber: #line))))
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

// A constructor in the bundle's own image: it runs when xctest loads the
// bundle, before any class is chosen or run. (SwiftPM's generated Info.plist
// has no NSPrincipalClass to name an observer; a class's `setUp()` runs only
// for the classes selected.) Needs SymbolLinkageMarkers, set on both test
// targets in Package.swift.
@section("__DATA,__mod_init_func")
@used
private let installLeakGuard: @convention(c) () -> Void = { LeakGuard.install() }
