import Foundation
import Testing
@testable import TrifolaKit

@Suite("Design-strengthening render matrix")
struct RenderMatrixTests {
    @Test("manifest covers six screens, three widths, and both themes")
    func completeMatrix() {
        let entries = StrengthenRenderMatrix.entries(directory: "/tmp/strengthen")

        #expect(entries.count == 36)
        #expect(Set(entries.map(\.surface)) == Set(StrengthenRenderSurface.allCases))
        #expect(Set(entries.map(\.width)) == Set([1_280, 1_680, 2_560]))
        #expect(Set(entries.map(\.theme)) == Set(StrengthenRenderTheme.allCases))
        #expect(Set(entries.map(\.outputPath)).count == entries.count)
        #expect(entries.first?.outputPath
            == "/tmp/strengthen/layout-1280-dark.png")
        #expect(entries.last?.outputPath
            == "/tmp/strengthen/spend-2560-light.png")
    }
}
