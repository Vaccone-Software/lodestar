import Foundation
import LodestarCore
import LodestarMLX
import Stoic
import StoicXPC

// Lodestar's models service: an XPC service in the app's bundle
// (Contents/XPCServices), the one process that links MLX. The editor's
// language model, dictation's model for what was meant and the Qwen3-ASR
// ear all evaluate here, one at a time on the process's MLX lane, so a
// generation that stops answering is ended with this process, its memory
// goes with it, and the app's own exit never runs a destructor of MLX's.
// Everything it does is ModelsService, in LodestarCore, on an XPCHost: the
// host answers and refuses, cancels, ends the process when a handler
// ignores its cancellation (the watchdog) and when nothing is held and
// nothing asked for ten seconds (idleExit); the tests host the same object
// with a fake engine on StoicXPC's simulated service.
//
// MLX finds its compiled kernels in this bundle's Resources
// (mlx-swift_Cmlx.bundle), where make-app.sh puts them.

// The app's log, appended with O_APPEND as every writer does; never stdout,
// which launchd sends nowhere. Stoic's warnings and errors, and the XPC
// lifecycle at info, join it.
Log.stdoutEnabled = false
withAmbient({ $0.instrumentation = CompositeInstrumentation([$0.instrumentation, StoicLog(alsoInfoFor: ["xpc."])]) }) {
    let host = XPCHost(build: Build.id, policy: XPCHostPolicy(idleExit: Models.idleExit))
    let service = ModelsService(host: host, engine: MLXModelsEngine())
    withExtendedLifetime(service) { host.run() }
}
