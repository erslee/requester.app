import SwiftUI
import UniformTypeIdentifiers

/// The project's API document: where it comes from, when it was last read, and
/// the buttons that read it again.
///
/// Nothing here happens on its own. A document is only ever re-read because the
/// user pressed Update or picked a new file.
struct SpecSectionView: View {
    @Bindable var model: AppModel
    let projectID: String

    @State private var isAdding = false
    @State private var draftURL = ""
    @State private var draftHeaders: [KeyValueItem] = []
    @State private var isEditingSource = false
    @State private var isConfirmingDetach = false

    private var project: Project? {
        model.projectList.first { $0.id == projectID }
    }

    private var source: SpecSource? { project?.specSource }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API DOCUMENT — OpenAPI or Swagger, in JSON")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let source {
                attached(source)
            } else {
                empty
            }
        }
        .fileImporter(
            isPresented: $model.isChoosingSpecFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await model.replaceSpecFile(projectID: projectID, url: url) }
        }
        .sheet(isPresented: $isAdding) { addSheet }
        .sheet(isPresented: $isEditingSource) { editSheet }
        .confirmationDialog(
            "Detach this document?",
            isPresented: $isConfirmingDetach,
            titleVisibility: .visible
        ) {
            Button("Detach", role: .destructive) {
                Task { await model.detachSpec(projectID: projectID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every request stays exactly as it is. Only the link is removed.")
        }
    }

    // MARK: - Attached

    private func attached(_ source: SpecSource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: source.kind == .url ? "link" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source.displayName)
                Text(lastSynced(source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if model.isSyncingSpec {
                ProgressView().controlSize(.small)
            }

            // A link is refreshed in place; a file has to be handed over again,
            // which is the same operation with the bytes coming from elsewhere.
            if source.kind == .url {
                Button("Update") {
                    Task { await model.updateSpecFromRemote(projectID: projectID) }
                }
                .help("Re-read the document and merge what changed")
            }

            Button(source.kind == .url ? "Upload File…" : "Replace File…") {
                model.isChoosingSpecFile = true
            }
            .help("Merge a document from a file, the same way Update does")

            Menu {
                if source.kind == .url {
                    Button("Edit Link…") {
                        draftURL = source.url
                        draftHeaders = source.headers
                        isEditingSource = true
                    }
                } else {
                    Button("Use a Link Instead…") {
                        draftURL = ""
                        draftHeaders = []
                        isAdding = true
                    }
                }
                Divider()
                Button("Detach…", role: .destructive) { isConfirmingDetach = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.isSyncingSpec)
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func lastSynced(_ source: SpecSource) -> String {
        guard let date = source.lastSyncedAt else { return "Not read yet" }
        return "Last read \(date.formatted(.relative(presentation: .named)))"
    }

    // MARK: - Empty

    private var empty: some View {
        HStack(spacing: 8) {
            Text("Import endpoints from a document, then update them when it changes.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button("Add Link…") {
                draftURL = ""
                draftHeaders = []
                isAdding = true
            }
            Button("Upload File…") { model.isChoosingSpecFile = true }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.isSyncingSpec)
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Sheets

    private var addSheet: some View {
        sourceSheet(title: "Add a Document Link", confirm: "Add and Read") {
            isAdding = false
            Task {
                await model.attachSpecLink(
                    projectID: projectID, url: draftURL, headers: draftHeaders
                )
            }
        } dismiss: {
            isAdding = false
        }
    }

    private var editSheet: some View {
        sourceSheet(title: "Edit Document Link", confirm: "Save") {
            isEditingSource = false
            guard var source else { return }
            source.url = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
            source.headers = draftHeaders.filter { !$0.isBlank }
            Task { await model.saveSpecSource(projectID: projectID, source: source) }
        } dismiss: {
            isEditingSource = false
        }
    }

    private func sourceSheet(
        title: String,
        confirm: String,
        commit: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("https://api.example.com/openapi.json", text: $draftURL)
                    .textFieldStyle(.roundedBorder)
                Text("{{variables}} from this project are resolved when the document is read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("HEADERS — for a document behind a token")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                KeyValueTableView(
                    items: $draftHeaders,
                    knownVariableNames: Set(
                        model.variables(forProject: projectID).map(\.key)
                    ),
                    showsDescription: false
                )
                .frame(height: 120)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(confirm) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 300)
    }
}
