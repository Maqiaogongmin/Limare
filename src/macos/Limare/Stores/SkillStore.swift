import Foundation
import Observation

@MainActor
@Observable
final class SkillStore {
    struct RunSnapshot: Sendable {
        let promptFragment: String
        let readableDirectories: [URL]
        let contributions: [ExtensionContribution]

        init(promptFragment: String, readableDirectories: [URL]? = nil, contributions: [ExtensionContribution] = []) {
            self.promptFragment = promptFragment
            self.contributions = contributions
            if !contributions.isEmpty {
                self.readableDirectories = ExtensionContribution.projectReadableDirectories(from: contributions)
            } else {
                self.readableDirectories = readableDirectories ?? []
            }
        }
    }
    private(set) var skills: [Skill] = []

    @ObservationIgnored
    private let logs: DebugLogStore
    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let disabledKey: String
    @ObservationIgnored
    private let scanner: SkillScanner
    @ObservationIgnored
    private var currentWorkspaceURL: URL?

    init(
        logs: DebugLogStore,
        defaults: UserDefaults = .standard,
        disabledKey: String = "disabledSkillIDs",
        scanner: SkillScanner = SkillScanner(),
        workspaceURL: URL? = nil
    ) {
        self.logs = logs
        self.defaults = defaults
        self.disabledKey = disabledKey
        self.scanner = scanner
        self.currentWorkspaceURL = workspaceURL
        rescan(workspaceURL: workspaceURL)
    }

    var workspaceURL: URL? {
        currentWorkspaceURL
    }

    var enabledSkillDirectories: [URL] {
        validEnabledSkillsNow().map(\.directoryURL)
    }

    func selectedSkills(maximumCount: Int = 20) -> [Skill] {
        selectSkills(from: validEnabledSkillsNow(), maximumCount: maximumCount)
    }

    /// Domain arbitration predicate: identifies skills that collide with native Computer Use authority.
    public static func isShadowedByComputerUse(skillName: String, skillDirectoryName: String? = nil) -> Bool {
        let nameNorm = skillName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shadowedNames: Set<String> = [
            "cua-driver", "cua_driver", "cuadriver", "cua", "computer-use", "computer_use", "computeruse"
        ]
        if shadowedNames.contains(nameNorm) {
            return true
        }
        if let dirName = skillDirectoryName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           shadowedNames.contains(dirName) {
            return true
        }
        return false
    }

    /// Provider returning true when Limare native Computer Use is active or available,
    /// enabling domain arbitration and shadowing of external competing desktop-control skills.
    var computerUseAvailabilityProvider: (@MainActor () -> Bool)?

