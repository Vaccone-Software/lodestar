import CoreGraphics
import Foundation
import Vision

/// The pixel sensor: what select sees when it looks at a window.
///
/// Pixels are the one interface every window implements. Accessibility
/// trees build lazily, un-build after idle, answer geometry per-app
/// per-element per-mood, and draw element boundaries a span cannot cross
/// — every one of which was a measured source of inconsistency. The
/// screen itself has none of those properties: the Vision framework reads
/// the capture, returns each visual line with its geometry, and can place
/// any character range of a line to the pixel. Recognition is configured
/// for fidelity over fluency: accurate level, language correction OFF —
/// correction "fixes" identifiers, and a copied UUID must be the UUID.
///
/// System framework, so the zero-dependency rule stands.
public enum OCRSense {
    /// One recognized visual line, in screen (Quartz, top-left origin)
    /// coordinates.
    public struct Line {
        public let text: String
        public let frame: CGRect
        let candidate: VNRecognizedText
        let windowFrame: CGRect

        /// Screen rectangles for a UTF-16 range of this line's text —
        /// character-precise, straight from the recognizer.
        public func rects(for range: NSRange) -> [CGRect] {
            guard let stringRange = Range(range, in: text) else { return [] }
            guard let observation = try? candidate.boundingBox(for: stringRange) else {
                return [frame]
            }
            return [OCRSense.mapped(observation.boundingBox, in: windowFrame)]
        }
    }

    /// Vision's normalized bottom-left box → Quartz screen rect.
    static func mapped(_ box: CGRect, in windowFrame: CGRect) -> CGRect {
        CGRect(x: windowFrame.minX + box.minX * windowFrame.width,
               y: windowFrame.minY + (1 - box.maxY) * windowFrame.height,
               width: box.width * windowFrame.width,
               height: box.height * windowFrame.height)
    }

    public enum Level {
        /// ~100ms on a Retina display: the world appears at once, rough
        /// around rare glyphs.
        case fast
        /// The truth, a few hundred milliseconds later — always run, and
        /// always the pass a copy is served from.
        case accurate
    }

    /// Recognize every line of a capture. Synchronous and CPU-fed — call
    /// off the main thread. Runs twice per mode entry over one frozen
    /// frame: fast to be present, accurate to be right, the second
    /// replacing the first the way every richer pass here replaces a
    /// poorer one.
    public static func recognize(image: CGImage, windowFrame: CGRect,
                                 level: Level = .accurate) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .fast ? .fast : .accurate
        request.usesLanguageCorrection = false
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return [] }
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return Line(text: candidate.string,
                        frame: mapped(observation.boundingBox, in: windowFrame),
                        candidate: candidate,
                        windowFrame: windowFrame)
        }
    }

    /// Whitespace-collapsed form, for grounding an OCR span against
    /// accessibility ground truth: recognition and AX may disagree about
    /// runs of spaces, never about the words between them.
    public static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The accessibility-read truth, normalized once and kept.
    ///
    /// Recognition of clean screen text is nearly perfect — nearly. The
    /// residue is single-glyph confusion (`1`↔`l`, `0`↔`O`), which is
    /// harmless in prose and catastrophic in an identifier: a copied
    /// token that is one silent character wrong burns a user worse than
    /// no copy at all. So when AX could read the same region, its text is
    /// the truth.
    ///
    /// Prepared rather than free-standing because normalizing the
    /// candidates is the expensive half, and a span crossing runs asks
    /// for a repair once per piece — the preparation belongs to the
    /// harvest that produced the texts, off the main thread, not to the
    /// keystroke that commits.
    public struct Grounding {
        let haystacks: [String]

        public init(_ candidates: [String]) {
            haystacks = candidates.map(OCRSense.normalized)
        }

        /// The truth behind a recognized span, or nil to keep the pixels.
        /// An exact match confirms the span; failing that, the span is
        /// aligned by a long word and repaired when the accessibility
        /// window agrees at the same length with only a few substituted
        /// characters. Anything less similar is left alone — a grounding
        /// that guessed would be the worse corruption.
        public func repair(_ span: String) -> String? {
            let target = normalized(span)
            guard target.count >= 4 else { return nil }
            for haystack in haystacks where haystack.contains(target) {
                return span
            }
            // Any word can anchor the alignment — tried longest first,
            // because longer anchors misalign less. Crucially not ONLY
            // the longest: the longest word is usually the identifier,
            // and the identifier is usually the thing that was misread,
            // so the anchor that works is a clean ordinary word beside it.
            let anchors = target.split(separator: " ")
                .filter { $0.count >= 5 }
                .sorted { $0.count > $1.count }
            for anchor in anchors {
                guard let targetAnchor = target.range(of: String(anchor)) else { continue }
                let lead = target.distance(from: target.startIndex,
                                           to: targetAnchor.lowerBound)
                for haystack in haystacks {
                    guard let anchorRange = haystack.range(of: String(anchor)),
                          let start = haystack.index(anchorRange.lowerBound, offsetBy: -lead,
                                                     limitedBy: haystack.startIndex),
                          let end = haystack.index(start, offsetBy: target.count,
                                                   limitedBy: haystack.endIndex)
                    else { continue }
                    let window = String(haystack[start..<end])
                    guard window.count == target.count else { continue }
                    let mismatches = zip(window, target).filter { $0.0 != $0.1 }.count
                    if mismatches == 0 { return span }
                    if Double(mismatches) / Double(target.count) <= 0.15 {
                        return window
                    }
                }
            }
            return nil
        }
    }

    /// Ground one span against candidates prepared on the spot.
    public static func ground(_ span: String, in candidates: [String]) -> String? {
        Grounding(candidates).repair(span)
    }
}
