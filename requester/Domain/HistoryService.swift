import Foundation

/// Orchestrates one send: inherit the project's global headers, resolve
/// `{{variables}}`, send, persist history unconditionally, run the
/// post-response script, persist what it wrote.
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
    let projects: ProjectRepository
    let scripts: ScriptRunner

    /// Told which stage is starting, as it starts.
    ///
    /// The pipeline's stages are the only ones observable live: the network
    /// phases inside the send arrive as one batch of metrics once the task has
    /// completed, so nothing can announce that DNS has finished while it is
    /// finishing.
    typealias StageObserver = @Sendable (RequestTimeline.Kind) async -> Void

    func sendAndRecord(
        _ request: APIRequest, onStage: StageObserver? = nil
    ) async throws -> HistoryEntry {
        let sentAt = Date()
        var timeline = RequestTimeline()

        /// Runs one stage, announcing it as it begins.
        ///
        /// `records: false` is for the two stages that write the record: a
        /// timeline cannot state how long it took to save the file it is being
        /// saved into. They are still announced, so the live indicator names
        /// them while they run.
        func stage<T>(
            _ kind: RequestTimeline.Kind, records: Bool = true, _ work: () async throws -> T
        ) async rethrows -> T {
            await onStage?(kind)
            let start = Date()
            defer { if records { timeline.add(kind, from: start, to: Date(), since: sentAt) } }
            return try await work()
        }

        /// The timeline as it stands, for writing into the record now.
        func timelineSoFar() -> RequestTimeline {
            var snapshot = timeline
            snapshot.totalMilliseconds = Date().timeIntervalSince(sentAt) * 1000
            return snapshot
        }

        // Global headers are merged in before resolution, so a `{{variable}}`
        // in one is substituted exactly as it would be in the request's own.
        let resolved = try await stage(.prepare) {
            let project = try await projects.get(request.projectID)
            let merged = HeaderMerge.apply(project?.globalHeaders ?? [], to: request)
            let variableValues = try await variables.values(projectID: request.projectID)
            return VariableResolver.resolve(merged, with: variableValues)
        }

        func newEntry() -> HistoryEntry {
            HistoryEntry(
                id: ProjectRepository.newIdentifier(),
                projectID: request.projectID,
                requestID: request.id.isEmpty ? nil : request.id,
                // The snapshot is the request as authored -- without the
                // project's headers folded in, which belong to the project and
                // may since have changed. What actually went over the wire is
                // recorded separately, in `requestHeadersSent`.
                requestSnapshot: request,
                resolvedURL: resolved.url,
                sentAt: sentAt
            )
        }

        let sent: HTTPExecutor.Sent
        do {
            sent = try await stage(.send) { try await executor.send(resolved) }
        } catch {
            var entry = newEntry()
            entry.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            // A failed send keeps its timeline: how long it spent before
            // giving up is the whole question about a timeout.
            entry.timeline = timelineSoFar()
            return try await stage(.saveHistory, records: false) {
                try await history.append(entry)
            }
        }

        // The network phases are known only now, and are measured from the same
        // origin as the stages around them.
        timeline.spans += sent.networkSpans
        timeline.reusedConnectionHops = sent.reusedConnectionHops

        var entry = newEntry()
        entry.requestHeadersSent = sent.headers
        entry.requestBodySent = sent.bodyText
        entry.response = sent.response
        entry.timeMilliseconds = sent.response.elapsedMilliseconds
        entry.timeline = timelineSoFar()

        // Two forms from here on. `stored` is what went to disk: a big body is
        // spilled to its own blob file and trimmed inline, so the history JSONL
        // stays small enough to re-read on every query. `displayed` keeps the
        // whole body, which is already in memory -- the size limit exists to
        // keep history readable, not to hide the response from the caller.
        let stored = try await stage(.saveHistory, records: false) {
            try await history.append(entry)
        }
        var displayed = stored
        if stored.response?.bodyTruncated == true {
            displayed.response?.bodyText = sent.response.bodyText
            displayed.response?.bodyTruncated = false
        }

        guard !request.postResponseScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return displayed }

        let result = await stage(.script) {
            await scripts.run(
                source: request.postResponseScript,
                response: sent.response,
                timeoutSeconds: request.scriptTimeoutSeconds
            )
        }

        // The amendment rewrites the whole record, so it is what carries the
        // script's own timing -- the first line was written before the script
        // had run.
        var amendable = stored
        amendable.timeline = timelineSoFar()

        let amended = try await stage(.saveScriptResult, records: false) {
            if !result.variablesWritten.isEmpty {
                try await variables.setMany(
                    projectID: request.projectID,
                    writes: result.variablesWritten,
                    source: .script,
                    sourceRequestID: request.id
                )
            }
            // The amendment is appended to the stored form, so the trimmed body
            // is not written back in full.
            return try await history.appendScriptResult(result, to: amendable)
        }
        displayed.scriptResult = amended.scriptResult
        displayed.timeline = amended.timeline
        return displayed
    }
}
