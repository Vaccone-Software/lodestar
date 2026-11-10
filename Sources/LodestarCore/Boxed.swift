/// A value kept on the heap and not in the struct that holds it, so a struct
/// with a few very large optional columns costs one pointer for each of them
/// until one is set.
///
/// It keeps value semantics: copies share the storage, and a change is made
/// in the storage only by whoever holds the one reference to it, otherwise to
/// a copy of it first. Eight bytes however big `Value` is, and empty is nil.
struct Boxed<Value: Equatable & Sendable>: Equatable, Sendable {
    /// Mutated only while the one reference to it is the one mutating it
    /// (`update`), so a value shared between threads is never written to.
    private final class Storage: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private var storage: Storage?

    init() {}

    var isEmpty: Bool { storage == nil }

    /// The value, or nil when none is held. Setting nil lets it go.
    var value: Value? {
        get { storage?.value }
        set { storage = newValue.map(Storage.init) }
    }

    /// What `body` makes of the held value, read where it is, not from a copy
    /// of it: nil when none is held.
    func read<Result>(_ body: (Value) -> Result) -> Result? {
        storage.map { body($0.value) }
    }

    /// Change the held value in place, made from `make` first when there is
    /// none, and copied first when another copy of this holds it too.
    mutating func update(creating make: @autoclosure () -> Value, _ body: (inout Value) -> Void) {
        if storage == nil {
            storage = Storage(make())
        } else if !isKnownUniquelyReferenced(&storage) {
            storage = Storage(storage!.value)
        }
        body(&storage!.value)
    }

    static func == (lhs: Boxed, rhs: Boxed) -> Bool {
        lhs.storage === rhs.storage || lhs.storage?.value == rhs.storage?.value
    }
}
