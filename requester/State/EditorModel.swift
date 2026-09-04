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

    /// The response on screen: the send that just finished, or the past one
    /// that was opened. Every entry that reaches it is also filed under its
    /// request, so leaving that request and coming back brings it with you.
    var lastEntry: HistoryEntry? {
        didSet {
            guard let entry = lastEntry, let requestID = entry.requestID else { return }
            lastEntryByRequestID[requestID] = entry
        }
    }

    /// The response last shown for each request, by request id.
    ///
    /// Held for the window's lifetime rather than written anywhere: this is
    /// about not losing what is on screen, and a request opened in a fresh
    /// window has nothing on screen to lose.
    private var lastEntryByRequestID: [String: HistoryEntry] = [:]

    /// The stage the send in flight is currently in, and when it started --
    /// what the response panel names and times while it runs. Both are cleared
    /// once the send finishes, since the finished entry carries its own,
    /// far more detailed timeline.
    private(set) var liveStage: RequestTimeline.Kind?
    private(set) var sendStartedAt: Date?

    /// Surfaced as an alert; a failed save or send should say so.
    var errorMessage: String?

    /// Shown briefly after a curl import or export -- on the way in so
    /// silently-dropped flags are visible, on the way out to confirm the copy.
    var curlNotice: String?

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

    /// Opens a saved request, with whatever response it last had on screen.
    func load(_ request: APIRequest) {
        autosaveTask?.cancel()
        draft = request
        saved = request
        lastEntry = lastEntryByRequestID[request.id]
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
        sendStartedAt = Date()
        defer {
            isSending = false
            liveStage = nil
            sendStartedAt = nil
        }

        do {
            // The observer is called from the pipeline's own context, so it
            // hops back here before touching observable state.
            let entry = try await sender.sendAndRecord(draft.normalized) { stage in
                await MainActor.run { self.liveStage = stage }
            }
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
        curlNotice = parsed.unsupported.isEmpty
            ? "Imported curl command."
            : "Imported curl command. Ignored: \(parsed.unsupported.joined(separator: ", "))"
    }
}
