import SwiftUI

/// The app's accent colours, one for light and dark alike: the orange of the
/// logo, and mid-tones chosen to sit beside it and stay readable on both.
extension Color {
    /// Toolbar items that are off, and hints that needn't catch the eye.
    /// Between the system's secondary and tertiary label colours.
    static let muted = Color.primary.opacity(0.4)
    /// The middle of the logo's background gradient, as one flat colour.
    static let logoOrange = Color(red: 0.835, green: 0.435, blue: 0.192)
    static let warmRed = Color(red: 0.871, green: 0.353, blue: 0.310)
    static let softGreen = Color(red: 0.373, green: 0.651, blue: 0.353)
    static let softPurple = Color(red: 0.616, green: 0.471, blue: 0.800)
}
