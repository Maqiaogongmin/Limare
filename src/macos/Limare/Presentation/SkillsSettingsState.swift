import Foundation
import Observation

enum SkillFilterScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case workspace = "Project"
    case global = "Global"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: String(localized: "All")
        case .workspace: String(localized: "Project")
        case .global: String(localized: "Global")
        }
    }
}

@MainActor
@Observable
final class SkillsSettingsState {
    var presentedSkillID: String?
    var searchText: String = ""
    var filterScope: SkillFilterScope = .all
    var isDescriptionExpanded: Bool = false
    var isInstructionsExpanded: Bool = false

    init(
        presentedSkillID: String? = nil,
        searchText: String = "",
        filterScope: SkillFilterScope = .all
    ) {
        self.presentedSkillID = presentedSkillID
        self.searchText = searchText
        self.filterScope = filterScope
    }

    func filteredSkills(from allSkills: [Skill]) -> [Skill] {
        allSkills.filter { skill in
            let matchesScope: Bool
            switch filterScope {
            case .all: matchesScope = true
            case .workspace: matchesScope = skill.location.isWorkspace
            case .global: matchesScope = !skill.location.isWorkspace
            }
            guard matchesScope else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty { return true }
            return skill.name.localizedCaseInsensitiveContains(query)
                || skill.description.localizedCaseInsensitiveContains(query)
        }
    }

    func resetSheetState() {
        isDescriptionExpanded = false
        isInstructionsExpanded = false
    }
}
