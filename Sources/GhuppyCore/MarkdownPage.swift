import cmark_gfm
import cmark_gfm_extensions
import Foundation

/// A Markdown file as a page for the Files view: GitHub's flavour of
/// Markdown, rendered by GitHub's own parser, in a style of its own.
public enum MarkdownPage {
    /// The page for `markdown`, a file's contents. Raw HTML in it is kept,
    /// as a README's images and badges need, except the tags GitHub filters
    /// out too, such as `script` and `iframe`; the page is meant to be shown
    /// with JavaScript off all the same. A YAML front matter block shows as
    /// it is, above the rest, rather than as a rule and a paragraph.
    public static func html(for markdown: String, title: String) -> String {
        let (frontMatter, body) = splitFrontMatter(markdown)
        var content = withHeadingIDs(render(body))
        if let frontMatter {
            content = "<pre class=\"front-matter\"><code>\(escape(frontMatter))</code></pre>\n" + content
        }
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        <style>\(style)</style>
        </head>
        <body>
        <main>
        \(content)
        </main>
        </body>
        </html>
        """
    }

    /// The HTML cmark-gfm makes of `markdown`, with GitHub's extensions.
    static func render(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES | CMARK_OPT_GITHUB_PRE_LANG
            | CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE | CMARK_OPT_VALIDATE_UTF8
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tagfilter", "tasklist"] {
            if let extensionPointer = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, extensionPointer)
            }
        }
        var bytes = Array(markdown.utf8)
        bytes.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                cmark_parser_feed(parser, $0, buffer.count)
            }
        }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else {
            return ""
        }
        defer { free(html) }
        return String(cString: html)
    }

    /// The front matter, without its fences, and the rest of the file. A
    /// file has front matter when it opens with a line of `---` and another
    /// such line, or `...`, closes it.
    static func splitFrontMatter(_ markdown: String) -> (String?, String) {
        // A Windows line ending, "\r\n", is one Character, and a newline.
        var lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else {
            return (nil, markdown)
        }
        let frontMatter = lines[1..<end].joined(separator: "\n")
        lines.removeSubrange(0...end)
        return (frontMatter, lines.joined(separator: "\n"))
    }

    /// Gives each heading the id GitHub would, so links to `#a-heading`
    /// within the page land on it without any JavaScript.
    static func withHeadingIDs(_ html: String) -> String {
        let pattern = /<h([1-6])>(.*?)<\/h\1>/.dotMatchesNewlines()
        var used: [String: Int] = [:]
        return html.replacing(pattern) { match in
            let base = slug(String(match.output.2))
            let count = used[base, default: 0]
            used[base] = count + 1
            let id = count == 0 ? base : "\(base)-\(count)"
            return "<h\(match.output.1) id=\"\(escape(id))\">\(match.output.2)</h\(match.output.1)>"
        }
    }

    /// GitHub's anchor for a heading: its text in lower case, without
    /// punctuation, spaces made hyphens.
    static func slug(_ headingHTML: String) -> String {
        let text = unescape(headingHTML.replacing(/<[^>]*>/, with: ""))
        return String(text.lowercased().compactMap { character -> Character? in
            if character == " " { return "-" }
            if character == "-" || character == "_" || character.isLetter || character.isNumber {
                return character
            }
            return nil
        })
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// GitHub's look in the system's type, following light and dark.
    private static let style = """
    :root {
      color-scheme: light dark;
      --text: #1f2328; --muted: #59636e; --border: #d1d9e0; --rule: #d1d9e0b3;
      --subtle: #f6f8fa; --code: #818b981f; --link: #0969da; --background: #ffffff;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --text: #e6e6e6; --muted: #9a9a9a; --border: #444444; --rule: #3d3d3d;
        --subtle: #262626; --code: #ffffff1a; --link: #4c9bff; --background: #1e1e1e;
      }
    }
    html { background: var(--background); }
    body {
      margin: 0; color: var(--text); background: var(--background);
      font: 15px/1.6 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
      -webkit-font-smoothing: antialiased; overflow-wrap: break-word;
    }
    main { max-width: 880px; margin: 0 auto; padding: 28px 40px 72px; }
    main > :first-child { margin-top: 0 !important; }
    main > :last-child { margin-bottom: 0 !important; }
    p, blockquote, ul, ol, dl, table, pre, details { margin: 0 0 16px; }
    h1, h2, h3, h4, h5, h6 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
    h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--rule); }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--rule); }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1em; }
    h5 { font-size: .875em; }
    h6 { font-size: .85em; color: var(--muted); }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    strong { font-weight: 600; }
    hr { height: 4px; margin: 24px 0; border: 0; background: var(--border); border-radius: 2px; }
    ul, ol { padding-left: 2em; }
    li + li, li > ul, li > ol { margin-top: .25em; }
    li > p { margin-top: 16px; }
    li > ul, li > ol { margin-bottom: 0; }
    ul:has(> li > input[type=checkbox]) { list-style: none; padding-left: 1.4em; }
    li > input[type=checkbox] { margin: 0 .45em 0 -1.4em; vertical-align: middle; }
    blockquote { margin-left: 0; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
    code, pre, kbd { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 85%; }
    code { padding: .2em .4em; border-radius: 6px; background: var(--code); }
    pre {
      padding: 14px 16px; overflow: auto; line-height: 1.45;
      background: var(--subtle); border-radius: 8px;
    }
    pre code { padding: 0; font-size: 100%; background: none; border-radius: 0; }
    pre.front-matter { color: var(--muted); border: 1px solid var(--border); background: none; }
    kbd {
      padding: 2px 5px; border: 1px solid var(--border); border-bottom-width: 2px;
      border-radius: 5px; background: var(--subtle);
    }
    table { display: block; width: max-content; max-width: 100%; overflow: auto; border-collapse: collapse; }
    th, td { padding: 6px 13px; border: 1px solid var(--border); }
    th { font-weight: 600; }
    tr:nth-child(2n) { background: var(--subtle); }
    img { max-width: 100%; box-sizing: border-box; }
    details summary { cursor: pointer; }
    section.footnotes { font-size: 12px; color: var(--muted); border-top: 1px solid var(--rule); margin-top: 32px; }
    section.footnotes ol { padding-top: 16px; }
    """
}
