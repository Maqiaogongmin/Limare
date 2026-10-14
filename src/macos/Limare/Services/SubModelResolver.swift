import Foundation

struct SubModelCandidate: Sendable, Equatable {
    let provider: ProviderConfiguration
    let model: ProviderModel

    var identity: String { "\(provider.id.uuidString):\(model.id)" }
    var attribution: String { "\(provider.name) / \(model.displayName)" }
}

@MainActor
final class SubModelResolver {
    static let maximumCandidatesPerSource = 3

    private let modelGroups: ModelGroupStore
    private let providers: ProviderStore

    init(modelGroups: ModelGroupStore, providers: ProviderStore) {
        self.modelGroups = modelGroups
        self.providers = providers
    }

    static func isTextTaskEligible(_ model: ProviderModel) -> Bool {
        guard let modality = model.modality else { return true }
        return modality.contains(.textInput) && modality.contains(.textOutput)
    }

    func candidates(
        for source: ConversationModelSource,
        conversationID: UUID
    ) -> [SubModelCandidate] {
        switch source {
        case .direct(let providerID, let modelID):
            guard let provider = providers.providers.first(where: { $0.id == providerID }),
                  let model = provider.models.first(where: { $0.id == modelID }),
                  Self.isTextTaskEligible(model) else { return [] }
            return [SubModelCandidate(provider: provider, model: model)]

        case .group(let groupID):
            guard let group = modelGroups.group(for: groupID) else { return [] }
            var result = group.memberEntryIds.compactMap { entryID -> SubModelCandidate? in
                guard let parsed = ModelGroup.parseEntryId(entryID),
                      let provider = providers.providers.first(where: { $0.id == parsed.providerID }),
                      let model = provider.models.first(where: { $0.id == parsed.modelID }),
                      Self.isTextTaskEligible(model) else { return nil }
                // Existing group bindings remain valid even when a model is hidden.
                // Credentials are intentionally checked only when a request begins.
                return SubModelCandidate(provider: provider, model: model)
            }
            if group.strategy == .loadBalance, result.count > 1 {
                let offset = Self.stableIndex(conversationID.uuidString, count: result.count)
                result = Array(result[offset...] + result[..<offset])
            }
            return Array(result.prefix(Self.maximumCandidatesPerSource))
        }
    }

    func orderedCandidates(
        subSource: ConversationModelSource?,
        primarySource: ConversationModelSource?,
        conversationID: UUID
    ) -> [SubModelCandidate] {
        var result: [SubModelCandidate] = []
        var seen = Set<String>()
        for source in [subSource, primarySource].compactMap({ $0 }) {
            for candidate in candidates(for: source, conversationID: conversationID)
                where seen.insert(candidate.identity).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    func capabilityCandidateCount(for group: ModelGroup) -> Int {
        group.memberEntryIds.reduce(into: 0) { count, entryID in
            guard let parsed = ModelGroup.parseEntryId(entryID),
                  let provider = providers.providers.first(where: { $0.id == parsed.providerID }),
                  let model = provider.models.first(where: { $0.id == parsed.modelID }),
                  Self.isTextTaskEligible(model) else { return }
            count += 1
        }
    }

    private static func stableIndex(_ value: String, count: Int) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}
