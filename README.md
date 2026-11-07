# Ghuppy

<img src="Resources/AppIcon.png" width="128" alt="">

A small macOS app for keeping a folder full of git checkouts tidy. Pick a
working directory, and Ghuppy lists every repository under it, with a link
to each one on GitHub and its pull requests underneath: the ones ready to
merge, then the other open ones, then the ones in the merge queue, then the
last 3 merged, the last merged first.

- **Cleanup** — `git fetch --prune`, then delete local branches whose work has
  actually landed and the worktrees left behind with them, then a
  fast-forward-only pull of the default branch, then reload the pull request
  list. Only the default branch is ever pulled: a checkout that stays on
  another branch, because that branch is kept, is left as it is. Cleanup shows
  how many commits the pull brought in, and Cleanup all shows the total. A
  fetch that loses a race with another git fetching the same repository (an
  IDE, say) is retried.
- **Cleanup all** (the triangle in the toolbar, or ⌘G) first rescans the
  working directory, so repositories added or deleted since the last look join
  or leave the list, then cleans them up, a few at a time: only the pinned ones
  while Pinned only is on, unless ⇧⌘G asks for every one.

⌘/ lists every action and shortcut, and how labels are decided. ⌘U opens the
author select. ⌘L shows or hides the log, and ⌘K clears it. ⌃C stops everything running in
every tab. A cleanup stopped this way deletes nothing more, and what it had
already deleted stays deleted.

The status bar at the bottom shows how much space the working directory takes
up on disk and how much is free on its volume, and each repository shows its
own size, then how many linked worktrees, local branches and remote-tracking
branches it has. All of it is measured again after every refresh and cleanup.
It also follows whatever else is writing to the disk: the free space is
re-read every second, and the sizes are measured again a few seconds after
anything under the working directory changes, and at most every few seconds
while it keeps changing, and the worktrees and branches counted again with them.
Cleanup logs the space it freed: the size of each worktree it removed.

Drag the divider above the log to resize it. The height is saved, and shared
by every tab.

**Refresh** (⌘R, or the button in the toolbar) brings the tab on screen up to
date without fetching: it rescans the working directory, reloads the
repositories' status and pull requests, and measures the disk again. The
button turns into a spinner for as long as anything is being reloaded, and
pressing it again starts over, cancelling the refresh under way. A tab also
refreshes when Ghuppy launches with it selected, and on coming back to it from
another tab or another app, once a minute has passed since its last refresh.

When GitHub's rate limit stops a request, Ghuppy stops sending any until the
limit lifts: until the quota resets if it ran out, and otherwise for a minute,
twice as long each time it happens again in a row, up to half an hour. The
status bar shows the time requests resume, and the pull requests on screen
stay as they were. Cleanup carries on meanwhile, and keeps any branch whose
pull request it can't check.

A pull request shows one label, the first of these that applies: **Merged**,
**Queued**, **Draft**, **Changes**, **Conflicts**, **Failed**, **Update**,
**Approve**, **Review**, **CI**, **Blocked**, **Ready**, **Approved**, **…**.
The icon beside it shows how its checks are doing either way.

Drafts are labelled **Draft**. A pull request that is ready to merge (out of
draft, not queued, GitHub allowing the merge, no conflicts, checks passing or
absent, no workflow waiting for approval, approved or needing no review) is
labelled **Ready**. While GitHub can't say whether it allows the merge or
whether a workflow is waiting, nothing is.

A pull request GitHub won't merge until its branch is brought up to date with
the base branch is labelled **Update**, and one with checks still going **CI**.
Once they have all finished, one with a failure among them is labelled
**Failed**. One with a workflow waiting for approval, as a first-time
contributor's is, is labelled **Approve**. One GitHub won't merge for a reason
its checks don't show, such as an unresolved conversation, is labelled
**Blocked**. One whose state isn't known yet, while GitHub is still working it
out, is labelled **…**.

