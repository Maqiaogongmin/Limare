import Foundation
import Observation

/// What the Changes surface reads Git through; the service in the app, a fake in tests.
protocol GitReviewReading: Sendable {
    func locate(workspace: URL) async -> GitReviewService.Location
    func readSnapshot(root: URL, scope: GitReviewScope, base: String?) async throws -> GitReviewSnapshot
    func readBaseChoices(root: URL, currentBranch: String?) async throws -> GitReviewService.BaseChoices
    func readPatch(root: URL, scope: GitReviewScope, base: String?, file: GitChangedFile) async -> GitReviewService.PatchResult
}

extension GitReviewService: GitReviewReading {}

/// One window's Changes surface: the repository of its conversation's working directory, the
/// scope shown, the selected file's diff, and the comments not yet added to a message. Comments
/// are kept by the app's `ReviewCommentStore`, per conversation and working directory.
@MainActor
@Observable
final class GitReviewStore {
    enum RefreshReason: Sendable, Equatable {
        case opened
        case scopeChanged
        case baseChanged
        case workspaceChanged
        case windowActivated
        case runFinished
        case manual

        /// Asked for by the user, or a change of what is compared: the selected file's diff is
        /// read again. The automatic ones reread it only when its line of the file list changed.
        var reloadsPatch: Bool {
            switch self {
            case .windowActivated, .runFinished: false
            default: true
            }
        }

        /// Looks for the repository again rather than trusting the last answer.
        var relocates: Bool {
            switch self {
            case .opened, .workspaceChanged, .manual: true
            default: false
            }
        }

        fileprivate var strength: Int {
            switch self {
            case .windowActivated, .runFinished: 0
            case .opened, .scopeChanged, .baseChanged: 1
            case .manual: 2
            case .workspaceChanged: 3
            }
        }
    }

    enum Availability: Sendable, Equatable {
        /// Nothing bound or read yet.
        case idle
        case unavailable(GitRepositoryUnavailable)
        case repository(root: URL)
    }

    /// The selected file's diff.
    struct PatchState: Sendable, Equatable {
        var path: String
        var result: GitReviewService.PatchResult?
        var readAt: Date?
        var isLoading: Bool
    }

    /// The line a comment is being written on. Its text is `editorText`, apart, so typing
    /// doesn't redraw the diff around it.
    struct CommentEditor: Sendable, Equatable {
        var anchor: GitLineAnchor
        /// Set when editing a comment already saved.
        var commentID: UUID?
    }

    struct BindingKey: Hashable, Codable, Sendable {
        var conversationID: UUID?
        var workspace: String
    }

    private(set) var workspace: URL?
    private(set) var conversationID: UUID?
    private(set) var availability: Availability = .idle
    private(set) var scope: GitReviewScope = .all
    private(set) var base: String?
    /// A worktree conversation's base commit and its branch's name, for the Task scope.
    private(set) var taskBase: String?
    private(set) var taskBaseName: String?
    private(set) var baseChoices: GitReviewService.BaseChoices?
    private(set) var snapshot: GitReviewSnapshot?
    private(set) var isRefreshing = false
    /// The last refresh failed; the previous snapshot, if any, is still shown.
    private(set) var refreshError: String?
    private(set) var selectedPath: String?
    private(set) var patch: PatchState?
    private(set) var editor: CommentEditor?
    var editorText = ""
    /// A line the diff should scroll to, set when jumping to a comment.
    var scrollTarget: GitLineAnchor.Key?

    @ObservationIgnored private let reader: any GitReviewReading
    let commentStore: ReviewCommentStore
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh: RefreshReason?
    @ObservationIgnored private var patchTask: Task<Void, Never>?
    @ObservationIgnored private var patchGeneration = 0
    @ObservationIgnored private var bindingGeneration = 0
    /// Receives operation, outcome and time of each refresh; never paths or contents.
    @ObservationIgnored var log: (@MainActor (String) -> Void)?

    /// `comments` nil keeps them in memory, for this store alone.
    init(reader: any GitReviewReading = GitReviewService(), comments: ReviewCommentStore? = nil) {
        self.reader = reader
        self.commentStore = comments ?? ReviewCommentStore(fileURL: nil)
    }

    var bindingKey: BindingKey? {
        workspace.map { BindingKey(conversationID: conversationID, workspace: GitReviewService.canonical($0)) }
    }

