import AppKit
import Foundation

@MainActor
protocol WorkspacePicking {
    func chooseWorkspace() -> URL?
}

struct WorkspacePicker: WorkspacePicking {
    func chooseWorkspace() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.message = "Choose a project folder as the default working directory."
        panel.prompt = "Choose Project Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
