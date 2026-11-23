import AppKit
import GhuppyCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A Markdown file under the working directory, rendered as a page. The page
/// and everything it refers to by a relative path, such as its images, come
/// from the working directory through a URL scheme of Ghuppy's own, which
/// serves nothing outside it. JavaScript is off.
///
/// A link to another Markdown file under the working directory opens it in
/// the view, through `open`; a link to a heading on the page scrolls to it;
/// a link to any other file shows it in Finder; and a web or mail link opens
/// in the browser or mail app. Nothing else the page asks for goes anywhere.
struct MarkdownWebView: NSViewRepresentable {
    let root: URL
    /// Relative to the root.
    let path: String
    /// Goes up when the file is to be read again.
    let revision: Int
    let open: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(context.coordinator.files, forURLScheme: MarkdownFileScheme.name)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsMagnification = true
        // Shown before the page draws, and past its ends: the page's own
        // background, in light and dark.
        view.underPageBackgroundColor = .textBackgroundColor
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.files.root = root
        coordinator.open = open
        let url = MarkdownFileScheme.url(for: root.appending(path: path))
        if coordinator.loaded != url {
            coordinator.loaded = url
            coordinator.revision = revision
            view.load(URLRequest(url: url))
        } else if coordinator.revision != revision {
            coordinator.revision = revision
            view.reload()
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let files = MarkdownFileScheme()
        var open: (String) -> Void = { _ in }
        var loaded: URL?
        var revision = 0

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else {
                decisionHandler(.cancel)
                return
            }
            guard action.navigationType == .linkActivated else {
                // Only what the view itself loads: the file shown, read for
                // the first time or again. Raw HTML in a file can still ask
                // for more, with a `<meta http-equiv="refresh">` or a
                // `<form>`, and gets nothing.
                decisionHandler(isLoaded(url) ? .allow : .cancel)
                return
            }
            // A heading on the page on screen.
            if isLoaded(url), url.fragment != nil {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            follow(url)
        }

        /// A link meant for a new window, as raw HTML's `target="_blank"` asks.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.navigationType == .linkActivated, let url = action.request.url { follow(url) }
            return nil
        }

        /// Whether `url` is the file shown, wherever on the page it points.
        private func isLoaded(_ url: URL) -> Bool {
            guard let loaded else { return false }
            return url.scheme == loaded.scheme && url.host == loaded.host && url.path == loaded.path
        }

        private func follow(_ url: URL) {
            if url.scheme == MarkdownFileScheme.name {
                guard let file = files.file(for: url) else { return }
                if MarkdownFiles.isMarkdown(file.path), let path = files.relativePath(of: file) {
                    open(path)
                } else if FileManager.default.fileExists(atPath: file.path) {
                    // Shown rather than opened, which for an app would launch it.
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            } else if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// Serves the files under the working directory to the page: a Markdown
/// file rendered, anything else as it is. A file outside the working
/// directory, or not there, fails to load.
@MainActor
final class MarkdownFileScheme: NSObject, WKURLSchemeHandler {
    static let name = "ghuppy-file"
    private static let host = "files"

    var root: URL?

    static func url(for file: URL) -> URL {
        var components = URLComponents()
        components.scheme = name
        components.host = host
        components.path = file.standardizedFileURL.path
        return components.url!
    }

    /// The file `url` stands for, if it lies under the root.
    func file(for url: URL) -> URL? {
        guard url.scheme == Self.name, url.host == Self.host else { return nil }
        let file = URL(fileURLWithPath: url.path).standardizedFileURL
        return relativePath(of: file) == nil ? nil : file
    }

    /// `file`'s path relative to the root, nil when it isn't under it, once
    /// symbolic links on the way are followed.
    func relativePath(of file: URL) -> String? {
        guard let root else { return nil }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = file(for: url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let data: Data
        let type: String
        if MarkdownFiles.isMarkdown(file.path) {
            let page: String
            if let contents = try? Data(contentsOf: file) {
                page = MarkdownPage.html(for: String(decoding: contents, as: UTF8.self), title: file.lastPathComponent)
            } else {
                page = MarkdownPage.html(for: "_\(file.lastPathComponent) can’t be read: it may have been moved or deleted._",
                                         title: file.lastPathComponent)
            }
            data = Data(page.utf8)
            type = "text/html"
        } else if let contents = try? Data(contentsOf: file) {
            data = contents
            type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count,
                                    textEncodingName: type == "text/html" ? "utf-8" : nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
