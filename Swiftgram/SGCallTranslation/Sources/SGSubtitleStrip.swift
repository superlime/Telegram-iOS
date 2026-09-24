import Foundation

// MARK: Swiftgram
/// The rolling subtitle strip, one line per utterance, in the order spoken.
///
/// A line starts life as a partial transcript while the speaker is still
/// talking, becomes the final transcript when the recogniser commits, and is
/// replaced by the translation when that lands. Each stage overwrites the same
/// line, so a viewer sees text appear as it is spoken and then turn into their
/// own language, without the strip ever reordering.
///
/// This replaced a sequencer that held completed translations back until every
/// earlier one had also completed. With one line per utterance that ordering
/// problem does not exist: a late translation lands on its own line, wherever
/// that line already is.
///
/// Pure and dependency-free so it can be exercised without a call.
public struct SGSubtitleStrip: Equatable {
    public struct Line: Equatable {
        public let key: String
        public var text: String
        /// True while the text is a transcript (partial or final) rather than
        /// the translation.
        public var isProvisional: Bool
    }

    private var lines: [Line] = []
    private let windowSize: Int

    public init(windowSize: Int) {
        self.windowSize = max(1, windowSize)
    }

    /// Show or update in-progress speech. Returns the strip when it changed.
    public mutating func setPartial(key: String, text: String) -> [String]? {
        if let index = self.lines.firstIndex(where: { $0.key == key }) {
            if self.lines[index].text == text {
                return nil
            }
            self.lines[index].text = text
            return self.currentSubtitles
        }
        self.lines.append(Line(key: key, text: text, isProvisional: true))
        self.trim()
        return self.currentSubtitles
    }

    /// The recogniser committed an utterance. Its line takes over from the
    /// partial it grew out of, if that is still on the strip, and otherwise
    /// goes on the end. Returns the strip when it changed.
    public mutating func commit(partialKey: String?, uuid: String, text: String) -> [String]? {
        if let partialKey = partialKey, let index = self.lines.firstIndex(where: { $0.key == partialKey }) {
            let changed = self.lines[index].text != text
            self.lines[index] = Line(key: uuid, text: text, isProvisional: true)
            return changed ? self.currentSubtitles : nil
        }
        self.lines.append(Line(key: uuid, text: text, isProvisional: true))
        self.trim()
        return self.currentSubtitles
    }

    /// The translation for a committed utterance. Returns nil when the line has
    /// already scrolled off, in which case there is nothing to show.
    public mutating func translate(uuid: String, text: String) -> [String]? {
        guard let index = self.lines.firstIndex(where: { $0.key == uuid }) else {
            return nil
        }
        if self.lines[index].text == text && !self.lines[index].isProvisional {
            return nil
        }
        self.lines[index].text = text
        self.lines[index].isProvisional = false
        return self.currentSubtitles
    }

    /// Drop an in-progress line that will never be committed.
    public mutating func removePartial(key: String) -> [String]? {
        guard let index = self.lines.firstIndex(where: { $0.key == key }) else {
            return nil
        }
        self.lines.remove(at: index)
        return self.currentSubtitles
    }

    public var currentSubtitles: [String] {
        return self.lines.map { $0.text }
    }

    public var currentLines: [Line] {
        return self.lines
    }

    public mutating func reset() {
        self.lines.removeAll()
    }

    private mutating func trim() {
        if self.lines.count > self.windowSize {
            self.lines.removeFirst(self.lines.count - self.windowSize)
        }
    }
}
