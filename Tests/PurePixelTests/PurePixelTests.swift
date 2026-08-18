import Testing
@testable import PurePixel

@Suite struct ImageTests {
    @Test func fillInitAndSubscript() {
        var image = Image(width: 4, height: 3, fill: .white)
        #expect(image.width == 4)
        #expect(image.height == 3)
        #expect(image.pixels.count == 12)

        image[2, 1] = RGBA(red: 1, green: 2, blue: 3, alpha: 4)
        #expect(image[2, 1] == RGBA(red: 1, green: 2, blue: 3, alpha: 4))
        #expect(image.pixel(atX: 4, y: 0) == nil)
        #expect(image.pixel(atX: -1, y: 0) == nil)
        #expect(image.pixel(atX: 3, y: 2) == .white)
    }
}

@Suite struct OperationTests {
    @Test func cropExtractsRegion() throws {
        var image = Image(width: 10, height: 8, fill: .black)
        image[3, 2] = .white
        let cropped = try image.cropped(to: Region(x: 3, y: 2, width: 4, height: 3))
        #expect(cropped.width == 4)
        #expect(cropped.height == 3)
        #expect(cropped[0, 0] == .white)
        #expect(cropped[1, 1] == .black)
    }

    @Test func cropRejectsOutOfBoundsRegion() {
        let image = Image(width: 10, height: 8)
        #expect(throws: ImageError.regionOutOfBounds) {
            _ = try image.cropped(to: Region(x: 5, y: 5, width: 6, height: 3))
        }
        #expect(throws: ImageError.regionOutOfBounds) {
            _ = try image.cropped(to: Region(x: -1, y: 0, width: 2, height: 2))
        }
    }

    @Test func nearestNeighborDoubling() throws {
        var image = Image(width: 2, height: 2)
        image[0, 0] = .white
        image[1, 0] = .black
        image[0, 1] = RGBA(red: 255, green: 0, blue: 0)
        image[1, 1] = RGBA(red: 0, green: 0, blue: 255)

        let resized = try image.resized(toWidth: 4, height: 4, method: .nearestNeighbor)
        #expect(resized[0, 0] == .white)
        #expect(resized[1, 1] == .white)
        #expect(resized[2, 0] == .black)
        #expect(resized[0, 3] == RGBA(red: 255, green: 0, blue: 0))
        #expect(resized[3, 3] == RGBA(red: 0, green: 0, blue: 255))
    }

    @Test func bilinearBlendsNeighbors() throws {
        var image = Image(width: 2, height: 1, fill: .black)
        image[1, 0] = .white

        let resized = try image.resized(toWidth: 4, height: 1, method: .bilinear)
        // Target pixel centers map to source x = -0.25, 0.25, 0.75, 1.25 (clamped).
        #expect(resized[0, 0] == .black)
        #expect(resized[1, 0] == RGBA(red: 64, green: 64, blue: 64))
        #expect(resized[2, 0] == RGBA(red: 191, green: 191, blue: 191))
        #expect(resized[3, 0] == .white)
    }

    @Test func scaledByFactor() throws {
        let image = Image(width: 100, height: 60, fill: .white)
        let scaled = try image.scaled(by: 0.5)
        #expect(scaled.width == 50)
        #expect(scaled.height == 30)
        #expect(scaled[10, 10] == .white)
    }

    @Test func resizeRejectsInvalidDimensions() {
        let image = Image(width: 2, height: 2)
        #expect(throws: ImageError.invalidDimensions) {
            _ = try image.resized(toWidth: 0, height: 2)
        }
        #expect(throws: ImageError.invalidDimensions) {
            _ = try image.scaled(by: -1)
        }
    }
}
