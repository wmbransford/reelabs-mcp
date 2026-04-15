import Testing
import Foundation
@testable import ReelabsMCPLib

@Suite("parseHexColor")
struct ColorUtilsTests {

    @Test("6-digit hex with hash")
    func sixDigitWithHash() {
        let color = parseHexColor("#FF8800")
        let components = color.components!
        #expect(components.count == 4)
        #expect(abs(components[0] - 1.0) < 0.01)     // R = 0xFF
        #expect(abs(components[1] - 0.533) < 0.01)    // G = 0x88
        #expect(abs(components[2] - 0.0) < 0.01)      // B = 0x00
        #expect(abs(components[3] - 1.0) < 0.01)      // A = 1.0
    }

    @Test("8-digit hex with alpha")
    func eightDigitWithAlpha() {
        let color = parseHexColor("#FF000080")
        let components = color.components!
        #expect(abs(components[0] - 1.0) < 0.01)      // R = 0xFF
        #expect(abs(components[1] - 0.0) < 0.01)      // G = 0x00
        #expect(abs(components[2] - 0.0) < 0.01)      // B = 0x00
        #expect(abs(components[3] - 0.502) < 0.01)    // A = 0x80
    }

    @Test("6-digit hex without hash")
    func sixDigitNoHash() {
        let color = parseHexColor("00FF00")
        let components = color.components!
        #expect(abs(components[0] - 0.0) < 0.01)
        #expect(abs(components[1] - 1.0) < 0.01)
        #expect(abs(components[2] - 0.0) < 0.01)
        #expect(abs(components[3] - 1.0) < 0.01)
    }

    @Test("White color")
    func whiteColor() {
        let color = parseHexColor("#FFFFFF")
        let components = color.components!
        #expect(abs(components[0] - 1.0) < 0.01)
        #expect(abs(components[1] - 1.0) < 0.01)
        #expect(abs(components[2] - 1.0) < 0.01)
    }

    @Test("Black with half alpha")
    func blackHalfAlpha() {
        let color = parseHexColor("#00000080")
        let components = color.components!
        #expect(abs(components[0] - 0.0) < 0.01)
        #expect(abs(components[1] - 0.0) < 0.01)
        #expect(abs(components[2] - 0.0) < 0.01)
        #expect(abs(components[3] - 0.502) < 0.01)
    }
}