    /// The comments of the bound conversation and working directory.
    var comments: [GitReviewComment] {
        bindingKey.map { commentStore.comments(for: $0) } ?? []
    }

    /// Comments in every conversation not yet added to a message, counting one this window
    /// is still writing.
    var unsentCommentCount: Int {
        let unsaved = editor != nil && editor?.commentID == nil && !editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0
        return commentStore.totalCount + unsaved
    }

    /// Opens the editor on a saved comment, showing its line first.
    func edit(_ comment: GitReviewComment) {
        reveal(comment)
        editor = CommentEditor(anchor: comment.anchor, commentID: comment.id)
        editorText = comment.body
    }

    var selectedFile: GitChangedFile? {
        guard let selectedPath else { return nil }
        return snapshot?.files.first { $0.path == selectedPath }
    }

    var repositoryRoot: URL? {
        if case .repository(let root) = availability { return root }
        return nil
    }

    // MARK: - Binding

    /// Follows the window's conversation and its working directory. Idempotent; a new pair drops
    /// what was read for the old one, and its comments stay with it. Refreshes now only when
    /// `refresh` says the surface is showing.
    func bind(workspace: URL?, conversationID: UUID?, refresh: Bool, taskBase: String? = nil, taskBaseName: String? = nil) {
        let sameWorkspace = workspace.map(GitReviewService.canonical) == self.workspace.map(GitReviewService.canonical)
        let sameTaskBase = taskBase == self.taskBase
        guard !sameWorkspace || conversationID != self.conversationID || !sameTaskBase else { return }
        saveEditor()
        self.conversationID = conversationID
        self.taskBase = taskBase
        self.taskBaseName = taskBaseName
        // The repository reading stays live across conversations sharing the same folder and base;
        // their comments are still keyed separately by conversation.
        guard !sameWorkspace || !sameTaskBase else { return }
        self.workspace = workspace
        bindingGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        pendingRefresh = nil
        patchTask?.cancel()
        availability = .idle
        snapshot = nil
        baseChoices = nil
        base = nil
        scope = .all
        refreshError = nil
        selectedPath = nil
        patch = nil
        editor = nil
        isRefreshing = false
        if refresh, workspace != nil { self.refresh(.workspaceChanged) }
    }

    // MARK: - Refreshing

    /// Reads the file list again. One refresh runs at a time; requests made meanwhile collapse
    /// into one more afterwards, with the strongest reason among them.
    func refresh(_ reason: RefreshReason) {
        guard workspace != nil else { return }
        if reason == .manual { saveEditor() }
        if refreshTask != nil {
            if let pending = pendingRefresh, pending.strength >= reason.strength { return }
            pendingRefresh = reason
            return
        }
        isRefreshing = true
        let generation = bindingGeneration
        refreshTask = Task { [weak self] in
            await self?.performRefresh(reason, generation: generation)
            guard let self, generation == self.bindingGeneration else { return }
            self.refreshTask = nil
            self.isRefreshing = false
            if let next = self.pendingRefresh {
                self.pendingRefresh = nil
                self.refresh(next)
            }
        }
    }

    /// Waits until no refresh is running or pending. For tests.
    func settle() async {
        while let task = refreshTask {
            await task.value
        }
        await patchTask?.value
    }

    private func performRefresh(_ reason: RefreshReason, generation: Int) async {
        guard let workspace else { return }
        let started = Date()
        var root = repositoryRoot
        if root == nil || reason.relocates {
            let location = await reader.locate(workspace: workspace)
            guard generation == bindingGeneration else { return }
            switch location {
            case .unavailable(let why):
                availability = .unavailable(why)
                snapshot = nil
                selectedPath = nil
                patch = nil
                refreshError = nil
                log?("Changes locate: unavailable")
                return
            case .repository(let found):
                availability = .repository(root: found)
                root = found
            }
        }
        guard let root else { return }

        do {
            // The bases leave out the current branch, so they are read once the branch is known,
            // except when Branch needs a base before it can read anything.
            var needsChoices = baseChoices == nil || reason.relocates
            if needsChoices, scope == .branch {
                try await loadBaseChoices(root: root, currentBranch: snapshot?.branch, generation: generation)
                needsChoices = false
            }
            var read: GitReviewSnapshot
            do {
                read = try await reader.readSnapshot(root: root, scope: scope, base: comparedBase(for: scope))
            } catch GitReviewService.Failure.requiresCommit {
                // No commit yet: All and Branch can't be shown, Unstaged can.
                guard generation == bindingGeneration else { return }
                scope = .unstaged
                read = try await reader.readSnapshot(root: root, scope: .unstaged, base: nil)
            }
            guard generation == bindingGeneration else { return }
            if needsChoices {
                try await loadBaseChoices(root: root, currentBranch: read.branch, generation: generation)
            }
            apply(read, reason: reason)
            log?("Changes refresh \(scope.rawValue): ok \(Self.milliseconds(since: started))ms")
        } catch is CancellationError {
            return
        } catch {
            guard generation == bindingGeneration else { return }
            refreshError = error.localizedDescription
            log?("Changes refresh \(scope.rawValue): failed \(Self.milliseconds(since: started))ms")
        }
    }

