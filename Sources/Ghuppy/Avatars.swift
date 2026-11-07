import AppKit
import SwiftUI

/// GitHub pictures by login, each loaded once and shared by every view that
/// shows it. A picture that fails to load is tried again the next time it's
/// asked for.
@MainActor @Observable
final class Avatars {
    static let shared = Avatars()

    private static let size = 20.0

    private var images: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    func load(_ logins: [String]) {
        for login in logins where images[login] == nil && loading.insert(login).inserted {
            Task {
                images[login] = await Self.fetch(login)
                loading.remove(login)
            }
        }
    }

    /// The picture, or a stand-in for everyone or until it loads.
    func image(for login: String?) -> Image {
        login.flatMap { images[$0] }.map(Image.init(nsImage:)) ?? Image(systemName: Self.standIn(for: login))
    }

    func menuImage(for login: String?) -> NSImage? {
        login.flatMap { images[$0] }
            ?? NSImage(systemSymbolName: Self.standIn(for: login), accessibilityDescription: nil)
    }

    private static func standIn(for login: String?) -> String {
        login == nil ? "person.2.fill" : "person.crop.circle.fill"
    }

    /// The picture, already round and at its final size: a menu shows an
    /// image as it is, ignoring modifiers.
    private static func fetch(_ login: String) async -> NSImage? {
        guard let path = login.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://github.com/\(path).png?size=64"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let picture = NSImage(data: data)
        else { return nil }

        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            picture.draw(in: rect)
            return true
        }
    }
}