A pull request in its base branch's merge queue shows its place in the queue
(**Queued #1** is next to merge, in dark yellow), in red once the queue finds it can't be
merged.

Pin a repository (the pin button, or right-click) to keep it at the top of
the list. Pins are saved, and shared by every tab that lists the repository.
Turn on the **pin button in the toolbar** (⌘P) to have Cleanup (⌘G) and Refresh
(⌘R) act on the pinned repositories alone, though every repository still loads
the first time. Cleanup All (⇧⌘G) and Refresh All (⇧⌘R) cover every repository
either way. Each tab remembers its own setting, across launches too.

The **Author** select narrows the pull requests on screen to one person's,
out of everyone with a pull request listed; every repository stays in the list.
It only changes what is shown: Cleanup all acts as before. Each tab remembers
its own choice, across launches too, until its working directory changes.

## What Cleanup deletes

A branch marked `[gone]` (its remote branch was deleted) is only a candidate:
that alone doesn't mean it was merged. For each candidate Ghuppy asks
GitHub (`gh pr list --head <branch>`):

| PR for the branch | Result |
| --- | --- |
| merged | deleted |
| open (e.g. a stacked PR) | kept |
| none, but its commits or an equal squashed patch are in the default branch | deleted |
| none, and not in the default branch | kept, reported for manual review |

The checked-out branch is a candidate even when it isn't `[gone]`, since a
merged PR doesn't always delete its remote branch. It is deleted when the
default branch holds an equal squashed patch, or holds its commits and its PR
is merged: a branch just cut from the default branch is in it too. A branch
with an open PR is kept.

If the branch to delete is the one checked out, Ghuppy switches the
checkout to the default branch, then deletes the branch, but only when there
are no local changes. The pull that follows fast-forwards the default branch
to `origin`.

Worktrees: stale registrations are pruned; a worktree on a deleted branch is
removed along with it; a detached worktree whose commit is already in the
default branch is removed. Nothing is ever removed with `--force`. A locked
worktree, or one with uncommitted work, is kept and named in the log, and so
is its branch.

Turn on **Dry run**, the flask in the toolbar (⇧⌘D), to see what Cleanup would do
without changing anything.

## Tabs

**+** next to the tabs (⌘T) opens a new tab for another working directory.
⌘W (or the × on hover) closes the current tab, and the window once it's the
last one; ⇧⌘[ and ⇧⌘] switch tabs. Drag a tab along the bar to move it. Open
tabs, in their order, and the selected one are restored on the next launch.

## Repository discovery

Every directory under the working directory that contains a `.git` is a
repository; the search doesn't go inside a repository. If the working
directory is itself a repository, paths it ignores are skipped. Linked
worktrees are left out of the list, because cleaning up their main checkout
handles them.

## Requirements

- macOS 14 or later
- `git` and the [GitHub CLI](https://cli.github.com) (`gh auth login`), in
  `/opt/homebrew/bin`, `/usr/local/bin` or `/usr/bin`

## Build

```bash
./scripts/build-app.sh            # builds build/Ghuppy.app
./scripts/build-app.sh --install  # and copies it to /Applications
```

The icon is a Liquid Glass icon, `Resources/AppIcon.icon`, made of SVG
layers; edit it in Icon Composer (bundled with Xcode). `build-app.sh` compiles
it with `actool`, so building needs Xcode rather than just the command line
tools. `Resources/AppIcon.png` is a rendered preview for this README.

The app is ad-hoc signed and not notarized, so it's meant to be built
locally. For development:

```bash
swift run Ghuppy
swift test
```

## Contributing

Pull requests are squash-merged, so a PR's title becomes the commit subject
on `main`, and CI checks it is a conventional commit subject:
`<type>[(scope)][!]: <description>`, with type one of `feat`, `fix`,
`refactor`, `docs`, `test`, `chore`, `perf`, `ci`, `build` or `revert`. CI
also runs `swift test`, builds the app with `build-app.sh` and lints the
scripts with ShellCheck; all of it has to pass before a PR can merge.

## License

MIT