    private func isSkillSourceValidNow(_ skill: Skill) -> Bool {
        guard FileManager.default.fileExists(atPath: skill.fileURL.path) else { return false }
        guard let data = try? Data(contentsOf: skill.fileURL) else { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    private func validEnabledSkillsNow() -> [Skill] {
        let isCUAvailable = computerUseAvailabilityProvider?() ?? false
        return skills.filter { skill in
            guard skill.isEnabled && isSkillSourceValidNow(skill) else { return false }
            if isCUAvailable && Self.isShadowedByComputerUse(skillName: skill.name, skillDirectoryName: skill.directoryURL.lastPathComponent) {
                logs.info("Skills", "Skill '\(skill.name)' shadowed by Limare native Computer Use capability.")
                return false
            }
            return true
        }
    }

    private func selectSkills(from enabled: [Skill], maximumCount: Int) -> [Skill] {
        guard maximumCount > 0 else { return [] }
        let workspaceSkills = enabled.filter { $0.location.isWorkspace }
        let globalSkills = enabled.filter { !$0.location.isWorkspace }
        var selected: [Skill] = []
        selected.append(contentsOf: workspaceSkills.prefix(maximumCount))
        if selected.count < maximumCount {
            selected.append(contentsOf: globalSkills.prefix(maximumCount - selected.count))
        }
        return selected
    }

    func runSnapshot(runID: UUID? = nil) -> RunSnapshot {
        let allEnabled = validEnabledSkillsNow()
        let selected = selectSkills(from: allEnabled, maximumCount: 20)
        let prompt = promptFragment(from: allEnabled, maximumCount: 20) ?? ""

        var contribs: [ExtensionContribution] = []

        // 1. Prompt fragments for selected skills (up to maximum selection limit)
        for skill in selected {
            let escapedName = skill.name.xmlEscaped
            var desc = skill.description
            if desc.count > 200 {
                desc = String(desc.prefix(200)) + "…"
            }
            let escapedDesc = desc.xmlEscaped
            let escapedVersion = skill.version.xmlEscaped
            let escapedPath = skill.sourcePath.xmlEscaped
            let skillXML = "  <skill>\n    <name>\(escapedName)</name>\n    <description>\(escapedDesc)</description>\n    <version>\(escapedVersion)</version>\n    <path>\(escapedPath)</path>\n  </skill>"

            let skillVersion = ExtensionSourceVersion(value: skill.version)
            contribs.append(ExtensionContribution(
                identity: ExtensionContributionIdentity(
                    kind: .skill,
                    sourceID: skill.id,
                    sourceVersion: skillVersion,
                    localID: "prompt"
                ),
                origin: .skillRunSnapshot(runID: runID),
                prerequisites: .skillSnapshot(enabledAtCapture: true, sourceValid: true),
                payload: .promptFragment(skillXML),
                claim: .captured
            ))
        }

        // 2. Omitted skills prompt summary if enabled skills exceed selection limit
        if allEnabled.count > selected.count {
            let omitted = allEnabled.filter { s in !selected.contains(where: { $0.id == s.id }) }
            let omittedNames = omitted.map(\.name).joined(separator: ", ")
            let summaryText = "\(omitted.count) more skills available: \(omittedNames)."
            contribs.append(ExtensionContribution(
                identity: ExtensionContributionIdentity(
                    kind: .skill,
                    sourceID: "omitted-skills-summary",
                    sourceVersion: ExtensionSourceVersion(value: "1.0"),
                    localID: "omittedSummary"
                ),
                origin: .skillRunSnapshot(runID: runID),
                prerequisites: .skillSnapshot(enabledAtCapture: true, sourceValid: true),
                payload: .promptFragment(summaryText),
                claim: .captured
            ))
        }

        // 3. Readable directory contributions for ALL enabled skills (snapshot parity)
        for skill in allEnabled {
            let skillVersion = ExtensionSourceVersion(value: skill.version)
            contribs.append(ExtensionContribution(
                identity: ExtensionContributionIdentity(
                    kind: .skill,
                    sourceID: skill.id,
                    sourceVersion: skillVersion,
                    localID: "readableDirectory"
                ),
                origin: .skillRunSnapshot(runID: runID),
                prerequisites: .skillSnapshot(enabledAtCapture: true, sourceValid: true),
                payload: .readableDirectory(skill.directoryURL),
                claim: .captured
            ))
        }

        return RunSnapshot(
            promptFragment: prompt,
            contributions: contribs
        )
    }

    func setWorkspaceURL(_ url: URL?) {
        currentWorkspaceURL = url
        performScan(workspaceURL: url)
    }

    func rescan(workspaceURL: URL? = nil) {
        let activeURL = workspaceURL ?? currentWorkspaceURL
        currentWorkspaceURL = activeURL
        performScan(workspaceURL: activeURL)
    }

    func setSkillsForTesting(_ newSkills: [Skill]) {
        self.skills = newSkills
    }

    private func performScan(workspaceURL: URL?) {
        let disabledIDs = Set(defaults.stringArray(forKey: disabledKey) ?? [])
        let scanned = scanner.scan(workspaceURL: workspaceURL)

        skills = scanned.map { skill in
            var copy = skill
            copy.isEnabled = !disabledIDs.contains(skill.id)
            return copy
        }

        let workspaceCount = skills.filter { $0.location.isWorkspace }.count
        let globalCount = skills.count - workspaceCount
        logs.info("Skills", "Discovered \(skills.count) skills (\(workspaceCount) workspace, \(globalCount) global).")
    }

    func setEnabled(_ isEnabled: Bool, for skillID: String) {
        guard let index = skills.firstIndex(where: { $0.id == skillID }) else { return }
        skills[index].isEnabled = isEnabled

        var disabledIDs = Set(defaults.stringArray(forKey: disabledKey) ?? [])
        if isEnabled {
            disabledIDs.remove(skillID)
        } else {
            disabledIDs.insert(skillID)
        }
        defaults.set(Array(disabledIDs), forKey: disabledKey)
        logs.info("Skills", "\(skills[index].name) is now \(isEnabled ? "enabled" : "disabled").")
    }

    func skillPromptFragment(maximumCount: Int = 20) -> String? {
        promptFragment(from: validEnabledSkillsNow(), maximumCount: maximumCount)
    }

    private func promptFragment(from enabled: [Skill], maximumCount: Int) -> String? {
        guard !enabled.isEmpty else { return nil }
        let selected = selectSkills(from: enabled, maximumCount: maximumCount)

        let maxDescLength = 200
        var xml = "<available_skills>\n"
        for skill in selected {
            let escapedName = skill.name.xmlEscaped
            var desc = skill.description
            if desc.count > maxDescLength {
                desc = String(desc.prefix(maxDescLength)) + "…"
            }
            let escapedDesc = desc.xmlEscaped
            let escapedVersion = skill.version.xmlEscaped
            let escapedPath = skill.sourcePath.xmlEscaped
            xml += "  <skill>\n"
            xml += "    <name>\(escapedName)</name>\n"
            xml += "    <description>\(escapedDesc)</description>\n"
            xml += "    <version>\(escapedVersion)</version>\n"
            xml += "    <path>\(escapedPath)</path>\n"
            xml += "  </skill>\n"
        }
        xml += "</available_skills>"

        var fragment = "Skills:\n"
        fragment += "Reusable instruction sets stored on disk. When a task matches an available skill, read the SKILL.md file using file_read to load its full instructions before proceeding.\n\n"
        fragment += xml

        if enabled.count > selected.count {
            let omitted = enabled.filter { s in !selected.contains(where: { $0.id == s.id }) }
            let omittedNames = omitted.map(\.name).joined(separator: ", ")
            fragment += "\n\n\(omitted.count) more skills available: \(omittedNames)."
        }

        return fragment
    }
}
