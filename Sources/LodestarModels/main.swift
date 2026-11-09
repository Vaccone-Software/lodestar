import Foundation
import LodestarCore
import LodestarMLX

// Lodestar's models service: an XPC service in the app's bundle
// (Contents/XPCServices), the one process that links MLX. The editor's
// language model, dictation's model for what was meant and the Qwen3-ASR
// ear all evaluate here, one at a time on the process's MLX lane, so a
// generation that stops answering is ended with this process, its memory
// goes with it, and the app's own exit never runs a destructor of MLX's.
// Everything it does is ModelsService, in LodestarCore, where the tests
// host the same object with a fake engine behind an anonymous listener.
//
// MLX finds its compiled kernels in this bundle's Resources
// (mlx-swift_Cmlx.bundle), where make-app.sh puts them.

final class ModelsDelegate: NSObject, NSXPCListenerDelegate {
    // One object for the process, whichever connection reaches it.
    let service = ModelsService(engine: MLXModelsEngine())

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ModelsXPC.self)
        connection.exportedObject = service
        connection.invalidationHandler = { [service, weak connection] in
            if let connection { service.connectionEnded(connection) }
        }
        connection.resume()
        return true
    }
}

// The app's log, appended with O_APPEND as every writer does; never stdout,
// which launchd sends nowhere.
Log.stdoutEnabled = false
let delegate = ModelsDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
