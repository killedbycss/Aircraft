import XCTest
import SwiftUI
@testable import aircraft

final class FloatingShadowTests: XCTestCase {
    /// Тень видна снаружи фигуры, а внутри не закрашивает прозрачное содержимое.
    @MainActor
    func testShadowOutsideOnly() throws {
        let view = ZStack {
            Color.white
            Color.clear
                .frame(width: 100, height: 60)
                .floatingShadow(RoundedRectangle(cornerRadius: 10), color: .black.opacity(0.5), radius: 8, y: 4)
        }
        .frame(width: 200, height: 160)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        func brightness(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1 }
        XCTAssertGreaterThan(brightness(100, 80), 0.98, "Внутри фигуры тени нет")
        XCTAssertLessThan(brightness(100, 115), 0.97, "Под фигурой видна тень")
        XCTAssertGreaterThan(brightness(5, 5), 0.98, "Далеко от фигуры тени нет")
    }
}
