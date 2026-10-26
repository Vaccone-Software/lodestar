import Foundation

/// The draft's editing style arrived after Vim was the only way to edit it,
/// and Standard became the default. A Mac that had run Lodestar before keeps
/// Vim, once, written into its config, so nobody's draft changes under
/// their hands. That a Mac ran Lodestar before is told by its state file
/// being there before the first launch of this build: the command line only
/// reads it, so a new Mac that runs a command first is still new, where the
/// config file, which the command line makes, would call it old. It is
/// once because the config is sparse: a hand that then picks Standard
/// leaves no key behind, and a Mac that looked old again at every launch
/// would be given Vim back. The state records that the choice
/// was made, and a new Mac is recorded without being given anything.
public enum EditingStyleMigration {
    /// Whether the config was written. Does nothing until the state is
    /// known, because an unknown state has not said whether the choice was
    /// made, and stays unsettled when the write fails, to be tried at the
    /// next launch. A state that had to start fresh (damaged, or its key
    /// lost) cannot say whether the choice was made, so it is settled
    /// without a write: a hand already on Standard is not given Vim.
    @discardableResult
    public static func run(ranBefore: Bool, state: StateStore, config: URL = Config.file) throws -> Bool {
        guard state.isKnown, !state.editingStyleSettled else { return false }
        var written = false
        if ranBefore, state.bootWarning == nil {
            let path = ["draft", "editing-style"]
            try Config.edit(in: config) { tree in
                // A style the file already names is the hand's own.
                guard tree.value(at: path) == nil else { return tree }
                guard let kept = Json.setting(tree, path: path, to: .string(Draft.EditingStyle.vim.rawValue)) else {
                    throw Config.EditError.unparsed(path.joined(separator: "."))
                }
                written = true
                return kept
            }
        }
        state.settleEditingStyle()
        return written
    }
}
