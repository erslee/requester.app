# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS HTTP client (SwiftUI, Swift 6 strict concurrency, **no third-party
dependencies**). Xcode project, not SwiftPM. `README.md` covers the user-facing
feature set, the on-disk data format, and the known limitations — read it before
changing behaviour in those areas.

## Commands

```sh
# Build (Debug)
xcodebuild -project requester.xcodeproj -scheme requester \
           -configuration Debug -destination 'platform=macOS' build

# Unit tests — fast, no window server needed
xcodebuild -project requester.xcodeproj -scheme requester \
           -destination 'platform=macOS' -only-testing:requesterTests test

# One suite, or one test
-only-testing:requesterTests/CurlParserTests
-only-testing:requesterTests/CurlParserTests/parsesMultipartFormFields

# UI tests (drives the real app; see below)
-only-testing:requesterUITests
```

On a machine without signing credentials, append
`CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=""` — ad-hoc signing
still applies the entitlements, so the sandboxed app builds and runs its tests.
That is what CI does.

There is no linter or formatter configured.

## Project mechanics

- The Xcode targets use **file-system synchronized groups**: a new `.swift` file
  under `requester/`, `requesterTests/`, or `requesterUITests/` is picked up
  automatically. Never hand-edit `project.pbxproj` to add a file.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — unannotated code is main-actor
  isolated. Everything in `Models/`, `Domain/`, `Repositories/`, and `Storage/` is
  therefore explicitly `nonisolated` (and `Sendable`). Keep it that way; dropping
  the annotation silently pulls domain logic onto the main actor.
- `PRODUCT_NAME = Requester` but `PRODUCT_MODULE_NAME = requester` — tests use
  `@testable import requester`.
- Sandboxed, and all three entitlements are load-bearing: outgoing network,
  user-selected files read-write (the collection importer), and the sandbox
  itself.

## Architecture

Strictly layered, each layer depending only on the one below.
`Views/` → `State/` → `Repositories/` + `Domain/` → `Storage/` → `Models/`.
`Domain/` must not import SwiftUI; it is where nearly all the tests point.

**`StorageBackend`** (`Storage/StorageBackend.swift`) is a protocol over plain
text files addressed by relative path, so a remote backend can be swapped in
without touching repositories, domain, or views. `LocalFileStorage` is an actor
so concurrent appends to one history file cannot interleave. Repositories own
the path layout (`projects/<id>/…`, `variables/<id>.json`,
`history/<id>/YYYY-MM.jsonl`); nothing above them constructs paths.

**Dependency wiring happens in one place**: `AppModel.init` builds the
repositories over the injected `StorageBackend` and assembles
`HistoryService(executor:history:variables:scripts:)`. Tests construct the same
graph over `InMemoryStorage` (`requesterTests/StorageTests.swift`) or a temp-dir
`LocalFileStorage`, and inject a stubbed `URLSession` into `HTTPExecutor`.

**`HistoryService.sendAndRecord`** is the pipeline everything else feeds:
resolve `{{variables}}` → send → append history → run the post-response script →
persist what it wrote. Its invariants are deliberate and tested:

- A failed send still produces a history entry (no `response`, an `error` instead).
- History is **append-only and never rewritten**. The script finishes after the
  response is already persisted, so its result is appended as a second full line
  sharing the same entry id; readers keep the last line written per id.
- A response body over 256 KB is spilled to `history/<project>/blobs/<id>.body`
  and trimmed inline, so re-reading a month stays cheap. The service returns the
  *untrimmed* form to the caller — the size limit is about file size, not display.

**Variables are resolved only at send time.** Saved requests keep their
unresolved `{{name}}` templates; an unknown name is left literal rather than
blanked, so a typo is visible in the request that reaches the server. A history
entry stores both the template (`requestSnapshot`) and what actually went over
the wire (`resolvedURL`, `requestHeadersSent`, `requestBodySent`) — opening one
in the editor loads the resolved form.

**`EditorModel`** holds `draft` plus `saved`, so dirtiness is a comparison
(`editableContent`, timestamps excluded) rather than a flag to clear by hand.
Autosave is debounced 700 ms; `flushAutosave()` must be awaited before the
editor moves to another request. A completed save deliberately does **not**
replace `draft` — only its `updatedAt` — because keystrokes can land while the
write is in flight.

**`ScriptRunner`** evaluates JavaScriptCore on its own dedicated thread with a
manual timeout race (not a task group — a group awaits children, and a hung
script never returns). It is a hang-safety boundary, not a security sandbox.

**Data folder resolution** lives in `StorageRootStore` (the container's
`Application Support/Requester`, and nothing else — the folder is not
configurable) and `LaunchState` in `requesterApp.swift`. The
`REQUESTER_DATA_ROOT` environment variable overrides it — a bare name resolves
inside the app's own container, which is how UI tests get a throwaway folder.

## Tests

Unit tests are **Swift Testing** (`@Test`, `@Suite`, `#expect`), UI tests are
XCTest. Suites follow an Arrange / Act / Assert comment structure.

- Storage-level tests use `InMemoryStorage`; pipeline tests use a temp-dir
  `LocalFileStorage` and `StubURLProtocol`.
- `SendPipelineTests` is `@Suite(.serialized)` — its canned response is
  process-global and parallel runs would clobber each other.
- UI tests are not a merge gate (`continue-on-error` in CI). The first launch of
  a freshly built binary intermittently comes up with no window; the tests
  relaunch once to work around it. If they fail right after a build, run again.
- UI queries are scoped to `app.windows.firstMatch` — a bare `app.buttons[…]`
  can match a Touch Bar proxy.

## Release

Push a `v*` tag; `.github/workflows/release.yml` runs the unit tests, builds
Release with `MARKETING_VERSION` taken from the tag, and publishes the zip. The
artifact is ad-hoc signed, not notarised.
