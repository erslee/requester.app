import Foundation

/// The request currently open in the editor: its draft, whether that draft
/// diverges from what is on disk, and the save / send actions.
@MainActor
@Observable
final class EditorModel {
    private let requests: RequestRepository
    private let sender: HistoryService

    /// `nil` means nothing is open, which is what disables the editor.
    var draft: APIRequest?

    /// The last saved state of `draft`, so dirtiness is a comparison rather
    /// than a flag that has to be cleared by hand on every code path.
    private(set) var saved: APIRequest?

    var knownVariableNames: Set<String> = []
    var isSending = false
    var lastEntry: HistoryEntry?

    /// Surfaced as an alert; a failed save or send should say so.
    var errorMessage: String?

    /// Shown briefly after a curl import so silently-dropped flags are visible.
    var curlImportNotice: String?

    private static let autosaveDelay = Duration.milliseconds(700)
    private var autosaveTask: Task<Void, Never>?

    var onSaved: (@MainActor (APIRequest) async -> Void)?
    var onSent: (@MainActor (HistoryEntry) async -> Void)?

    init(requests: RequestRepository, sender: HistoryService) {
        self.requests = requests
        self.sender = sender
    }

    var isDirty: Bool {
        guard let draft, let saved else { return false }
        return draft.editableContent != saved.editableContent
    }

    var namePlaceholder: String {
        RequestNaming.derivedName(fromURL: draft?.url ?? "")
    }

    func load(_ request: APIRequest) {
        autosaveTask?.cancel()
        draft = request
        saved = request
        lastEntry = nil
    }

    /// Loads what a history entry actually sent -- resolved URL, the real
    /// headers, the real body -- rather than the `{{variable}}` template, so
    /// the editor shows what the server saw.
    func load(historyEntry entry: HistoryEntry) {
        autosaveTask?.cancel()
        var request = entry.requestSnapshot
        request.url = entry.resolvedURL
        request.headers = entry.requestHeadersSent
        if request.bodyMode == .raw { request.rawBody = entry.requestBodySent }

        draft = request
        saved = request
        lastEntry = entry
    }

    func clear() {
        autosaveTask?.cancel()
        draft = nil
        saved = nil
        lastEntry = nil
    }

    @discardableResult
    func save() async -> Bool {
        guard let draft else { return false }
        do {
            let persisted = try await requests.save(draft.normalized)
            saved = persisted

            // The draft is deliberately not replaced with what was written:
            // keystrokes can land while the write is in flight, and overwriting
            // would discard them. Only the timestamp is carried across, so the
            // dirty comparison comes from the right baseline -- and anything
            // typed meanwhile stays dirty and gets saved by the next pass.
            if var current = self.draft {
                current.updatedAt = persisted.updatedAt
                self.draft = current
            }

            await onSaved?(persisted)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Saves shortly after editing stops, so finishing a field commits it
    /// without an explicit save.
    ///
    /// Debounced rather than saved per keystroke: every write also refreshes the
    /// sidebar, and a URL typed character by character would otherwise mean a
    /// write and a project reload per character.
    func scheduleAutosave() {
        autosaveTask?.cancel()
        guard isDirty else {
            autosaveTask = nil
            return
        }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Writes a pending autosave immediately -- on Return, on losing focus, and
    /// before the editor moves to a different request, where waiting out the
    /// delay would lose the edit.
    func flushAutosave() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard isDirty else { return }
        await save()
    }

    func send() async {
        guard let draft, !isSending else { return }
        isSending = true
        defer { isSending = false }

        do {
            let entry = try await sender.sendAndRecord(draft.normalized)
            lastEntry = entry
            await onSent?(entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Applies a pasted curl command over the draft. Only the fields curl
    /// actually described are replaced -- the request keeps its name, scripts,
    /// and identity.
    func apply(_ parsed: CurlParser.Parsed) {
        guard draft != nil else { return }
        draft?.method = parsed.method
        draft?.url = parsed.url
        draft?.params = parsed.params
        draft?.headers = parsed.headers
        draft?.bodyMode = parsed.bodyMode
        draft?.rawBody = parsed.rawBody
        draft?.formFields = parsed.formFields
        if let graphQL = parsed.graphQLBody { draft?.graphQLBody = graphQL }
        draft?.auth = parsed.auth
        curlImportNotice = parsed.unsupported.isEmpty
            ? "Imported curl command."
            : "Imported curl command. Ignored: \(parsed.unsupported.joined(separator: ", "))"
    }
}
