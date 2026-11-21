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
    private static let extensionUsageCountsKey = "extensionCardUsageCounts"
    private static let extensionUsageSeededKey = "extensionCardUsageSeededV1"

    private(set) var skills: [Skill] = []
    private(set) var extensionUsageCounts: [String: Int] = [:]

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
        if let stored = defaults.dictionary(forKey: Self.extensionUsageCountsKey) as? [String: Int] {
            self.extensionUsageCounts = stored
        } else if let numbers = defaults.dictionary(forKey: Self.extensionUsageCountsKey) as? [String: NSNumber] {
            self.extensionUsageCounts = numbers.mapValues(\.intValue)
        }
        if scanner.usesDefaultGlobalRoots {
            BuiltInExtensionBuilderSkill.syncIfNeeded()
        }
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

    private func validEnabledSkillsNow(_ candidates: [Skill]? = nil) -> [Skill] {
        let isCUAvailable = computerUseAvailabilityProvider?() ?? false
        return (candidates ?? skills).filter { skill in
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
        let hiddenSkills = enabled.filter(\.isHidden)
        let workspaceSkills = enabled.filter { !$0.isHidden && $0.location.isWorkspace }
        let globalSkills = enabled.filter { !$0.isHidden && !$0.location.isWorkspace }
        var selected: [Skill] = []
        selected.append(contentsOf: hiddenSkills.prefix(maximumCount))
        if selected.count < maximumCount {
            selected.append(contentsOf: workspaceSkills.prefix(maximumCount - selected.count))
        }
        if selected.count < maximumCount {
            selected.append(contentsOf: globalSkills.prefix(maximumCount - selected.count))
        }
        return selected
    }

    /// Returns true if `url` resides inside any active workspace or global skill scan root.
    func isSkillFile(_ url: URL, workspaceURL: URL? = nil) -> Bool {
        let candidateCanonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        let candidateStd = url.standardizedFileURL.path
        var roots = scanner.allScanRoots(workspaceURL: workspaceURL ?? currentWorkspaceURL)
        if let workspaceURL, let currentWorkspaceURL, workspaceURL != currentWorkspaceURL {
            roots.append(contentsOf: SkillScanner.workspaceRoots(for: currentWorkspaceURL))
        }
        for root in roots {
            let rootCanonical = root.resolvingSymlinksInPath().standardizedFileURL.path
            let rootStd = root.standardizedFileURL.path
            let prefixCanonical = rootCanonical.hasSuffix("/") ? rootCanonical : rootCanonical + "/"
            let prefixStd = rootStd.hasSuffix("/") ? rootStd : rootStd + "/"
            if candidateCanonical.hasPrefix(prefixCanonical) || candidateStd.hasPrefix(prefixStd) {
                return true
            }
        }
        return false
    }

    func runSnapshot(runID: UUID? = nil) -> RunSnapshot {
        makeRunSnapshot(from: validEnabledSkillsNow(), runID: runID)
    }

    /// Captures skills for this run without changing the workspace shown in Settings.
    func runSnapshot(workspaceURL: URL?, runID: UUID? = nil) -> RunSnapshot {
        let disabledIDs = Set(defaults.stringArray(forKey: disabledKey) ?? [])
        let scanned = scanner.scan(workspaceURL: workspaceURL).map { skill in
            var copy = skill
            copy.isEnabled = !disabledIDs.contains(skill.id)
            return copy
        }
        return makeRunSnapshot(from: validEnabledSkillsNow(scanned), runID: runID)
    }

    private func makeRunSnapshot(from allEnabled: [Skill], runID: UUID?) -> RunSnapshot {
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

    func recordExtensionUsage(cardID: String) {
        guard !cardID.isEmpty else { return }
        extensionUsageCounts[cardID, default: 0] += 1
        defaults.set(extensionUsageCounts, forKey: Self.extensionUsageCountsKey)
    }

    func recordSkillFileRead(_ url: URL, workspaceURL: URL? = nil) {
        guard let cardID = skillCardID(forFileURL: url, workspaceURL: workspaceURL) else { return }
        recordExtensionUsage(cardID: cardID)
    }

    func seedExtensionUsageIfNeeded(from conversations: [ConversationRecord]) {
        guard !defaults.bool(forKey: Self.extensionUsageSeededKey) else { return }
        var seededCounts = extensionUsageCounts
        for conversation in conversations {
            let convWorkspace = conversation.workspace?.url
            for message in conversation.messages {
                for toolCall in message.toolCalls {
                    if toolCall.name == "computer_use" {
                        seededCounts["builtin:computer-use", default: 0] += 1
                    } else if let (serverID, _) = MCPToolNamespace.parse(exposedName: toolCall.name) {
                        seededCounts["mcp:\(serverID)", default: 0] += 1
                    } else if toolCall.name == "file_read",
                              let data = toolCall.input.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let rawPath = json["path"] as? String,
                              !rawPath.isEmpty {
                        let expandedPath = (rawPath as NSString).expandingTildeInPath
                        let fileURL: URL
                        if expandedPath.hasPrefix("/") {
                            fileURL = URL(fileURLWithPath: expandedPath)
                        } else if let convWorkspace {
                            fileURL = convWorkspace.appendingPathComponent(expandedPath)
                        } else {
                            continue
                        }
                        if let cardID = skillCardID(forFileURL: fileURL, workspaceURL: convWorkspace) {
                            seededCounts[cardID, default: 0] += 1
                        }
                    }
                }
            }
        }
        extensionUsageCounts = seededCounts
        defaults.set(seededCounts, forKey: Self.extensionUsageCountsKey)
        defaults.set(true, forKey: Self.extensionUsageSeededKey)
    }

    private func skillCardID(forFileURL url: URL, workspaceURL: URL?) -> String? {
        let candidateCanonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        let candidateStd = url.standardizedFileURL.path

        func match(in candidates: [Skill]) -> String? {
            for skill in candidates {
                let dirCanonical = skill.directoryURL.resolvingSymlinksInPath().standardizedFileURL.path
                let dirStd = skill.directoryURL.standardizedFileURL.path
                let prefixCanonical = dirCanonical.hasSuffix("/") ? dirCanonical : dirCanonical + "/"
                let prefixStd = dirStd.hasSuffix("/") ? dirStd : dirStd + "/"
                if candidateCanonical == dirCanonical || candidateCanonical.hasPrefix(prefixCanonical)
                    || candidateStd == dirStd || candidateStd.hasPrefix(prefixStd) {
                    return "skill:\(skill.id)"
                }
            }
            return nil
        }

        if let found = match(in: skills) {
            return found
        }
        if let workspaceURL, workspaceURL != currentWorkspaceURL {
            return match(in: scanner.scan(workspaceURL: workspaceURL))
        }
        return nil
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
