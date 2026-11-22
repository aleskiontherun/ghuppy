import Foundation
import Testing
@testable import GhuppyCore

struct MarkdownTreeTests {
    private func rows(_ paths: String...) -> [String] {
        MarkdownTree.rows(for: paths).map { row in
            String(repeating: "  ", count: row.depth) + row.name + (row.kind == .folder ? "/" : "")
        }
    }

    @Test func eachFolderListsItsFilesThenItsFolders() {
        #expect(rows("b.md", "docs/z.md", "a.md", "app/guide.md", "docs/a.md") == [
            "a.md",
            "b.md",
            "app/",
            "  guide.md",
            "docs/",
            "  a.md",
            "  z.md",
        ])
    }

    @Test func aReadmeComesFirstInItsFolder() {
        #expect(rows("CHANGELOG.md", "AGENTS.md", "README.md", "docs/adr.md", "docs/readme.markdown") == [
            "README.md",
            "AGENTS.md",
            "CHANGELOG.md",
            "docs/",
            "  readme.markdown",
            "  adr.md",
        ])
    }

    @Test func aFolderHoldingOnlyAFolderSharesItsRow() {
        #expect(rows("app/docs/adr/one.md", "app/docs/adr/two.md", "app/README.md", "lib/Sources/Lib/Notes.md") == [
            "app/",
            "  README.md",
            "  docs/adr/",
            "    one.md",
            "    two.md",
            "lib/Sources/Lib/",
            "  Notes.md",
        ])
        let folder = MarkdownTree.rows(for: ["app/docs/adr/one.md"]).first
        #expect(folder?.path == "app/docs/adr")
        #expect(folder?.id == "app/docs/adr/")
        #expect(MarkdownTree.rows(for: ["app/docs/adr/one.md"]).last?.path == "app/docs/adr/one.md")
    }

    @Test func namesSortTheWayFinderSortsThem() {
        #expect(rows("note10.md", "Note2.md", "note1.md") == ["note1.md", "Note2.md", "note10.md"])
    }
}

struct MarkdownDefaultFileTests {
    @Test func theTopReadmeIsShownFirst() {
        #expect(MarkdownFiles.defaultFile(in: ["a/README.md", "AGENTS.md", "README.md"]) == "README.md")
        #expect(MarkdownFiles.defaultFile(in: ["Readme.markdown", "notes.md"]) == "Readme.markdown")
    }

    @Test func elseTheReadmeNearestTheTop() {
        #expect(MarkdownFiles.defaultFile(in: ["b/c/README.md", "z/README.md", "a/README.md", "notes.md"]) == "a/README.md")
    }

    @Test func noReadmeMeansNoFile() {
        #expect(MarkdownFiles.defaultFile(in: ["notes.md", "README.txt", "readme-old.md"]) == nil)
        #expect(MarkdownFiles.defaultFile(in: []) == nil)
    }
}

struct MarkdownListTests {
    @Test func listsWhatGitListsInsideACheckoutAndTheRestOutsideIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghuppy-markdown-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("app")
        let worktree = root.appendingPathComponent("app-wt")
        for file in [
            "notes.md", "group/plan.MD", "group/data.json", ".hidden/secret.md", "node_modules/pkg/README.md",
            "app/README.md", "app/docs/guide.markdown", "app/build/out.md", "app/.github/TEMPLATE.md",
            "app-wt/README.md",
        ] {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# \(file)".write(to: url, atomically: true, encoding: .utf8)
        }
        try "build/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        #expect(await Shell.run("git", ["init", "-q"], cwd: repo).ok)
        #expect(await Shell.run("git", ["init", "-q"], cwd: worktree).ok)

        // The second checkout stands for one the list leaves out, such as a linked worktree.
        let files = await MarkdownFiles.list(under: root, repositories: [repo])
        #expect(files == ["app/.github/TEMPLATE.md", "app/docs/guide.markdown", "app/README.md", "group/plan.MD", "notes.md"])
    }

    @Test func aRootThatIsACheckoutIsListedByGit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghuppy-markdown-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["README.md", "scratch/todo.md", "lib/README.md"] {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# \(file)".write(to: url, atomically: true, encoding: .utf8)
        }
        try "scratch/\nlib/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        #expect(await Shell.run("git", ["init", "-q"], cwd: root).ok)
        let lib = root.appendingPathComponent("lib")
        #expect(await Shell.run("git", ["init", "-q"], cwd: lib).ok)

        // A checkout the root ignores still shows its own files.
        let files = await MarkdownFiles.list(under: root, repositories: [root, lib])
        #expect(files == ["lib/README.md", "README.md"])
    }
}

struct MarkdownPageTests {
    @Test func rendersGitHubsMarkdown() {
        let html = MarkdownPage.render("""
        | a | b |
        |---|:-:|
        | 1 | 2 |

        - [x] done
        - [ ] to do

        ~~gone~~ https://example.com
        """)
        #expect(html.contains("<table>"))
        #expect(html.contains("<td align=\"center\">2</td>"))
        #expect(html.contains("<input type=\"checkbox\" checked=\"\" disabled=\"\" />"))
        #expect(html.contains("<del>gone</del>"))
        #expect(html.contains("<a href=\"https://example.com\">https://example.com</a>"))
    }

    @Test func escapesTextAndCodeButKeepsRawHTML() {
        let html = MarkdownPage.render("""
        a < b & c

        ```swift
        if a < b { print("<div>") }
        ```

        <img src="icon.png" width="128">
        """)
        #expect(html.contains("a &lt; b &amp; c"))
        #expect(html.contains("<pre lang=\"swift\"><code>if a &lt; b { print(&quot;&lt;div&gt;&quot;) }"))
        #expect(html.contains("<img src=\"icon.png\" width=\"128\">"))
    }

    @Test func filtersTheTagsGitHubFilters() {
        let html = MarkdownPage.render("<script>alert(1)</script>\n\n<iframe src=\"x\"></iframe>")
        #expect(!html.contains("<script"))
        #expect(!html.contains("<iframe"))
    }

    @Test func headingsGetGitHubsAnchors() {
        let html = MarkdownPage.withHeadingIDs(MarkdownPage.render("""
        # Ghuppy!
        ## What `Ghuppy!` deletes
        ## Tabs & windows
        ## Tabs & windows
        """))
        #expect(html.contains("<h1 id=\"ghuppy\">Ghuppy!</h1>"))
        #expect(html.contains("<h2 id=\"what-ghuppy-deletes\">What <code>Ghuppy!</code> deletes</h2>"))
        #expect(html.contains("<h2 id=\"tabs--windows\">"))
        #expect(html.contains("<h2 id=\"tabs--windows-1\">"))
    }

    @Test func frontMatterShowsAsItIs() {
        let (frontMatter, body) = MarkdownPage.splitFrontMatter("---\nname: x\r\ndescription: y\n---\n# Title\n")
        #expect(frontMatter == "name: x\ndescription: y")
        #expect(body == "# Title\n")
        let page = MarkdownPage.html(for: "---\nname: <x>\n---\n# Title", title: "a & b")
        #expect(page.contains("<pre class=\"front-matter\"><code>name: &lt;x&gt;</code></pre>"))
        #expect(page.contains("<title>a &amp; b</title>"))
        #expect(!page.contains("<hr"))
    }

    @Test func aRuleAloneIsNotFrontMatter() {
        #expect(MarkdownPage.splitFrontMatter("---\n# Title").0 == nil)
        #expect(MarkdownPage.splitFrontMatter("Text\n---\nname: x\n---").0 == nil)
    }
}
