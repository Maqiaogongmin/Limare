import Foundation
import Observation

/// Review comments not yet added to a message, per conversation and working directory, shared
/// by every window. Saved to one JSON file, so closing a window or quitting keeps them; they
/// leave when added to a message, deleted, or with their conversation.
@MainActor
@Observable
final class ReviewCommentStore {
    private struct Entry: Codable {
        var binding: GitReviewStore.BindingKey
        var comments: [GitReviewComment]
    }

    private(set) var byBinding: [GitReviewStore.BindingKey: [GitReviewComment]] = [:]
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored var log: ((String) -> Void)?

    /// `fileURL` nil keeps the comments in memory only.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let entries = try? decoder.decode([Entry].self, from: data) {
            byBinding = Dictionary(entries.map { ($0.binding, $0.comments) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func comments(for binding: GitReviewStore.BindingKey) -> [GitReviewComment] {
        byBinding[binding] ?? []
    }

    func set(_ comments: [GitReviewComment], for binding: GitReviewStore.BindingKey) {
        guard byBinding[binding] ?? [] != comments else { return }
        byBinding[binding] = comments.isEmpty ? nil : comments
        save()
    }

    var totalCount: Int { byBinding.values.reduce(0) { $0 + $1.count } }

    func removeAll(conversationID: UUID) {
        let kept = byBinding.filter { $0.key.conversationID != conversationID }
        guard kept.count != byBinding.count else { return }
        byBinding = kept
        save()
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let entries = byBinding.map { Entry(binding: $0.key, comments: $0.value) }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            log?("Review comments couldn't be saved: \(error.localizedDescription)")
        }
    }
}
