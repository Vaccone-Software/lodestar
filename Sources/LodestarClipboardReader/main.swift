import Foundation
import LodestarCore
import Stoic
import StoicXPC

// Lodestar's clipboard reader: an XPC service in the app's bundle
// (Contents/XPCServices), so a copy whose read waits on its app or the
// network waits here, on this process's main queue, and never on the
// thread that answers the keys. Everything it does is
// PasteboardReaderService, in LodestarCore, on an XPCHost: the host answers
// and refuses, cancels, and ends the process when a read stays wedged past
// its budget and the grace (the watchdog); the tests host the same object on
// StoicXPC's simulated service.
//
// The service keeps no state and idles out never: it is started by the
// first copy and ended with the app.

Log.stdoutEnabled = false
withAmbient({ $0.instrumentation = CompositeInstrumentation([$0.instrumentation, StoicLog(alsoInfoFor: ["xpc."])]) }) {
    let host = XPCHost(build: Build.id)
    let service = PasteboardReaderService(host: host)
    withExtendedLifetime(service) { host.run() }
}
