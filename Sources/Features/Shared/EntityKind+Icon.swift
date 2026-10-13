import SwiftUI

/// Maps each category to its custom Baby Buddy glyph asset (extracted from the web app's
/// Fontello icon font). These are template images, so they tint with the accent color.
extension EntityKind {
    /// Asset-catalog name of the custom glyph, e.g. `glyph_feeding`.
    var assetName: String { "glyph_\(rawValue)" }

    /// Whether the asset catalog has a custom glyph for this kind. The activity kinds have none (each
    /// type brings its own icon) and use their SF Symbol instead.
    var hasGlyph: Bool {
        switch self {
        case .activityType, .activity: return false
        default: return true
        }
    }

    /// The category's icon as a tintable SwiftUI `Image`.
    var iconImage: Image {
        (hasGlyph ? Image(assetName) : Image(systemName: systemImage)).renderingMode(.template)
    }

    /// Size-constrained icon view. Required because the custom glyphs have large intrinsic
    /// sizes and (unlike SF Symbols) don't scale to the surrounding font automatically.
    ///
    /// Marked decorative for VoiceOver: every place a glyph appears it sits beside a text label
    /// that already names the record kind, so an unlabeled "image" here would be redundant noise.
    func icon(_ size: CGFloat = 18) -> some View {
        iconImage.resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension ActivityIcon {
    /// The icon at `size` points, decorative for VoiceOver like ``EntityKind/icon(_:)``. A glyph or
    /// symbol takes the foreground style; an emoji keeps its own colours.
    @ViewBuilder func view(_ size: CGFloat = 18) -> some View {
        switch self {
        case .emoji(let emoji):
            Text(emoji).font(.system(size: size)).accessibilityHidden(true)
        case .glyph(let kind):
            kind.icon(size)
        case .symbol(let name):
            Image(systemName: name).renderingMode(.template)
                .resizable().scaledToFit().frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
