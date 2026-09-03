import AppKit
import LodestarCore

// One hung app must not freeze the probe.
setGlobalAXTimeout(1.0)

var arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    probe — lodestar slice 0: is a CGWindowID a handle we can build breaths on?

    usage:
      probe check [--prompt]           accessibility trust + window-server reach
      probe displays                   display bounds, their union, the parking point
      probe cg [--all]                 raw window-server list (works without accessibility)
      probe list                       every app's windows with CGWindowIDs (the private-call bridge)
      probe park <wid> [--seconds N] [--sliver]
      probe park --app <name> ...      park a window beyond all displays, then restore it
      probe move <wid> <x> <y> [<w> <h>]
                                       set a frame (size, position, size again)
      probe watch <app> [--seconds N]  log window ids while you close/reopen windows
      probe selection [--write]        which apps expose character geometry and a settable
                                       selection, the two facts a selection mode needs
      probe pressables <app>           the click door's harvest measured: the batched walk's node
                                       count and time, and which elements press outside its role list
      probe selectsense <app> [--units]
                                       select's bench: capture a window by id, read it with both
                                       recognition passes, type every visible word through the
                                       auto-anchoring grammar and report where uniqueness landed
      probe speech [--seconds N] [--words a,b] [--dictation] [--cycle] [--auth]
                                       the draft's questions: latency to first word, revisions,
                                       restart cost, contextual vocabulary, which TCC grant

    the slice-0 questions, and the command that answers each:
      1. does _AXUIElementGetWindow bridge AX windows to real window-server ids?  -> list
      2. does off-screen parking hold, and does the id survive it?                -> park
      3. do ids survive close-and-reopen? (Brave, Ghostty, Proton Mail)           -> watch
    """)
    exit(2)
}

guard !arguments.isEmpty else { usage() }
let command = arguments.removeFirst()

switch command {
case "check": runCheck(&arguments)
case "displays": runDisplays(&arguments)
case "cg": runCG(&arguments)
case "list": runList(&arguments)
case "park": runPark(&arguments)
case "move": runMove(&arguments)
case "watch": runWatch(&arguments)
case "selection": runSelection(&arguments)
case "harvest": runHarvest(&arguments)
case "termtext": runTermtext(&arguments)
case "selectpipe": runSelectPipe(&arguments)
case "selectsense": runSelectSense(&arguments)
case "pressables": runPressables(&arguments)
case "ocrlive": runOCRLive(&arguments)
case "speech": runSpeech(&arguments)
case "help", "--help", "-h": usage()
default:
    fputs("probe: unknown command '\(command)'\n\n", stderr)
    usage()
}