    private func loadBaseChoices(root: URL, currentBranch: GitBranchState?, generation: Int) async throws {
        let current: String? = if case .branch(let name)? = currentBranch { name } else { nil }
        let choices = try? await reader.readBaseChoices(root: root, currentBranch: current)
        guard generation == bindingGeneration else { throw CancellationError() }
        baseChoices = choices
        if let base, choices?.candidates.contains(base) != true { self.base = nil }
        if base == nil { base = choices?.defaultBase }
    }

    /// What `scope` compares against: the chosen branch for Branch, the task base for Task.
    private func comparedBase(for scope: GitReviewScope) -> String? {
        switch scope {
        case .branch: base
        case .task: taskBase
        default: nil
        }
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func apply(_ read: GitReviewSnapshot, reason: RefreshReason) {
        let previous = snapshot
        let previousFile = selectedFile
        snapshot = read
        refreshError = nil

        // Keep the selection; if its file is gone, take the one now at its place.
        if let path = selectedPath, !read.files.contains(where: { $0.path == path }) {
            let index = previous?.files.firstIndex { $0.path == path } ?? 0
            selectedPath = read.files.isEmpty ? nil : read.files[min(index, read.files.count - 1)].path
            if editor?.anchor.path == path { editor = nil }
        }
        if selectedPath == nil, let first = read.files.first {
            selectedPath = first.path
        }
        guard let file = selectedFile else {
            patch = nil
            return
        }
        // An automatic refresh leaves the diff alone while a comment is being written on it.
        if !reason.reloadsPatch, editor?.anchor.path == file.path { return }
        if reason.reloadsPatch || file != previousFile || patch?.path != file.path {
            loadPatch()
        }
    }

    // MARK: - Scope, base, selection

    func setScope(_ newScope: GitReviewScope) {
        guard newScope != scope else { return }
        saveEditor()
        scope = newScope
        refresh(.scopeChanged)
    }

    func setBase(_ newBase: String) {
        guard newBase != base else { return }
        saveEditor()
        base = newBase
        if scope == .branch { refresh(.baseChanged) }
    }

    func showTaskReview() {
        guard taskBase != nil else { return }
        setScope(.task)
    }

    /// Whether `scope` can be shown, and why not.
    func unavailability(of scope: GitReviewScope) -> String? {
        switch scope {
        case .all:
            return snapshot?.hasHead == false ? String(localized: "Needs a first commit") : nil
        case .branch:
            if snapshot?.hasHead == false { return String(localized: "Needs a first commit") }
            if baseChoices != nil, base == nil { return String(localized: "No branch to compare against") }
            return nil
        case .task:
            return taskBase == nil ? String(localized: "Only in a worktree conversation") : nil
        case .unstaged, .staged:
            return nil
        }
    }

    func select(path: String) {
        guard path != selectedPath || patch == nil else { return }
        saveEditor()
        selectedPath = path
        loadPatch()
    }

    /// Clears the selection, as the narrow layout's Back does.
    func deselect() {
        saveEditor()
        selectedPath = nil
        patch = nil
        patchTask?.cancel()
    }

    private func loadPatch() {
        guard let root = repositoryRoot, let file = selectedFile else { return }
        patchTask?.cancel()
        patchGeneration += 1
        let generation = patchGeneration
        let previous = patch?.path == file.path ? patch : nil
        patch = PatchState(path: file.path, result: previous?.result, readAt: previous?.readAt, isLoading: true)
        let scope = self.scope, base = comparedBase(for: scope)
        let reader = self.reader
        patchTask = Task { [weak self] in
            let result = await reader.readPatch(root: root, scope: scope, base: base, file: file)
            guard let self, !Task.isCancelled, generation == self.patchGeneration else { return }
            self.patch = PatchState(path: file.path, result: result, readAt: Date(), isLoading: false)
            self.validateComments(path: file.path, scope: scope, base: scope == .branch ? base : nil, result: result)
        }
    }

    // MARK: - Comments

    /// Marks the comments on `path` in `scope` (against `base`, for Branch) outdated whose line no
    /// longer holds the quoted text. Nothing is moved to another line; a read that failed leaves
    /// them as they were.
    func validateComments(path: String, scope: GitReviewScope, base: String? = nil, result: GitReviewService.PatchResult) {
        guard let key = bindingKey else { return }
        var list = commentStore.comments(for: key)
        guard !list.isEmpty else { return }
        let document: GitDiffDocument?
        switch result {
        case .document(let doc): document = doc
        case .failed, .tooLarge: return
        default: document = nil
        }
        for index in list.indices where list[index].anchor.path == path && list[index].anchor.scope == scope
            && list[index].anchor.base == base {
            let anchor = list[index].anchor
            let current = document?.line(side: anchor.side, number: anchor.line)
            list[index].isOutdated = current.map { !anchor.matches($0) } ?? true
        }
        commentStore.set(list, for: key)
    }

    func comment(at key: GitLineAnchor.Key) -> GitReviewComment? {
        comments.first { $0.anchor.key == key }
    }

    /// Opens the editor on `line`, with its comment if it has one.
    func beginComment(on line: GitDiffLine, path: String) {
        guard line.anchorLine != nil else { return }
        let anchor = GitLineAnchor(scope: scope, base: base, path: path, line: line)
        if editor?.anchor.key == anchor.key { return }
        saveEditor()
        if let existing = comment(at: anchor.key) {
            editor = CommentEditor(anchor: existing.anchor, commentID: existing.id)
            editorText = existing.body
        } else {
            editor = CommentEditor(anchor: anchor, commentID: nil)
            editorText = ""
        }
    }

    /// Saves the open editor. Saving an empty comment removes it.
    func saveEditor() {
        guard let editing = editor, let key = bindingKey else { return }
        editor = nil
        var list = commentStore.comments(for: key)
        let body = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        editorText = ""
        if let id = editing.commentID, let index = list.firstIndex(where: { $0.id == id }) {
            if body.isEmpty {
                list.remove(at: index)
            } else {
                list[index].body = body
            }
        } else if !body.isEmpty {
            list.removeAll { $0.anchor.key == editing.anchor.key }
            list.append(GitReviewComment(anchor: editing.anchor, body: body))
        }
        commentStore.set(list, for: key)
    }

    func cancelEditor() {
        editor = nil
        editorText = ""
    }

    func deleteComment(id: UUID) {
        guard let key = bindingKey else { return }
        if editor?.commentID == id { editor = nil }
        var list = commentStore.comments(for: key)
        list.removeAll { $0.id == id }
        commentStore.set(list, for: key)
    }

    func clearComments() {
        guard let key = bindingKey else { return }
        editor = nil
        commentStore.set([], for: key)
    }

    /// Drops the comment being written in `conversationID`; its saved comments are the store's.
    func discardEditor(for conversationID: UUID) {
        if self.conversationID == conversationID { editor = nil; editorText = "" }
    }

    /// Shows the comment's line: its scope, its file, scrolled to it.
    func reveal(_ comment: GitReviewComment) {
        saveEditor()
        if comment.anchor.scope != scope || (comment.anchor.scope == .branch && comment.anchor.base != base) {
            scope = comment.anchor.scope
            if let commentBase = comment.anchor.base { base = commentBase }
            selectedPath = comment.anchor.path
            refresh(.scopeChanged)
        } else if comment.anchor.path != selectedPath {
            select(path: comment.anchor.path)
        }
        scrollTarget = comment.anchor.key
    }

    /// The comments as a message, taken out of the surface: they leave it once in the draft.
    func takeMessage() -> String? {
        saveEditor()
        let context = GitReviewMessageBuilder.Context(
            projectName: (repositoryRoot ?? workspace)?.lastPathComponent ?? "",
            branch: snapshot?.branch,
            readAt: snapshot?.readAt
        )
        guard let message = GitReviewMessageBuilder.message(for: comments, context: context) else { return nil }
        clearComments()
        return message
    }
}
