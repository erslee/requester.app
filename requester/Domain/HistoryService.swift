import Foundation

/// Orchestrates one send: resolve `{{variables}}`, send, persist history
/// unconditionally, run the post-response script, persist what it wrote.
///
/// A failed send (bad URL, connection error, timeout) still produces a history
/// record -- it simply has no `response` and carries an `error` instead. A
/// script that crashes or hangs must never cost us the response we already
/// have, so history is appended *before* the script runs and the script's
/// result arrives as a separate amendment line once it finishes.
nonisolated struct HistoryService: Sendable {
    let executor: HTTPExecutor
    let history: HistoryRepository
    let variables: VariableRepository
    let scripts: ScriptRunner

    func sendAndRecord(_ request: APIRequest) async throws -> HistoryEntry {
        let sentAt = Date()
        let variableValues = try await variables.values(projectID: request.projectID)
        let resolved = VariableResolver.resolve(request, with: variableValues)

        func newEntry() -> HistoryEntry {
            HistoryEntry(
                id: ProjectRepository.newIdentifier(),
                projectID: request.projectID,
                requestID: request.id.isEmpty ? nil : request.id,
                requestSnapshot: request,
                resolvedURL: resolved.url,
                sentAt: sentAt
            )
        }

        let sent: HTTPExecutor.Sent
        do {
            sent = try await executor.send(resolved)
        } catch {
            var entry = newEntry()
            entry.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return try await history.append(entry)
        }

        var entry = newEntry()
        entry.requestHeadersSent = sent.headers
        entry.requestBodySent = sent.bodyText
        entry.response = sent.response
        entry.timeMilliseconds = sent.response.elapsedMilliseconds

        // Two forms from here on. `stored` is what went to disk: a big body is
        // spilled to its own blob file and trimmed inline, so the history JSONL
        // stays small enough to re-read on every query. `displayed` keeps the
        // whole body, which is already in memory -- the size limit exists to
        // keep history readable, not to hide the response from the caller.
        let stored = try await history.append(entry)
        var displayed = stored
        if stored.response?.bodyTruncated == true {
            displayed.response?.bodyText = sent.response.bodyText
            displayed.response?.bodyTruncated = false
        }

        guard !request.postResponseScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return displayed }

        let result = await scripts.run(
            source: request.postResponseScript,
            response: sent.response,
            timeoutSeconds: request.scriptTimeoutSeconds
        )
        if !result.variablesWritten.isEmpty {
            try await variables.setMany(
                projectID: request.projectID,
                writes: result.variablesWritten,
                source: .script,
                sourceRequestID: request.id
            )
        }
        // The amendment is appended to the stored form, so the trimmed body is
        // not written back in full.
        let amended = try await history.appendScriptResult(result, to: stored)
        displayed.scriptResult = amended.scriptResult
        return displayed
    }
}
