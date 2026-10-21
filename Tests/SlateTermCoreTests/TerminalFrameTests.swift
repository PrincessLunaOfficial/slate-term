import Foundation
import CoreGraphics
import ImageIO
import Testing
import SlateTermTestSupport
@testable import SlateTermCore

@Test func terminalFrameIsPublicReadWithExplicitLifetimeGuards() throws {
    let method = try #require(AutomationMethod(rawValue: "terminal.frame"))
    #expect(method.family == .terminal && method.admission == .read)
    let contract = try #require(AutomationCatalog.methods[method])
    let valid: [String: JSONValue] = ["pane": .string("p7"), "sessionId": .string("session"), "expectedInstanceId": .string("app")]
    #expect(schemaAccepts(contract.input, .object(valid)))
    for missing in valid.keys {
        var input = valid
        input.removeValue(forKey: missing)
        #expect(!schemaAccepts(contract.input, .object(input)))
    }
    for extra in ["tab", "scope", "contextPane", "expectedAnchorSessionId", "expectedLayoutRevision"] {
        #expect(!schemaAccepts(contract.input, .object(valid.merging([extra: .string("foreign")]) { _, b in b })))
    }
    let defaults = AutomationDefaults(pane: PaneID(9), tab: TabID(9), scope: "tab")
    #expect(method.resolving([:], defaults: defaults).isEmpty)
    #expect(method.resolving(valid, defaults: defaults) == valid)
    #expect(contract.semantics["freshness"] == .string("renderedForRequest"))
    #expect(contract.semantics["changesFocusOrGeometry"] == .bool(false))
}

@Test func terminalFrameRequestRejectsIncompleteIdentityAndUnknownFields() throws {
    let valid: [String: JSONValue] = ["pane": .string("p7"), "sessionId": .string("s"), "expectedInstanceId": .string("epoch")]
    let method = try #require(AutomationMethod(rawValue: "terminal.frame"))
    let schema = try #require(AutomationCatalog.methods[method]).input
    var samples = [valid]
    for key in valid.keys {
        var sample = valid; sample.removeValue(forKey: key); samples.append(sample)
        sample = valid; sample[key] = .string(""); samples.append(sample)
    }
    samples.append(valid.merging(["sessionId": .string(String(repeating: "x", count: 257))]) { _, b in b })
    samples.append(valid.merging(["scope": .string("global")]) { _, b in b })
    for sample in samples {
        #expect(schemaAccepts(schema, .object(sample)) == ((try? TerminalFrameRequest(sample)) != nil))
    }
}

@Test func terminalFrameOwnedPixelsEncodeExactBGRAAndRejectMalformedBuffers() throws {
    // Two opaque pixels: red, green, followed by row padding. The native image
    // is encoded at its original resolution and color space, never reflowed.
    let bytes = Data([0, 0, 255, 255, 0, 255, 0, 255, 0, 0, 0, 0])
    let pixels = try TerminalFramePixels(data: bytes, width: 2, height: 1, bytesPerRow: 12)
    let png = try pixels.png()
    #expect(png.data.prefix(8) == Data([137,80,78,71,13,10,26,10]))
    let source = try #require(CGImageSourceCreateWithData(png.data as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decoded.width == 2 && decoded.height == 1)
    #expect(decoded.colorSpace?.name == CGColorSpace.displayP3)
    var roundTrip = [UInt8](repeating: 0, count: 8)
    try roundTrip.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(data: buffer.baseAddress, width: 2, height: 1,
            bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 2, height: 1))
    }
    #expect(Data(roundTrip) == bytes.prefix(8))
    #expect(png.contentHash.count == 64)
    #expect(try pixels.png().contentHash == png.contentHash)
    #expect(png.data.base64EncodedString().utf8.count < 1_048_576)
    for (width, height, stride, data) in [(0, 1, 12, bytes), (2, 1, 4, bytes), (2, 2, 12, bytes),
                                          (8_193, 1, 32_772, Data()), (1, Int.max, 4, Data())] {
        #expect(throws: RPCFailure.self) { try TerminalFramePixels(data: data, width: width, height: height, bytesPerRow: stride) }
    }
    #expect(throws: RPCFailure.self) { try TerminalFramePNG(data: Data(count: TerminalFrameLimits.maximumPNGBytes + 1)) }
}
