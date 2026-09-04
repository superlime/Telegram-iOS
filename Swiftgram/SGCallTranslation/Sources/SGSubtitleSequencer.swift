import Foundation

// MARK: Swiftgram
/// Keeps subtitles in the order things were actually said.
///
/// Translation requests are issued as utterances arrive but complete out of
/// order — a four-word utterance comes back well before the long one spoken
/// before it. Publishing on completion would shuffle the conversation. This
/// holds finished translations until every earlier utterance is also finished,
/// then releases the run in spoken order.
///
/// Pure and dependency-free so the ordering can be tested without a call.
public struct SGSubtitleSequencer {
    private var pending: [String] = []
    private var completed: [String: String] = [:]
    private var visible: [String] = []
    private let windowSize: Int

    public init(windowSize: Int) {
        self.windowSize = max(1, windowSize)
    }

    /// Register an utterance in the order it was spoken.
    public mutating func enqueue(_ uuid: String) {
        self.pending.append(uuid)
    }

    /// Supply a finished translation. Returns the subtitle window if this
    /// completion released anything, or nil if it is still waiting on an
    /// earlier utterance.
    public mutating func complete(_ uuid: String, text: String) -> [String]? {
        guard self.pending.contains(uuid) else {
            // Unknown or already-released id: ignore rather than corrupt order.
            return nil
        }
        self.completed[uuid] = text

        var released = false
        while let first = self.pending.first, let ready = self.completed[first] {
            self.pending.removeFirst()
            self.completed.removeValue(forKey: first)
            self.visible.append(ready)
            released = true
        }
        if self.visible.count > self.windowSize {
            self.visible.removeFirst(self.visible.count - self.windowSize)
        }
        return released ? self.visible : nil
    }


    public var currentSubtitles: [String] {
        return self.visible
    }

    public mutating func reset() {
        self.pending.removeAll()
        self.completed.removeAll()
        self.visible.removeAll()
    }
}
