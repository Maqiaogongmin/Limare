import Foundation

/// Limare-owned element registry mapping ephemeral model-facing tokens (e1, e2, ...)
/// to backend driver element tokens with generation and snapshot binding.
///
/// References come from the latest observation of the run's window: every observation (including
/// the one returned after each action) replaces the previous references. They never cross
/// conversations or runs.
public actor ComputerUseElementRegistry {
    public struct SessionKey: Hashable, Sendable {
        public let conversationID: String
        public let runID: String

        public init(conversationID: String, runID: String) {
            self.conversationID = conversationID
            self.runID = runID
        }
    }

    private struct SessionState {
        var generation: Int
        var snapshotID: String
        var elementsByRefID: [String: ComputerUseElementRef] = [:]
    }

    private var sessions: [SessionKey: SessionState] = [:]

    public init() {}

    /// Registers a new observation, binding its elements to fresh model-facing refs (e1, e2, ...).
    @discardableResult
    public func registerObservation(
        _ observation: ComputerUseObservation,
        conversationID: String,
        runID: String,
        generation: Int
    ) -> [ComputerUseElementRef] {
        let key = SessionKey(conversationID: conversationID, runID: runID)
        var refMap: [String: ComputerUseElementRef] = [:]
        var refsList: [ComputerUseElementRef] = []

        for (idx, elem) in observation.elements.enumerated() {
            let refID = "e\(idx + 1)"
            let ref = ComputerUseElementRef(
                refID: refID,
                generation: generation,
                snapshotID: observation.snapshotID,
                backendToken: elem.token,
                target: observation.target,
                role: elem.role,
                label: elem.label ?? elem.title,
                normalizedFrame: elem.normalizedFrame
            )
            refMap[refID] = ref
            refsList.append(ref)
        }

        sessions[key] = SessionState(
            generation: generation,
            snapshotID: observation.snapshotID,
            elementsByRefID: refMap
        )

        return refsList
    }

    /// Project raw driver indexes into the exact model tokens for this observation.
    /// Only structural AX line prefixes change; user text and numeric values stay untouched.
    public nonisolated static func modelTreeMarkdown(_ observation: ComputerUseObservation,
                                                      refs: [ComputerUseElementRef]) -> String? {
        guard let tree = observation.treeMarkdown,
              let regex = try? NSRegularExpression(pattern: #"(?m)^(\s*(?:-\s*)?)\[(\d+)\]"#) else { return observation.treeMarkdown }
        var byIndex: [Int: [String]] = [:]
        for (element, ref) in zip(observation.elements, refs) { byIndex[element.index, default: []].append(ref.refID) }
        let output = NSMutableString(string: tree)
        for match in regex.matches(in: tree, range: NSRange(location: 0, length: (tree as NSString).length)).reversed() {
            let index = Int((tree as NSString).substring(with: match.range(at: 2))) ?? -1
            let mapped = byIndex[index] ?? []
            let prefix = (tree as NSString).substring(with: match.range(at: 1))
            output.replaceCharacters(in: match.range, with: prefix + "[" + (mapped.count == 1 ? mapped[0] : "unaddressable") + "]")
        }
        return output as String
    }

    /// Resolves a reference from the latest observation.
    public func resolve(
        refID: String,
        conversationID: String,
        runID: String
    ) throws -> ComputerUseElementRef {
        let key = SessionKey(conversationID: conversationID, runID: runID)
        guard let session = sessions[key] else {
            throw ComputerUseDriverError.elementNotFound(detail: "No active observation session for \(conversationID)/\(runID)")
        }
        guard let ref = session.elementsByRefID[refID] else {
            throw ComputerUseDriverError.elementNotFound(detail: "Element reference '\(refID)' not found in session")
        }
        return ref
    }

    /// Invalidate session on driver shutdown or target change.
    public func invalidateSession(conversationID: String, runID: String) {
        let key = SessionKey(conversationID: conversationID, runID: runID)
        sessions.removeValue(forKey: key)
    }

    /// Clear all stored sessions.
    public func clearAll() {
        sessions.removeAll()
    }
}
