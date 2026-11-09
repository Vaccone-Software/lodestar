import Foundation
import LodestarCore

// Lodestar's clipboard reader: an XPC service in the app's bundle
// (Contents/XPCServices), so a copy whose read waits on its app or the
// network waits here, on this process's main thread, and never on the
// thread that answers the keys. Everything it does is
// PasteboardReaderService, in LodestarCore, where the tests host the
// same object behind an anonymous listener.

final class ReaderDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PasteboardReaderXPC.self)
        connection.exportedObject = PasteboardReaderService()
        connection.resume()
        return true
    }
}

let delegate = ReaderDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
