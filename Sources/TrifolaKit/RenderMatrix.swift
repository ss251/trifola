import Foundation

/// The public visual-regression contract for the final design-strengthening
/// pass. Keeping names and dimensions in the pure Kit target lets tests pin the
/// matrix without importing AppKit or constructing a SwiftUI renderer.
public enum StrengthenRenderSurface: String, CaseIterable, Sendable {
    case layout
    case sessions
    case fleet
    case audit
    case ledger
    case spend
}

public enum StrengthenRenderTheme: String, CaseIterable, Sendable {
    case dark
    case light
}

public struct StrengthenRenderEntry: Sendable, Equatable {
    public let surface: StrengthenRenderSurface
    public let width: Int
    public let theme: StrengthenRenderTheme
    public let outputPath: String

    public init(
        surface: StrengthenRenderSurface,
        width: Int,
        theme: StrengthenRenderTheme,
        outputPath: String
    ) {
        self.surface = surface
        self.width = width
        self.theme = theme
        self.outputPath = outputPath
    }
}

public enum StrengthenRenderMatrix {
    public static let widths = [1_280, 1_680, 2_560]
    public static let viewportHeight = 900

    public static func entries(directory: String) -> [StrengthenRenderEntry] {
        StrengthenRenderSurface.allCases.flatMap { surface in
            widths.flatMap { width in
                StrengthenRenderTheme.allCases.map { theme in
                    let filename = "\(surface.rawValue)-\(width)-\(theme.rawValue).png"
                    let path = URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent(filename)
                        .path
                    return StrengthenRenderEntry(
                        surface: surface,
                        width: width,
                        theme: theme,
                        outputPath: path)
                }
            }
        }
    }
}
