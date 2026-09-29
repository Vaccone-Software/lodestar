import Metal
import MLX
import XCTest
@testable import lodestar

/// Every draw from MLX's global random key leaves an unevaluated split
/// behind, and a model load makes a thousand of them. Settled after a
/// load, the chain is a value again and what it held is free.
final class EditorRandomStateTests: XCTestCase {
    private func inUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }

    func testSettlingTheRandomKeyFreesTheChainALoadLeaves() throws {
        // MLX runs on the GPU, and a hosted runner's virtual machine has
        // none: the first draw raises inside MLX and takes the whole test
        // process with it, silently, along with every test of its shard
        // that had not run yet. This measures Apple silicon's allocator;
        // it is not something a runner could tell us.
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil || ProcessInfo.processInfo.environment["CI"] != nil,
                      "needs a GPU, which a hosted runner does not have")
        EditorModel.settleRandomState()
        let before = inUse()
        for _ in 0..<5_000 { _ = MLXRandom.globalState.next() }   // a load's worth, several times over
        let grown = inUse() - before
        XCTAssertGreaterThan(grown, 5 * 1024 * 1024, "the chain is held while nothing evaluates it")
        EditorModel.settleRandomState()
        XCTAssertLessThan(inUse() - before, grown / 4, "settled, it is let go")
    }
}
