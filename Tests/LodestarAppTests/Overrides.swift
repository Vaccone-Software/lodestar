import AppKit
import XCTest
@testable import LodestarCore

// A static a test changes is changed for the rest of the process, and which
// tests share a process changes with every run (scripts/test.sh balances the
// shards by the time each class took last). A leak is therefore a red that
// moves: the test that suffers it is never the test that caused it.
//
// So a test changes a static through these, which put it back, and LeakGuard
// fails the test that leaves a watched one changed.
//
// This file is in both test bundles (LodestarCoreTests links to it).

/// `body` with `keyPath` set to `value`, and what it held put back after,
/// whether `body` returns or throws:
///
///     try withOverride(\ActivePolicy.Type.frameOverride, to: Stage.screen) { ... }
func withOverride<Owner, Value, Result>(_ keyPath: ReferenceWritableKeyPath<Owner.Type, Value>, to value: Value,
                                        _ body: () throws -> Result) rethrows -> Result {
    let owner = Owner.self
    let prior = owner[keyPath: keyPath]
    owner[keyPath: keyPath] = value
    defer { owner[keyPath: keyPath] = prior }
    return try body()
}

/// `body` with `frame` standing in for the display the surfaces are laid out on.
func withPresentationFrame<Result>(_ frame: NSRect, _ body: () throws -> Result) rethrows -> Result {
    try withOverride(\ActivePolicy.Type.frameOverride, to: frame, body)
}

extension XCTestCase {
    /// Set `keyPath` to `value` until this test ends, then put back what it
    /// held. Teardown blocks run last in, first out, ahead of `tearDown()`.
    func setOverride<Owner, Value>(_ keyPath: ReferenceWritableKeyPath<Owner.Type, Value>, to value: Value) {
        let owner = Owner.self
        let prior = owner[keyPath: keyPath]
        owner[keyPath: keyPath] = value
        addTeardownBlock { owner[keyPath: keyPath] = prior }
    }
}
