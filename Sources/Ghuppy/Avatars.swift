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
        if let picture = login.flatMap({ images[$0] }) { return Image(nsImage: picture) }
        return Image(nsImage: Self.standIn(for: login)).renderingMode(.template)
    }

    func menuImage(for login: String?) -> NSImage? {
        login.flatMap { images[$0] } ?? Self.standIn(for: login)
    }

    private static let everyone = standIn(symbol: "person.2.fill")
    private static let someone = standIn(symbol: "person.crop.circle.fill")

    private static func standIn(for login: String?) -> NSImage {
        login == nil ? everyone : someone
    }

    /// A symbol fitted into the same square as the pictures, so it takes up
    /// as much room as the one it stands in for wherever it's shown. What's
    /// fitted is the symbol's drawing, not the margin around it.
    private static func standIn(symbol name: String) -> NSImage {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 4, weight: .regular))
        else { return NSImage(size: NSSize(width: size, height: size)) }
        let drawn = drawnBounds(of: symbol)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let scale = min(rect.width / drawn.width, rect.height / drawn.height)
            let fitted = NSSize(width: drawn.width * scale, height: drawn.height * scale)
            symbol.draw(in: NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                                   width: fitted.width, height: fitted.height),
                        from: drawn, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The part of an image that isn't transparent, in its own coordinates.
    private static func drawnBounds(of image: NSImage) -> NSRect {
        let whole = NSRect(origin: .zero, size: image.size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width.rounded(.up)),
                                         pixelsHigh: Int(image.size.height.rounded(.up)), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return whole }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: whole)
        NSGraphicsContext.restoreGraphicsState()
        var (minX, minY, maxX, maxY) = (rep.pixelsWide, rep.pixelsHigh, -1, -1)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0 {
                (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
            }
        }
        guard maxX >= minX else { return whole }
        // The bitmap's rows run top down, the image's coordinates bottom up.
        return NSRect(x: CGFloat(minX), y: CGFloat(rep.pixelsHigh - 1 - maxY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
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
