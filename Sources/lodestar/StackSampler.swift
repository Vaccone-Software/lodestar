import Darwin
import Foundation

/// Another thread's stack, read from inside the process: what a thread
/// that has stopped answering is doing, read while it is still doing it
/// (`MainThreadWatchdog`). The watchdog logged that main was late, and for
/// how long, 123 times in twenty days, and never once what held it.
///
/// The thread is suspended for the microseconds it takes to read its
/// registers and follow its frame pointers, and nothing in that window may
/// take a lock the suspended thread could be holding: no allocation, no
/// logging, no symbol lookup. So the addresses go into a buffer made
/// beforehand, and they are named only after the thread runs again.
struct StackSampler {
    let thread: thread_t
    /// The thread's stack, [low, high). A frame pointer is followed only
    /// inside it, so a frame that is not one ends the walk, never the
    /// process.
    let stackLow: UInt
    let stackHigh: UInt

    /// The most frames read from one stack.
    static let depth = 64

    /// The calling thread, to be read later from another one.
    static func current() -> StackSampler {
        let me = pthread_self()
        let high = UInt(bitPattern: pthread_get_stackaddr_np(me))
        let size = UInt(pthread_get_stacksize_np(me))
        return StackSampler(thread: pthread_mach_thread_np(me), stackLow: high - size, stackHigh: high)
    }

    /// The thread's program counter and then each return address, innermost
    /// first; nil when it could not be read, or when it is the caller's own
    /// (a thread that suspends itself does not come back).
    func addresses() -> [UInt]? {
        guard thread != pthread_mach_thread_np(pthread_self()) else { return nil }
        let buffer = UnsafeMutableBufferPointer<UInt>.allocate(capacity: Self.depth)
        defer { buffer.deallocate() }
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        var count = 0
        guard thread_suspend(thread) == KERN_SUCCESS else { return nil }
        // Suspended: from here to the resume, only registers and the stack.
        let read = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &stateCount)
            }
        }
        if read == KERN_SUCCESS {
            buffer[0] = Self.strip(UInt(state.__pc))
            count = 1
            var frame = UInt(state.__fp)
            while count < Self.depth, frame >= stackLow, frame + 16 <= stackHigh, frame & 7 == 0 {
                let words = UnsafePointer<UInt>(bitPattern: frame)!
                let caller = words[0], returnAddress = Self.strip(words[1])
                guard returnAddress != 0 else { break }
                buffer[count] = returnAddress
                count += 1
                guard caller > frame else { break }
                frame = caller
            }
        }
        thread_resume(thread)
        guard read == KERN_SUCCESS else { return nil }
        return Array(buffer[0..<count])
    }

    /// An address without the signature Apple silicon puts on return
    /// addresses that system code saves: a user address fits in 47 bits
    /// (MACH_VM_MAX_ADDRESS is 0x7FFFFE000000).
    static func strip(_ address: UInt) -> UInt { address & 0x0000_7FFF_FFFF_FFFF }

    /// Each address as the binary and the function it is in. The first is
    /// where the thread was; the rest are return addresses, which point just
    /// past their call, so each is looked up one byte back to land inside the
    /// function that made it.
    static func names(_ addresses: [UInt]) -> [String] {
        addresses.enumerated().map { index, address in
            name(of: index == 0 ? address : address &- 1)
        }
    }

    static func name(of address: UInt) -> String {
        var info = Dl_info()
        guard address != 0, dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
            return String(format: "0x%lx", address)
        }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        guard let symbol = info.dli_sname else {
            return "\(image) +\(address &- UInt(bitPattern: info.dli_fbase))"
        }
        return "\(image) \(shortened(demangled(String(cString: symbol))))"
    }

    /// A Swift name as Swift writes it, or the name unchanged when it is not
    /// one.
    static func demangled(_ symbol: String) -> String {
        guard let readable = symbol.withCString({ swift_demangle($0, strlen($0), nil, nil, 0) }) else { return symbol }
        defer { free(readable) }
        return String(cString: readable)
    }

    /// A line holds a frame: long generic signatures are cut.
    static func shortened(_ name: String, limit: Int = 160) -> String {
        name.count <= limit ? name : String(name.prefix(limit)) + "…"
    }
}

/// The Swift runtime's demangler, exported for tools like this one.
@_silgen_name("swift_demangle")
private func swift_demangle(_ mangledName: UnsafePointer<CChar>?, _ mangledNameLength: Int,
                            _ outputBuffer: UnsafeMutablePointer<CChar>?,
                            _ outputBufferSize: UnsafeMutablePointer<Int>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?
