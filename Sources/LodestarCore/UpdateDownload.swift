import Foundation
import Stoic
import StoicDownloads
import StoicHTTP
import StoicStore

/// The update's zip, fetched the way a model is: resumable, bounded, hashed
/// as it streams, and delivered whole or not at all.
///
/// A zip is some twenty megabytes, and a Mac that is asleep, or on a hotel's
/// Wi-Fi, may take longer than the three minutes the whole transfer once had
/// (a cap that cut a slow transfer that was getting there, and left the run
/// `.checking`, which refuses every later check). Now a transfer that is
/// moving is never cut: what bounds it is a deadline (`deadline`, half an
/// hour) that is long for a healthy one and short of the days a stuck one
/// would hold the single-flight phase, and a limit on its size (`byteLimit`,
/// a gigabyte) that stops a server that sends without end.
///
/// What it is checked against is GitHub's own SHA-256 of the asset, when the
/// feed carries it (the preview feed does; the site's stable answer passes it
/// on). It is a check on the transfer, not on the release: the codesign
/// checks that follow are the gate, and a digest that does not match fails the
/// update as a download that failed does.
public enum UpdateDownload {
    /// The most a zip may be.
    public static let byteLimit = 1 << 30

    /// How long a download may take in all, from the first request to the
    /// last byte, waits included.
    public static let deadline = Duration.seconds(30 * 60)

    /// The session: a quarter of a minute of silence is a cut (which is then
    /// resumed), and there is no limit on the whole transfer.
    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return configuration
    }

    /// The client the zip comes through: GitHub, one try for each request (the
    /// downloader is the retry layer), and who is asking.
    public static func client(transport: (any HTTPTransport)? = nil) -> HTTPClient {
        var policy = HTTPPolicy.singleAttempt
        policy.attemptTimeout = .seconds(30)
        return HTTPClient(
            base: URL(string: "https://github.com")!, policy: policy,
            transport: transport ?? URLSessionTransport(configuration: sessionConfiguration()),
            headers: ["User-Agent": "lodestar/\(Lodestar.version)"], label: "update-download")
    }

    /// The digest the feed names, if it names one this app can check: a
    /// SHA-256. Anything else is not a check that can be made, and is not an
    /// error: the update goes on to the signature checks as it did before the
    /// feed said anything.
    public static func digest(of release: Updater.Release) -> ContentDigest? {
        guard let text = release.zipDigest, text.hasPrefix("sha256:") else { return nil }
        return try? .sha256(String(text.dropFirst("sha256:".count)))
    }

    /// What went wrong, in the words the log carries: a digest that is not
    /// the one GitHub names is said as that, with both.
    public static func problem(_ error: any Error, release: Updater.Release) -> String {
        if let error = error as? DownloadError, case .digestMismatch(let expected, let actual, _) = error {
            return "the zip is \(actual), and GitHub says \(release.zipName) is \(expected.hex): it is not installed"
        }
        return String(describing: error)
    }

    /// Fetches `release`'s zip to `destination`, replacing what is there.
    ///
    /// - Parameters:
    ///   - progress: The share of the zip that is in hand, 0 to 1, as the
    ///     downloader reports it (at most twice a second); only when the size
    ///     is known (the response's `Content-Length` will do).
    /// - Throws: `DownloadError`, or `CancellationError`.
    @discardableResult
    public static func fetch(
        _ release: Updater.Release, to destination: URL, client: HTTPClient = client(),
        fileSystem: any FileSystem = PosixFileSystem(), policy: DownloadPolicy = .standard,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DownloadResult {
        guard let url = URL(string: release.zipURL) else { throw URLError(.badURL) }
        let download = Download(
            url, to: destination.path, digest: digest(of: release), byteLimit: byteLimit)
        let downloader = Downloader(client: client, fileSystem: fileSystem, policy: policy, label: "update-download")
        return try await withDeadline(.after(deadline)) {
            try await downloader.download(download) { report in
                guard report.phase == .downloading, let progress else { return }
                // The feed carries no size, so the share is known once the response's
                // Content-Length is: the downloader's `fraction`.
                guard let fraction = report.fraction else { return }
                progress(fraction)
            }
        }
    }
}
