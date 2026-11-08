import AppKit
import GhuppyCore
import SwiftUI

struct RepoCard: View {
    @Environment(Workspace.self) private var model
    let repo: RepoState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(12)
            if repo.github != nil {
                Divider()
                pullRequests
                    .padding(.vertical, 6)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repo.git.path])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(repo.git.path.path, forType: .string)
            }
            if let github = repo.github {
                Button("Open on GitHub") { NSWorkspace.shared.open(github.url) }
            }
            Divider()
            Button(pinned ? "Unpin" : "Pin to Top", action: togglePin)
        }
    }

    private var pinned: Bool { Pins.shared.isPinned(repo.git.path) }

    private func togglePin() {
        withAnimation(.snappy) { Pins.shared.toggle(repo.git.path) }
    }

    private var pinButton: some View {
        Button(action: togglePin) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .rotationEffect(.degrees(45))
                .foregroundStyle(pinned ? Color.logoOrange : Color.secondary)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.hoverHighlight)
        .tooltip(pinned ? "Unpin" : "Pin to the top")
    }

    /// Not disabled while it turns, which would dim it, but while the
    /// repository is being cleaned up, when only the Ghuppy! icon turns.
    private var refreshButton: some View {
        Button {
            model.startRefresh(of: repo)
        } label: {
            Group {
                if repo.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.hoverHighlight)
        .disabled(repo.activity != nil || !model.canAct)
        .accessibilityLabel("Refresh")
        .tooltip("Refresh this repository")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(repo.name)
                        .font(.headline)
                    if let github = repo.github {
                        Link(destination: github.url) {
                            Label(github.slug, systemImage: "arrow.up.right.square")
                                .labelStyle(.titleAndIcon)
                                .font(.callout)
                        }
                        .tooltip(github.url.absoluteString)
                    } else {
                        Text("no GitHub remote")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
                branchLine
            }
            Spacer()
            if let activity = repo.activity {
                // The cleanup icon beside it is animating meanwhile.
                Text(activity).font(.callout).foregroundStyle(.secondary)
            } else if let result = repo.result {
                Text(result.text)
                    .font(.callout)
                    .foregroundStyle(result.isError ? Color.warmRed : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .tooltip(result.text)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            HStack(spacing: 4) {
                // Not disabled while it runs, which would dim the animation.
                Button {
                    if repo.activity == nil { model.startCleanup(of: repo) }
                } label: {
                    FishSpinner(animating: repo.activity != nil)
                        .controlSize(.small)
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.hoverHighlight)
                .accessibilityLabel("Ghuppy!")
                .tooltip(model.dryRun ? "Dry run this repository" : "Clean up this repository")
                refreshButton
                pinButton
            }
            // Level with the middle of the title beside them.
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
        }
    }

    private var branchLine: some View {
        HStack(spacing: 8) {
            let status = repo.status
            Label(status.branch ?? "detached HEAD", systemImage: "arrow.triangle.branch")
            if status.ahead > 0 { Text("↑\(status.ahead)").tooltip("\(status.ahead) commits to push") }
            if status.behind > 0 { Text("↓\(status.behind)").tooltip("\(status.behind) commits to pull") }
            if status.dirty {
                Text("modified").foregroundStyle(Color.logoOrange).tooltip("Uncommitted changes")
            }
            if let size = repo.size {
                Label(size.formatted(.byteCount(style: .file)), systemImage: "folder")
                    .tooltip("Size on disk")
            }
            if let counts = repo.refCounts {
                Text(counts.worktrees == 1 ? "1 worktree" : "\(counts.worktrees) worktrees")
                    .tooltip("Linked worktrees")
                Text("\(counts.localBranches) local").tooltip("Local branches")
                Text("\(counts.remoteBranches) remote").tooltip("Remote-tracking branches")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var pullRequests: some View {
        let open = PullRequests.filter(repo.pullRequests, author: model.authorFilter)
        let merged = PullRequests.filter(repo.mergedPullRequests, author: model.authorFilter)
        return VStack(alignment: .leading, spacing: 0) {
            // A failed reload keeps the list it couldn't replace on screen.
            if let error = repo.prError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Color.warmRed)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else if open.isEmpty {
                HStack(spacing: 6) {
                    if repo.prsLoaded {
                        Text(model.authorFilter.map { "No open pull requests by \($0)" } ?? "No open pull requests")
                    } else if model.rateLimitedUntil != nil {
                        Text("Waiting for GitHub's rate limit")
                    } else {
                        ProgressView().controlSize(.mini)
                        Text("Loading pull requests…")
                    }
                }
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            ForEach(open) { pr in
                PRRow(pr: pr)
            }
            ForEach(merged) { pr in
                PRRow(pr: pr)
            }
        }
    }
}
