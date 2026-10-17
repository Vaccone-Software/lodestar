import Foundation
import StoicSealed
import StoicStore

/// A whole file kept sealed (`era.json`, `blind.json`, `observations.json`,
/// `rollups.json`, a health archive month): one `SealedFile` value, atomic,
/// `0600`, under the context `("lodestar.file", name)`.
///
/// A reader accepts **both forms**, told by the first four bytes: a sealed
/// file opens, a plaintext one is what an earlier build wrote and is read as
/// it is until `migrate` has sealed it. What it never does is read a sealed
/// file that will not open as an absent one: `unavailable` (the key cannot be
/// asked for) and `unreadable` (it will not open) are answers of their own, so
/// no caller can mistake them for "start fresh" and write over what is there.
public struct SealedValueFile: Sendable {
    public static let purpose = "lodestar.file"

    public let url: URL
    /// The file's logical name: authenticated with it, so a file moved to
    /// another name does not open as that one.
    public let name: String
    public let ring: Vault.Ring
    public let fileSystem: any FileSystem

    public init(url: URL, name: String? = nil, ring: Vault.Ring, fileSystem: any FileSystem = OwnerOnlyFileSystem()) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.ring = ring
        self.fileSystem = fileSystem
    }

    private var context: SealContext { SealContext(Self.purpose, name) }

    public enum Contents: Equatable {
        case absent
        /// The bytes, and whether they were sealed on disk.
        case value([UInt8], sealed: Bool)
        /// Sealed, and no key can be asked for it (paused, or the key is gone).
        case unavailable
        /// Sealed, and it would not open: altered, torn, or under a key the ring does not hold.
        case unreadable(String)

        /// The bytes when there are any; nil for absent, unavailable and unreadable.
        public var bytes: [UInt8]? {
            if case .value(let bytes, _) = self { bytes } else { nil }
        }

        /// There is something on disk this read could not give back: callers
        /// that would write must not.
        public var blocksWriting: Bool {
            switch self {
            case .unavailable, .unreadable: true
            case .absent, .value: false
            }
        }
    }

    public func read() -> Contents {
        guard (try? fileSystem.exists(url.path)) == true else { return .absent }
        let bytes: [UInt8]
        do {
            bytes = try fileSystem.readAll(url.path)
        } catch {
            SealedFailures.note(file: name, why: "\(error)")
            return .unreadable("\(error)")
        }
        guard Sealing.isSealed(bytes) else { return .value(bytes, sealed: false) }
        guard let keyring = ring.existing() else { return .unavailable }
        func open() -> Result<[UInt8], SealError> {
            do { return .success(try Sealing.open(bytes, context: context, keyring: keyring)) } catch { return .failure(error) }
        }
        var opened = open()
        // A reader holds the ring it opened with; the app may have rotated it.
        if case .failure(.unknownKey) = opened, (try? keyring.reload()) != nil { opened = open() }
        switch opened {
        case .success(let plain):
            return .value(plain, sealed: true)
        case .failure(let error):
            SealedFailures.note(file: name, why: "\(error)")
            return .unreadable("\(error)")
        }
    }

    public enum Written: Equatable {
        case written
        /// No key to seal with: nothing was written.
        case paused
        case failed(String)
    }

    /// Replace the file with `bytes`, sealed, atomically. A directory sync
    /// that fails after the rename is a warning, not a failure: the file is
    /// the new one (`DurableFile.acceptingUnknownDurability`).
    public func write(_ bytes: [UInt8]) -> Written {
        guard let keyring = ring.keyring() else { return .paused }
        SealedDirectory.ensure(SealedPath.directory(of: url.path), fileSystem: fileSystem)
        let sealed = SealedFile(keyring: keyring, fileSystem: fileSystem)
        do {
            try DurableFile.acceptingUnknownDurability(of: name) {
                do { try sealed.write(bytes, to: url.path, context: context) } catch SealedStoreError.store(let error) { throw error }
            }
            return .written
        } catch {
            return .failed("\(error)")
        }
    }

    // MARK: Migrating

    public enum Migrated: Equatable {
        /// Nothing to do: no file, or it is sealed already.
        case nothing
        /// Plaintext sealed in place: its size.
        case sealed(bytes: Int)
        case paused
        case failed(String)
    }

    /// Seal a plaintext file where it stands. The sealed form is written
    /// beside it under a temporary name, **read back and compared with the
    /// plaintext byte for byte**, renamed over the plaintext (atomic), and the
    /// directory synced. A crash before the rename leaves the plaintext
    /// untouched (and a temporary the next call removes); after it, the sealed
    /// file. The plaintext is never removed by anything but that rename, so
    /// it is never gone before its replacement verified.
    public func migrate() -> Migrated {
        guard (try? fileSystem.exists(url.path)) == true else { return .nothing }
        let plain: [UInt8]
        do {
            plain = try fileSystem.readAll(url.path)
        } catch {
            return .failed("\(error)")
        }
        if Sealing.isSealed(plain) { return .nothing }
        guard let keyring = ring.keyring() else { return .paused }
        let staged = url.path + ".sealing"
        let stagedURL = URL(fileURLWithPath: staged)
        let beside = SealedValueFile(url: stagedURL, name: name, ring: ring, fileSystem: fileSystem)
        do {
            for leftover in [staged, staged + ".tmp"] where (try? fileSystem.exists(leftover)) == true {
                try fileSystem.remove(leftover)
            }
            try SealedFile(keyring: keyring, fileSystem: fileSystem).write(plain, to: staged, context: context)
            guard case .value(let back, sealed: true) = beside.read(), back == plain else {
                try? fileSystem.remove(staged)
                return .failed("the sealed copy did not read back as the plaintext")
            }
            try fileSystem.rename(from: staged, to: url.path)
            try fileSystem.syncDirectory(SealedPath.directory(of: url.path))
            return .sealed(bytes: plain.count)
        } catch {
            return .failed("\(error)")
        }
    }
}
