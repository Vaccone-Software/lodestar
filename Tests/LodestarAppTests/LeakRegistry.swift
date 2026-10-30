import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Every process-wide static this bundle's tests change, which LeakGuard
/// watches (Overrides.swift). A test that needs a new one adds it here.
///
/// Not here, because a closure cannot be compared and these answer nothing a
/// test could read off them: `Pointer.post`, `Sounds.play`,
/// `FileSense.thumbnailer`, `FileSense.dataless` and `FileSense.wait`.
/// LeakGuardTests reads the tests' sources instead and fails any that
/// assigns one outside the stage.
enum LeakRegistry {
    static let watched: [Watched] = LeakGuard.core + [
        .closure("BarTheme.accentColor", \BarTheme.Type.accentColor) { shown($0()) },
        .closure("Accessibility.reduceMotion", \Accessibility.Type.reduceMotion) { "\($0())" },
        .closure("Accessibility.increaseContrast", \Accessibility.Type.increaseContrast) { "\($0())" },
        .value("FileSense.deadline", \FileSense.Type.deadline),
        .value("ClipboardStore.deletionDelay", \ClipboardStore.Type.deletionDelay),
        .value("ClipboardStore.foldDelay", \ClipboardStore.Type.foldDelay),
        .value("ClipboardStore.prunePeriod", \ClipboardStore.Type.prunePeriod),
        .value("ClipboardController.presenceDeadline", \ClipboardController.Type.presenceDeadline),
        .object("DictationLexicon.given", \DictationLexicon.Type.given),
        Watched("NSApplication.appearance", read: { NSApp?.appearance?.name.rawValue },
                write: { NSApp?.appearance = $0.flatMap { NSAppearance(named: NSAppearance.Name($0)) } }, same: ==),
        Watched("EyeComfortState", read: { EyeComfortState.shared.enabled ? EyeComfortState.shared.level : nil },
                write: { EyeComfortState.shared.set(enabled: $0 != nil, level: $0 ?? 1) }, same: ==),
    ]

    /// The settings of the Mac a surface would read, set to the suite's own
    /// when the bundle loads (LeakGuard), so no test inherits what the Mac
    /// happens to be set to and a runner's Mac and a desk's run the same
    /// process:
    ///
    /// - the look: Dark, which is the look the suite was written at and the
    ///   one Stage sets. `scripts/test.sh` under TEST_LIGHT starts the process
    ///   with `NSRequiresAquaSystemAppearance`, which is the one explicit way
    ///   to ask for Light, so that is Light here;
    /// - Reduce Motion and Increase Contrast, off (a test that turns one on
    ///   says so, and LeakGuard puts it back to this);
    /// - the scale every window reports (DisplayScale);
    /// - the display: Screens answers the stand-in under a test run.
    ///
    /// Reduce Transparency is not pinned because nothing in Sources reads it.
    static func pinEnvironment() {
        Accessibility.reduceMotion = { false }
        Accessibility.increaseContrast = { false }
        NSApplication.shared.appearance = suiteAppearance
        DisplayScale.pin()
    }

    /// The look the process is pinned to, and the one a test that changed it
    /// puts back: never `nil`, which would be the Mac's own.
    static var suiteAppearance: NSAppearance? {
        let light = UserDefaults.standard.bool(forKey: "NSRequiresAquaSystemAppearance")
        return NSAppearance(named: light ? .aqua : .darkAqua)
    }

    /// The repository's word lists, installed when the bundle loads (LeakGuard):
    /// the pronunciation dictionary the stage's matcher reads, and the
    /// frequency list `CommonWords` reads once and keeps. No test installs or
    /// changes them, and the guard fails one that does.
    static func installFixtures() {
        let packaging = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("packaging")
        CommonWords.frequentListURL = packaging.appendingPathComponent("common-words.txt")
        DictationLexicon.given = (try? String(contentsOf: packaging.appendingPathComponent("cmudict.dict"), encoding: .utf8))
            .map { Pronouncer(cmu: $0) } ?? Pronouncer()
    }

    /// A colour as the three numbers a person would compare, drawn in the
    /// look in force.
    private static func shown(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(format: "sRGB %.3f %.3f %.3f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }
}
