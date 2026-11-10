import Foundation

extension NSRegularExpression {
    /// A regular expression whose pattern is a constant of the source: it is a
    /// regular expression every time or never, so a pattern that is not one is
    /// a mistake in the code and stops the process, naming the pattern and the
    /// reason, the first time it is built (the tests build each one).
    static func constant(_ pattern: String, options: Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("the constant pattern \(pattern) is not a regular expression: \(error)")
        }
    }
}
