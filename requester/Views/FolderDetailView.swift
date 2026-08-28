import SwiftUI

/// Shown when a folder rather than a project or request is selected: what is in
/// it, and the two things worth doing from here.
///
/// Deliberately thin. A folder holds no settings of its own -- variables,
/// global headers, and the API document all belong to the project -- so this
/// says where you are and gets out of the way.
struct FolderDetailView: View {
    let model: AppModel
    let path: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(path.last ?? "", systemImage: "folder.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .labelStyle(.titleAndIcon)

                // The full path, so two folders with the same name are telling
                // apart at a glance.
                if path.count > 1 {
                    Text(path.dropLast().joined(separator: " ▸ "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    Task { await model.createRequest(projectID: model.projectID, folder: path) }
                } label: {
                    Label("New Request", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await model.createFolder(in: path) }
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    /// Counts what is directly inside and what is nested, since "3 requests" on
    /// a folder whose requests all sit one level down would be a lie.
    private var summary: String {
        let node = FolderTree.node(
            at: path,
            requests: model.requestsByProject[model.projectID] ?? [],
            declared: model.project?.folders ?? []
        )
        let direct = node.requests.count
        let nested = node.children.count

        var parts: [String] = []
        parts.append(direct == 1 ? "1 request" : "\(direct) requests")
        if nested > 0 { parts.append(nested == 1 ? "1 folder" : "\(nested) folders") }
        return parts.joined(separator: " · ")
    }
}
