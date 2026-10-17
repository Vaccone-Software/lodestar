import AppKit
import Stoic
import StoicHTTP
import StoicTesting
import XCTest
@testable import LodestarCore
@testable import lodestar

/// The Send Feedback window over a real queue on a real directory, with the
/// site played by a script and time by a `TestClock`: everything between the
/// person's Send and the network is the code that ships.
@MainActor
final class FeedbackRig {
    static let thanks = ScriptedTransport.Step.json(#"{"ok":true}"#)
    static let offline = ScriptedTransport.Step.failure(.notConnectedToInternet)

    let directory: URL
    let transport = ScriptedTransport()
    /// A pasteboard of the test's own: the clipboard of the Lodestar that
    /// is running on the Mac records every write to the general one.
    let board = NSPasteboard(name: NSPasteboard.Name("lodestar.tests.feedback.\(UUID().uuidString)"))
    let queue: FeedbackQueue
    let controller: FeedbackController

    /// A rig over `directory`, a new one if none: a second rig over the same
    /// directory, after the first has shut down, is a relaunch.
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-feedback-\(UUID().uuidString)", isDirectory: true)
        queue = FeedbackQueue(directory: self.directory, client: Feedback.client(transport: transport))
        controller = FeedbackController(queue: queue)
        controller.pasteboard = board
        controller.report = { "REPORT" }
        board.clearContents()
    }

    /// What the site answers, one step per request, then the last again.
    func script(_ steps: [ScriptedTransport.Step]) {
        transport.on(.post(Feedback.path, body: [], contentType: "application/json"), respond: steps)
    }

    /// Fills the window and presses Send, and waits until the window has
    /// shown what came of it.
    func send(_ message: String, replyTo: String = "", attachReport: Bool = false) async {
        controller.fill(message: message, replyTo: replyTo, attachReport: attachReport)
        controller.pressSend()
        await controller.settled()
    }

    func body(_ index: Int = 0) -> [String: String] {
        guard let bytes = transport.requests[index].body else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: String] ?? [:]
    }

    func key(_ index: Int = 0) -> String? {
        transport.requests[index].headers["Idempotency-Key"]
    }

    var messages: [String] { (0..<transport.requestCount).map { body($0)["message"] ?? "" } }

    func shutdown() async {
        await queue.shutdown()
        controller.close()
        board.releaseGlobally()
    }

    /// Runs `body` on a rig under a test clock, and shuts it down after.
    static func run(directory: URL? = nil, _ body: (FeedbackRig, TestClock) async throws -> Void) async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let rig = FeedbackRig(directory: directory)
            defer { if directory == nil { try? FileManager.default.removeItem(at: rig.directory) } }
            rig.controller.show()
            do {
                try await body(rig, clock)
            } catch {
                await rig.shutdown()
                throw error
            }
            await rig.shutdown()
        }
    }
}
