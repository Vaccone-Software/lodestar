import Foundation
import LodestarCore

// The one-copy rule, with real processes. `copy` is a stand-in for a running
// Lodestar: it takes over the way the app does on launch, says so on its
// standard output a line at a time, and on SIGTERM shuts down the way the app
// does (a pause for the windows it restores, the pid file removed if it is
// still its own, exit 0). With `--lock` it is a build that holds the instance
// lock (`SingleInstance`); without, it is an older build, which takes over by
// the pid file alone, as every build before the lock did. `stranger` is an
// unrelated process that writes down every signal it is sent. Both take their
// files from the command line, never from the person's folders, and neither
// writes the person's log.

private func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// One line, on its way out at once: the test reads these to know what the
/// process has done.
private func say(_ line: String) {
    print(line)
    fflush(stdout)
}

func runCopy(_ arguments: inout [String]) {
    Log.fileEnabled = false
    guard let pidPath = option("--pid-file", in: arguments) else {
        fputs("probe copy: --pid-file is required\n", stderr)
        exit(2)
    }
    let pidFile = URL(fileURLWithPath: pidPath)
    let lockFile = option("--lock", in: arguments).map { URL(fileURLWithPath: $0) }
    let waitSeconds = option("--wait", in: arguments).flatMap(Double.init) ?? 5
    let ignoreTerm = arguments.contains("--ignore-term")
    let quitSeconds = option("--quit-seconds", in: arguments).flatMap(Double.init) ?? 0
    let maxSeconds = option("--max-seconds", in: arguments).flatMap(Double.init) ?? 60
    let me = ProcessInfo.processInfo.processIdentifier
    // A probe that a failed test leaves behind ends itself.
    DispatchQueue.global().asyncAfter(deadline: .now() + maxSeconds) { exit(3) }

    say("BOOT \(me)")
    if let lockFile {
        let outcome = SingleInstance(files: .init(lock: lockFile, pid: pidFile)).takeOver(wait: waitSeconds)
        say("TOOK holds=\(outcome.holdsLock) replaced=\(outcome.replaced.map(String.init) ?? "-") "
            + "standing=\(outcome.standing.map(String.init) ?? "-")")
    } else {
        olderBuildTakeOver(pidFile: pidFile, selfPid: me, wait: waitSeconds)
    }
    if arguments.contains("--spawn-child") {
        // A child that outlives this process, started the way the app starts
        // its helpers: it must not keep the lock this process dies holding.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["300"]
        try? child.run()
        say("CHILD \(child.processIdentifier)")
    }

    // The app installs its handler well after the takeover; a signal before
    // it takes the default action, which is to end.
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
        say("TERMED \(me)")
        if ignoreTerm { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + quitSeconds) {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == me {
                try? FileManager.default.removeItem(at: pidFile)
            }
            say("EXITING \(me)")
            exit(0)
        }
    }
    source.resume()
    say("READY \(me)")
    dispatchMain()
}

func runStranger(_ arguments: inout [String]) {
    Log.fileEnabled = false
    guard let logPath = option("--signal-log", in: arguments) else {
        fputs("probe stranger: --signal-log is required\n", stderr)
        exit(2)
    }
    let maxSeconds = option("--max-seconds", in: arguments).flatMap(Double.init) ?? 60
    DispatchQueue.global().asyncAfter(deadline: .now() + maxSeconds) { exit(3) }
    var sources: [DispatchSourceSignal] = []
    for (name, number) in [("TERM", SIGTERM), ("HUP", SIGHUP), ("INT", SIGINT), ("USR1", SIGUSR1), ("USR2", SIGUSR2),
                           ("QUIT", SIGQUIT), ("ALRM", SIGALRM)] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            if let handle = FileHandle(forWritingAtPath: logPath) ?? {
                FileManager.default.createFile(atPath: logPath, contents: nil)
                return FileHandle(forWritingAtPath: logPath)
            }() {
                handle.seekToEndOfFile()
                handle.write(Data("\(name)\n".utf8))
                try? handle.close()
            }
        }
        source.resume()
        sources.append(source)
    }
    say("READY \(ProcessInfo.processInfo.processIdentifier)")
    dispatchMain()
}

/// What every build before the lock did on launch, as it was: read the pid
/// file, ask whatever process it names to quit, wait for it to go, write this
/// pid. Kept here as the older build that the tests launch beside a newer one.
private func olderBuildTakeOver(pidFile: URL, selfPid: Int32, wait: Double) {
    if let text = try? String(contentsOf: pidFile, encoding: .utf8),
       let oldPid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
       oldPid != selfPid, kill(oldPid, 0) == 0 {
        kill(oldPid, SIGTERM)
        let deadline = Date().addingTimeInterval(wait)
        while kill(oldPid, 0) == 0, Date() < deadline { usleep(25_000) }
    }
    try? "\(selfPid)".write(to: pidFile, atomically: true, encoding: .utf8)
}
