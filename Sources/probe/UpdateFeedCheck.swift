import Foundation
import LodestarCore

/// `probe update-feed`: one real update check on each channel, through the
/// client the app reads its feed with (`UpdateFeed.client`), and nothing
/// applied. It prints what each channel answered and exits non-zero when
/// either could not be read or did not name a release.
///
/// A build whose update check is broken can never be told of its own fix,
/// and the tests script the network: this is the same code against the two
/// real hosts. release.sh runs it on the build it is about to sign.
func runUpdateFeed() -> Never {
    let done = DispatchSemaphore(value: 0)
    let failed = Flag()
    Task {
        let client = UpdateFeed.client()
        let channels: [(String, URL, Updater.Channel)] = [
            ("stable", Updater.stableURL, .stable),
            ("preview", Updater.previewURL, .preview),
        ]
        for (name, url, channel) in channels {
            do {
                let data = try await UpdateFeed.data(from: url, client: client)
                if let release = Updater.parse(data, channel: channel) {
                    print("✓ \(name): \(release.tag) (\(data.count) bytes from \(url.host ?? "?"))")
                } else {
                    print("✕ \(name): \(data.count) bytes from \(url.host ?? "?") that name no release")
                    failed.set()
                }
            } catch {
                print("✕ \(name): \(UpdateFeed.problem(error))")
                failed.set()
            }
        }
        done.signal()
    }
    done.wait()
    exit(failed.isSet ? 1 : 0)
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
