import Foundation

/// What kind of app the hands were in, so a record can be compared across
/// people who use different apps for the same work: one person's Slack is
/// another's Teams, and a hold time in a terminal is not a hold time in a
/// chat.
///
/// Two answers, kept side by side. **`declared`** is what the app says about
/// itself (`LSApplicationCategoryType`, without its `public.app-category.`
/// prefix), kept as provenance and never edited. It is too coarse and too
/// self-serving to compare on alone: measured on the maker's Mac, Safari,
/// Mail, Teams and Firefox all declare productivity, 1Password and Asana
/// declare developer tools, and Brave and Chrome declare nothing. **`kind`**
/// is Lodestar's class, by bundle identifier for the apps that matter most
/// and from the declared category for the rest, `other` when neither says.
public struct AppCategory: Equatable, Sendable {
    public let kind: String
    public let declared: String?

    public init(kind: String, declared: String?) {
        self.kind = kind
        self.declared = declared
    }

    public static let kinds = ["browser", "terminal", "code", "assistant", "chat", "meeting", "mail",
                               "writing", "office", "design", "media", "reading", "game", "system", "other"]

    public static func of(bundleID: String?, declared raw: String?) -> AppCategory {
        let declared = raw.map(short).flatMap { $0.isEmpty ? nil : $0 }
        let id = bundleID?.lowercased() ?? ""
        if let kind = byBundle[id] ?? byPrefix.first(where: { id.hasPrefix($0.0) })?.1 {
            return AppCategory(kind: kind, declared: declared)
        }
        return AppCategory(kind: declared.flatMap(fromDeclared) ?? "other", declared: declared)
    }

    /// `public.app-category.developer-tools` → `developer-tools`.
    static func short(_ declared: String) -> String {
        let prefix = "public.app-category."
        let lowered = declared.lowercased()
        return lowered.hasPrefix(prefix) ? String(lowered.dropFirst(prefix.count)) : lowered
    }

    /// Only the declared categories that say something true about the hand:
    /// productivity and developer tools say nothing, so they fall to other.
    static func fromDeclared(_ declared: String) -> String? {
        if declared.hasSuffix("games") { return "game" }
        switch declared {
        case "social-networking": return "chat"
        case "music", "video", "entertainment": return "media"
        case "graphics-design", "photography": return "design"
        case "books", "reference", "news", "education": return "reading"
        case "utilities": return "system"
        default: return nil
        }
    }

    static let byPrefix: [(String, String)] = [
        ("com.jetbrains.", "code"),
        ("com.google.chrome", "browser"),
    ]

    static let byBundle: [String: String] = {
        var table: [String: String] = [:]
        func add(_ kind: String, _ ids: [String]) { for id in ids { table[id.lowercased()] = kind } }
        add("browser", ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.brave.Browser",
                        "com.brave.Browser.beta", "com.brave.Browser.nightly", "org.mozilla.firefox",
                        "org.mozilla.firefoxdeveloperedition", "company.thebrowser.Browser", "company.thebrowser.dia",
                        "com.microsoft.edgemac", "net.mullvad.mullvadbrowser", "com.kagi.kagimacOS",
                        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "app.zen-browser.zen",
                        "org.chromium.Chromium"])
        add("terminal", ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                         "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty"])
        add("code", ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
                     "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.google.android.studio",
                     "com.panic.Nova", "com.sublimetext.4", "com.barebones.bbedit", "com.vscodium",
                     "ai.opencode.desktop", "com.t3tools.t3code"])
        add("assistant", ["com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
                          "ai.perplexity.mac", "com.anthropic.operon"])
        add("chat", ["com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
                     "org.whispersystems.signal-desktop", "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp",
                     "com.microsoft.teams2", "com.microsoft.teams"])
        add("meeting", ["us.zoom.xos", "com.apple.FaceTime", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark",
                        "ch.protonmeet.desktop"])
        add("mail", ["com.apple.mail", "com.microsoft.Outlook", "org.mozilla.thunderbird", "ch.protonmail.desktop",
                     "com.readdle.smartemail-Mac", "com.mimestream.Mimestream", "com.superhuman.electron"])
        add("writing", ["com.apple.Pages", "com.microsoft.Word", "com.apple.TextEdit", "com.apple.Notes",
                        "md.obsidian", "notion.id", "com.literatureandlatte.scrivener3", "net.shinyfrog.bear",
                        "pro.writer.mac", "com.ulyssesapp.mac", "co.180g.Vellum", "com.anytype.anytype",
                        "com.apple.Stickies", "com.apple.freeform"])
        add("office", ["com.apple.Numbers", "com.apple.Keynote", "com.microsoft.Excel", "com.microsoft.Powerpoint",
                       "com.linear", "com.electron.asana", "com.mongodb.compass"])
        add("design", ["com.figma.Desktop", "com.bohemiancoding.sketch3", "com.canva.affinity", "com.canva.canvaeditor",
                       "com.pixelmatorteam.pixelmator.x", "org.blenderfoundation.blender", "com.adobe.Photoshop",
                       "com.apple.IconComposer", "com.apple.SFSymbols", "org.freecad.FreeCAD"])
        add("media", ["com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.apple.TV",
                      "org.videolan.vlc", "com.colliderli.iina", "com.apple.QuickTimePlayerX", "com.obsproject.obs-studio"])
        add("reading", ["com.apple.Preview", "com.apple.iBooksX", "com.amazon.Lassen", "com.apple.news",
                        "com.apple.Dictionary"])
        add("system", ["com.apple.finder", "com.apple.systempreferences", "com.apple.ActivityMonitor",
                       "com.apple.loginwindow", "com.vaccone.lodestar", "com.raycast.macos", "com.1password.1password",
                       "com.apple.Passwords", "com.apple.calculator"])
        return table
    }()
}
