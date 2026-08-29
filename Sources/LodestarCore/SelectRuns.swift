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

    /// Whether two rectangles share a column: their horizontal extents
    /// overlap by at least `columnOverlap` of the narrower one. Measured
    /// against the narrower so a short line inside a wide column still
    /// belongs to it, and a line beside the column does not. The one
    /// definition of a column this layer has; a span that decides what
    /// lies between its ends asks the same question.
    static func sharesColumn(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let narrower = min(a.width, b.width)
        return narrower > 0 && overlap / narrower >= columnOverlap
    }

    /// Merge leaves that may belong to different windows. A leaf belongs
    /// to the frontmost window whose bounds contain its center — windows
    /// front to back, as the window server draws them — or to no window
    /// at all; each window's leaves are stitched on their own. A run
    /// never straddles two windows: a reference window beside the focused
    /// one is every bit as selectable, but its lines are not the focused
    /// window's continuation, whatever column the two happen to share.
    public static func merge(_ leaves: [Leaf], windows: [CGRect]) -> [Run] {
        guard !windows.isEmpty else { return merge(leaves) }
        var groups = [[Leaf]](repeating: [], count: windows.count + 1)
        for leaf in leaves {
            let center = CGPoint(x: leaf.frame.midX, y: leaf.frame.midY)
            let owner = windows.firstIndex { $0.contains(center) } ?? windows.count
            groups[owner].append(leaf)
        }
        return groups.flatMap(merge)
    }

    /// Merge leaves (already roughly reading-ordered by the caller) into
    /// runs. Same line and close → joined with a space when the layout
    /// drew a gap, nothing when it did not; consecutive lines of one
    /// column → joined with a newline; anything else starts a new run.
    /// Conservative on purpose: an over-merged run promises spans across
    /// unrelated columns, and a promise the highlight cannot keep is worse
    /// than a shorter run.
    ///
    /// Every run stays open until the pass ends, and each leaf joins the
    /// nearest open run it continues — not merely the run of the leaf
    /// before it. Reading order interleaves columns line by line, so on a
    /// screen with a sidebar the leaf before is usually the other
    /// column's; a merge that only ever asked about that one failed the
    /// column test on every line and shattered both columns into
    /// single-line runs. The rules are unchanged; they are simply asked
    /// of every run that could answer. Cost is leaves × open runs — a
    /// few hundred each way on a dense screen, cheap float comparisons,
    /// tens of microseconds measured.
    public static func merge(_ leaves: [Leaf]) -> [Run] {
        guard !leaves.isEmpty else { return [] }

        /// A run under construction.
        struct Block {
            var text: String
            var fragments: [Fragment]
            /// The run's UTF-16 length so far, advanced beside every
            /// append: bridging the accumulated text to NSString per
            /// fragment made stitching quadratic.
            var utf16Length: Int
            /// The extent of the run's current visual line — a newline
            /// replaces it, a same-line merge widens it. Kept per run:
            /// unioning across runs once let a right-hand column inherit
            /// the whole visual line and claim the left column's next
            /// line as its own continuation.
            var lineFrame: CGRect
            /// Where the run's last leaf began, so a leaf that sits above
            /// it (an input the caller failed to sort) never continues it.
            var lastMinY: CGFloat
        }
        var blocks: [Block] = []

        for leaf in leaves {
            let frame = leaf.frame
            var chosen: Int?
            var joiner = ""

            // Same line first: the run whose current line ends nearest
            // to this leaf's left, within a word gap. A drawn gap is a
            // space; touching fragments are one token split by styling.
            // To its left, strictly: reading order sorts a line's leaves
            // by x, but a tall leaf can sort ahead of a short one on the
            // same visual line, and a leaf that lies before a line's end
            // is not its continuation — appending it would put the words
            // in the wrong order, and did, when a sidebar item followed a
            // heading in the sort and vanished into the heading's run.
            var nearestEnd = -CGFloat.infinity
            for (index, block) in blocks.enumerated() {
                let line = block.lineFrame
                guard abs(line.midY - frame.midY) <= lineTolerance else { continue }
                let gap = frame.minX - line.maxX
                guard gap >= -lineTolerance, gap <= wordGap, line.maxX > nearestEnd
                else { continue }
                nearestEnd = line.maxX
                chosen = index
                joiner = gap > 1.5 ? " " : ""
            }

            // Then the column: the nearest run above whose current line
            // shares this leaf's column, within a block gap. A later run
            // wins a tie, which is the run the leaf before this one most
            // likely joined.
            if chosen == nil {
                var nearestBottom = -CGFloat.infinity
                for (index, block) in blocks.enumerated() {
                    let line = block.lineFrame
                    let lineHeight = max(line.height, frame.height, 8)
                    let verticalGap = frame.minY - line.maxY
                    let continues = frame.minY > block.lastMinY - lineTolerance
                        && verticalGap <= lineHeight * blockGapFactor
                    guard continues, sharesColumn(line, frame),
                          line.maxY >= nearestBottom else { continue }
                    nearestBottom = line.maxY
                    chosen = index
                    joiner = "\n"
                }
            }

            let nsText = leaf.text as NSString
            if let index = chosen {
                blocks[index].text += joiner
                // Joiners are ASCII (" ", "", "\n"): one UTF-16 unit each.
                blocks[index].utf16Length += joiner.utf16.count
                blocks[index].lineFrame = joiner == "\n"
                    ? frame : blocks[index].lineFrame.union(frame)
                let start = blocks[index].utf16Length
                blocks[index].text += leaf.text
                blocks[index].utf16Length += nsText.length
                blocks[index].fragments.append(Fragment(
                    leaf: leaf.id,
                    range: NSRange(location: start, length: nsText.length),
                    localRange: NSRange(location: 0, length: nsText.length)))
                blocks[index].lastMinY = frame.minY
            } else {
                blocks.append(Block(
                    text: leaf.text,
                    fragments: [Fragment(
                        leaf: leaf.id,
                        range: NSRange(location: 0, length: nsText.length),
                        localRange: NSRange(location: 0, length: nsText.length))],
                    utf16Length: nsText.length,
                    lineFrame: frame,
                    lastMinY: frame.minY))
            }
        }
        // Runs come out in the order they opened — top to bottom, then
        // left to right, by first leaf — which is the reading order the
        // caller sorts by anyway.
        return blocks.map { Run(text: $0.text, fragments: $0.fragments) }
    }
}
