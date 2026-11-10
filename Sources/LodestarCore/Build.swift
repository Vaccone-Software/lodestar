/// The identifier the app and its two XPC services are each given, and
/// that StoicXPC compares in its handshake (design/25, rule 3): a service
/// of another build than the app that started it is refused, never decoded.
///
/// It is compiled into this module, which the app and both services link,
/// so the three carry the same one only when they were built together. An
/// app replaced on disk while it runs (an update) starts the services of the
/// new bundle, whose identifier is the new version's, and the running app
/// is refused them (`XPCCallError.buildMismatch`) until it restarts.
///
/// - A release is its version: ship.sh never ships one twice.
/// - A development build (`make-app.sh` under `LODESTAR_DEVELOPMENT`) is
///   the version of the release it was made over, so two development builds
///   of one version cannot tell each other apart: the wire types are the
///   only thing that can differ between them that would be decoded wrongly,
///   and an app and its services of one bundle are always built together.
/// - A debug build (`swift build`, the tests) says so, so a debug app never
///   talks to a release service, which the bundle never carries anyway.
public enum Build {
    public static let id: String = {
        #if DEBUG
        "\(Lodestar.version)-debug"
        #else
        Lodestar.version
        #endif
    }()
}
