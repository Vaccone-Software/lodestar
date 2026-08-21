import Foundation
import CoreGraphics

/// Stitching fragmented text back into the prose it renders as.
///
/// Web and Electron views shatter a paragraph into dozens of tiny static
/// text leaves — one per styling run, one per line box. Searched leaf by
/// leaf, "this word here" with a bold middle can never match, and a span
/// can never cross a fragment. So harvested leaves are merged, in reading
/// order, into **runs**: fragments on one visual line joined by the gap
/// the layout drew, lines of the same column joined by newlines. A run is
/// what the matcher searches and what a span may cover; the fragment map
/// underneath converts any range of the run back into per-fragment slices
/// — which is what geometry and copying need, and what makes a highlight
/// across three fragments three honest rectangles.
public enum SelectRuns {
    /// One harvested text leaf, in the caller's coordinate space.
    public struct Leaf: Equatable {
        /// The caller's index into whatever it keeps alongside (AX handles).
        public let id: Int
        public let text: String
        public let frame: CGRect

        public init(id: Int, text: String, frame: CGRect) {
            self.id = id
            self.text = text
            self.frame = frame
        }
    }

    /// A slice of a run that lives in one leaf: `range` in the run's
    /// UTF-16 text maps onto `localRange` of leaf `leaf`.
    public struct Fragment: Equatable {
        public let leaf: Int
        public let range: NSRange
        public let localRange: NSRange

        public init(leaf: Int, range: NSRange, localRange: NSRange) {
            self.leaf = leaf
            self.range = range
            self.localRange = localRange
        }
    }

    /// One searchable stretch of stitched text.
    public struct Run: Equatable {
        public let text: String
        public let fragments: [Fragment]

        public init(text: String, fragments: [Fragment]) {
            self.text = text
            self.fragments = fragments
        }

        /// The fragment slices covered by a range of the run, each clipped
        /// to its overlap — joiner characters between fragments belong to
        /// nobody and simply drop out of geometry.
        public func slices(of range: NSRange) -> [Fragment] {
            fragments.compactMap { fragment in
                let start = max(range.location, fragment.range.location)
                let end = min(range.location + range.length,
                              fragment.range.location + fragment.range.length)
                guard end > start else { return nil }
                let localStart = fragment.localRange.location
                    + (start - fragment.range.location)
                return Fragment(leaf: fragment.leaf,
                                range: NSRange(location: start, length: end - start),
                                localRange: NSRange(location: localStart,
                                                    length: end - start))
            }
        }
    }

    /// Fragments whose vertical centers are this close share a line.
    public static let lineTolerance: CGFloat = 6
    /// A horizontal gap wider than this is a layout column, not a space.
    static let wordGap: CGFloat = 48
    /// A vertical gap taller than this many line heights breaks the block.
    static let blockGapFactor: CGFloat = 1.9
    /// Lines whose horizontal extents overlap less than this share no
    /// column and are never joined into one block.
    static let columnOverlap: CGFloat = 0.5

    /// Merge leaves (already roughly reading-ordered by the caller) into
    /// runs. Same line and close → joined with a space when the layout
    /// drew a gap, nothing when it did not; consecutive lines of one
    /// column → joined with a newline; anything else starts a new run.
    /// Conservative on purpose: an over-merged run promises spans across
    /// unrelated columns, and a promise the highlight cannot keep is worse
    /// than a shorter run.
    public static func merge(_ leaves: [Leaf]) -> [Run] {
        guard !leaves.isEmpty else { return [] }
        var runs: [Run] = []
        var text = ""
        var fragments: [Fragment] = []
        var lineFrame = CGRect.null
        var previous: Leaf?
        /// The run's UTF-16 length so far, advanced beside every append.
        var utf16Length = 0

        func flush() {
            guard !fragments.isEmpty else { return }
            runs.append(Run(text: text, fragments: fragments))
            text = ""
            fragments = []
            utf16Length = 0
        }

        for leaf in leaves {
            let joiner: String?
            if let prior = previous {
                let sameLine = abs(prior.frame.midY - leaf.frame.midY) <= lineTolerance
                if sameLine {
                    let gap = leaf.frame.minX - prior.frame.maxX
                    if gap <= wordGap {
                        joiner = gap > 1.5 ? " " : ""
                    } else {
                        joiner = nil
                    }
                } else {
                    let lineHeight = max(lineFrame.height, leaf.frame.height, 8)
                    let verticalGap = leaf.frame.minY - lineFrame.maxY
                    let overlap = min(lineFrame.maxX, leaf.frame.maxX)
                        - max(lineFrame.minX, leaf.frame.minX)
                    let narrower = min(lineFrame.width, leaf.frame.width)
                    let sameColumn = narrower > 0 && overlap / narrower >= columnOverlap
                    let continues = leaf.frame.minY > prior.frame.minY - lineTolerance
                        && verticalGap <= lineHeight * blockGapFactor
                    joiner = sameColumn && continues ? "\n" : nil
                }
            } else {
                joiner = nil
            }

            if previous != nil, joiner == nil {
                flush()
            }
            // The line extent belongs to the CURRENT RUN: a new run starts
            // its own line, a newline advances it, a same-line merge widens
            // it. Unioning across run boundaries let a right-hand column
            // inherit the whole visual line and claim the left column's
            // next line as its own continuation.
            if !fragments.isEmpty, let joiner {
                text += joiner
                // Joiners are ASCII (" ", "", "\n"): one UTF-16 unit each.
                utf16Length += joiner.utf16.count
                lineFrame = joiner == "\n" ? leaf.frame : lineFrame.union(leaf.frame)
            } else {
                lineFrame = leaf.frame
            }

            let nsText = leaf.text as NSString
            // Carried, not remeasured: bridging the accumulated run to
            // NSString on every fragment made stitching quadratic.
            let start = utf16Length
            text += leaf.text
            utf16Length += nsText.length
            fragments.append(Fragment(
                leaf: leaf.id,
                range: NSRange(location: start, length: nsText.length),
                localRange: NSRange(location: 0, length: nsText.length)))
            previous = leaf
        }
        flush()
        return runs
    }
}
