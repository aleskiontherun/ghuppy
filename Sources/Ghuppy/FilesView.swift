import AppKit
import GhuppyCore
import SwiftUI

/// The tab's Markdown files: every folder holding one down the side, each
/// closed until it's opened, and the file chosen, or else the README, beside
/// them.
struct FilesView: View {
    @Environment(Workspace.self) private var model
    @AppStorage("filesPaneWidth") private var paneWidth = 260.0

    /// The widths the side pane can take beside the file, which always
    /// keeps enough room to read.
    static func widths(sharing available: Double) -> ClosedRange<Double> {
        let narrowest = 160.0
        return narrowest...max(narrowest, available - 320)
    }

    var body: some View {
        Group {
            if let files = model.markdownFiles, files.isEmpty {
                ContentUnavailableView("No Markdown files", systemImage: "doc.text",
                                       description: Text("No Markdown files were found under this folder."))
            } else if model.markdownFiles == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    let widths = Self.widths(sharing: proxy.size.width)
                    HStack(spacing: 0) {
                        FileList()
                            .frame(width: paneWidth.clamped(to: widths))
                        ResizeHandle(length: $paneWidth, range: widths, axis: .horizontal)
                        FileDocument()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        // On coming on screen: switching to the Files view, or to the tab.
        .task { model.listFiles() }
    }
}

/// The side pane: each folder's files under it, indented as deep as it
/// lies. Clicking a folder opens it, or closes it again.
private struct FileList: View {
    @Environment(Workspace.self) private var model

    var body: some View {
        let selection = Binding<String?>(
            get: { model.shownFile },
            set: { if let path = $0 { model.chosenFile = path } }
        )
        ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(model.visibleMarkdownRows) { row in
                    FileRow(row: row)
                        .tag(Optional(row.id))
                        .selectionDisabled(row.kind == .folder)
                        .id(row.id)
                }
            }
            .listStyle(.sidebar)
            .onAppear {
                if let shown = model.shownFile { proxy.scrollTo(shown, anchor: .center) }
            }
        }
    }
}

private struct FileRow: View {
    @Environment(Workspace.self) private var model
    let row: MarkdownTree.Row

    private var collapsed: Bool { !model.expandedFolders.contains(row.path) }

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) {
            if collapsed {
                model.expandedFolders.insert(row.path)
            } else {
                model.expandedFolders.remove(row.path)
            }
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            // A column of its own, which files leave empty, so a folder's
            // icon lines up with its siblings'.
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 12)
                .opacity(row.kind == .folder ? 1 : 0)
            Label {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: row.kind == .folder ? "folder" : "doc.text")
            }
            .foregroundStyle(row.kind == .folder ? .secondary : .primary)
        }
        .padding(.leading, Double(row.depth) * 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // On a folder alone: on a file it would take the click the list
        // selects it by.
        .gesture(TapGesture().onEnded(toggle), including: row.kind == .folder ? .all : .subviews)
        .accessibilityAddTraits(row.kind == .folder ? .isButton : [])
        .accessibilityValue(row.kind == .folder ? (collapsed ? "Collapsed" : "Expanded") : "")
        .contextMenu {
            if let url = model.root?.appending(path: row.path) {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
                if row.kind == .file {
                    Button("Open in Default App") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

/// The file shown, under a bar naming it.
private struct FileDocument: View {
    @Environment(Workspace.self) private var model

    var body: some View {
        if let root = model.root, let path = model.shownFile {
            VStack(spacing: 0) {
                header(root.appending(path: path), path: path)
                Divider()
                MarkdownWebView(root: root, path: path, revision: model.shownFileRevision) { chosen in
                    model.chosenFile = chosen
                }
            }
        } else {
            ContentUnavailableView("No file chosen", systemImage: "doc.text",
                                   description: Text("Choose a file on the left to read it."))
        }
    }

    private func header(_ url: URL, path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(path)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .tooltip("Reveal in Finder")
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open in Default App", systemImage: "arrow.up.forward.app")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .tooltip("Open in default app")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 32)
    }
}
