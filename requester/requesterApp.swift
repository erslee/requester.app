import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct RequesterApp: App {
    @State private var launch = LaunchState()

    var body: some Scene {
        WindowGroup {
            Group {
                switch launch.phase {
                case .ready(let model):
                    ContentView(model: model)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Could Not Open Your Data", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Use the Default Folder") { launch.useDefaultFolder() }
                            .buttonStyle(.borderedProminent)
                        Button("Choose a Folder…") { launch.isChoosingFolder = true }
                    }
                }
            }
            // Wide enough for the sidebar, the editor, and the history
            // inspector at their minimums. Any narrower and the split view
            // lays out wider than the window, pushing the sidebar off its
            // left edge where it cannot be clicked.
            .frame(minWidth: 1180, minHeight: 700)
            .fileImporter(
                isPresented: $launch.isChoosingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    launch.adopt(url)
                }
            }
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Import Collection…") {
                    launch.model?.isChoosingImportFile = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(launch.model == nil || launch.model?.isImporting == true)

                Divider()
                Button("Reveal Data Folder in Finder") { launch.revealDataFolder() }
                Button("Change Data Folder…") { launch.isChoosingFolder = true }
                Button("Use Default Data Folder") { launch.useDefaultFolder() }
                    .disabled(launch.isUsingDefaultFolder)
            }
        }
    }
}

/// Opens the app's data folder and holds the wired model.
///
/// There is no first-run prompt: the default folder needs no permission, so the
/// app comes up straight into the main window. Pointing it at a different
/// folder is an explicit choice from the File menu.
@MainActor
@Observable
final class LaunchState {
    enum Phase {
        case ready(AppModel)
        case failed(String)
    }

    /// Overrides the data folder, for scripted runs and UI tests. An absolute
    /// path must be one the sandbox already allows; a bare name is resolved
    /// inside the app's own container, which is how UI tests get a throwaway
    /// folder (their runner is sandboxed too and cannot create one there).
    static let dataRootEnvironmentKey = "REQUESTER_DATA_ROOT"

    private let roots = StorageRootStore()
    private(set) var phase: Phase = .failed("")
    private(set) var currentRoot: URL?

    /// Drives the folder picker, which is only ever opened deliberately.
    var isChoosingFolder = false

    var isUsingDefaultFolder: Bool { roots.isUsingDefaultRoot }

    /// The wired model, once there is one. Lets the menu commands reach it --
    /// the scene owns the menu but the model lives inside the phase.
    var model: AppModel? {
        guard case .ready(let model) = phase else { return nil }
        return model
    }

    init() {
        open(startupRoot())
    }

    func adopt(_ url: URL) {
        do {
            open(try roots.adopt(url))
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    func useDefaultFolder() {
        open(roots.useDefaultRoot())
    }

    /// The default folder lives inside the sandbox container, where it is not
    /// obvious in Finder -- so there is a command to go straight to it.
    func revealDataFolder() {
        guard let currentRoot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([currentRoot])
    }

    private func startupRoot() -> URL {
        if let path = ProcessInfo.processInfo.environment[Self.dataRootEnvironmentKey],
           !path.isEmpty {
            return path.hasPrefix("/")
                ? URL(filePath: path, directoryHint: .isDirectory)
                : FileManager.default.temporaryDirectory.appending(path: path)
        }
        return roots.resolveRoot()
    }

    private func open(_ url: URL) {
        do {
            let storage = try LocalFileStorage(root: url)
            currentRoot = url
            phase = .ready(AppModel(storage: storage))
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// Includes the recovery suggestion, so the message says what to do next
    /// rather than only what went wrong.
    private static func describe(_ error: any Error) -> String {
        guard let localized = error as? any LocalizedError else {
            return error.localizedDescription
        }
        return [localized.errorDescription, localized.recoverySuggestion]
            .compactMap(\.self)
            .joined(separator: " ")
    }
}
