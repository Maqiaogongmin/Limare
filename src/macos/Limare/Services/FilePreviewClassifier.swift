import Foundation
import UniformTypeIdentifiers

/// Classifies file URLs into deterministic P0 FilePreviewKind categories.
/// Strictly prioritizes explicit extensions and explicit exclusion of P1/P2 formats.
public enum FilePreviewClassifier {

    public static func classify(url: URL) -> FilePreviewKind {
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.lowercased()

        // 1. Explicit Markdown
        if ["md", "markdown"].contains(ext) {
            return .markdown
        }

        // 2. Explicit HTML
        if ["html", "htm"].contains(ext) {
            return .html
        }

        // 3. Explicit Code Extensions & Special Filenames
        if let codeKind = codeLanguage(for: ext, filename: filename) {
            return .code(language: codeKind)
        }

        // 4. Explicit Image Extensions (SVG belongs to Image, not XML Text)
        if ["png", "jpg", "jpeg", "webp", "gif", "svg"].contains(ext) {
            return .image
        }

        // 5. Explicit PDF
        if ext == "pdf" {
            return .pdf
        }

        // 6. Explicit P0 Text Extensions
        if ["txt", "log", "json", "yaml", "yml", "xml", "env", "ini", "conf", "plist", "properties", "cfg", "ndjson", "jsonl"].contains(ext) {
            return .text
        }

        // 7. Explicit Excluded P1/P2 Formats (Must be rejected to unsupported, not text)
        if isExplicitUnsupported(ext: ext) {
            return .unsupported(reason: "Preview isn’t available for this file type.")
        }

        // 8. Conservative Fallback
        return .unsupported(reason: "Preview isn’t available for this file type.")
    }

    private static func codeLanguage(for ext: String, filename: String) -> String? {
        if filename == "dockerfile" || ext == "dockerfile" {
            return "Dockerfile"
        }
        if filename == "makefile" || ext == "makefile" {
            return "Makefile"
        }

        switch ext {
        case "swift": return "Swift"
        case "py", "python": return "Python"
        case "js", "mjs", "cjs": return "JavaScript"
        case "ts", "mts", "cts": return "TypeScript"
        case "tsx": return "TypeScript React"
        case "jsx": return "JavaScript React"
        case "rs": return "Rust"
        case "go": return "Go"
        case "rb": return "Ruby"
        case "java": return "Java"
        case "kt", "kts": return "Kotlin"
        case "c": return "C"
        case "cpp", "cc", "cxx": return "C++"
        case "h", "hpp": return "C/C++ Header"
        case "sh", "bash", "zsh": return "Shell"
        case "css", "scss", "sass", "less": return "CSS"
        case "sql": return "SQL"
        case "graphql", "gql": return "GraphQL"
        case "proto": return "Protobuf"
        case "toml": return "TOML"
        case "lua": return "Lua"
        case "r": return "R"
        case "scala": return "Scala"
        case "php": return "PHP"
        default: return nil
        }
    }

    private static func isExplicitUnsupported(ext: String) -> Bool {
        let unsupportedExtensions: Set<String> = [
            "csv", "tsv",
            "doc", "docx", "xls", "xlsx", "ppt", "pptx",
            "pages", "numbers", "key",
            "mp3", "wav", "m4a", "aac", "flac", "ogg",
            "mp4", "mov", "avi", "mkv", "webm",
            "zip", "tar", "gz", "7z", "rar", "bz2", "xz",
            "dmg", "pkg", "exe", "bin", "dat", "iso", "o", "a", "dylib", "so"
        ]
        return unsupportedExtensions.contains(ext)
    }
}
