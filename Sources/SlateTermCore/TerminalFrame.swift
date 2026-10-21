import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

/// Exact rendered pixels are separate from terminal.capture's plaintext projection.
public enum TerminalFrameLimits {
    public static let maximumPixelDimension = 8_192
    public static let maximumPixelBytes = 32 * 1_024 * 1_024
    public static let maximumPNGBytes = 512 * 1_024
    public static let maximumEncodedResultBytes = 900_000
    public static let maximumBase64Bytes = ((maximumPNGBytes + 2) / 3) * 4
    public static let timeoutMilliseconds = 2_000

    public static func unavailable(_ reason: String) -> RPCFailure {
        RPCFailure(code: -32022, message: "Terminal frame unavailable: \(reason)",
                   data: .object(["availability": .string(reason)]))
    }
}

/// Frame capture intentionally has no focus/context defaults: every caller must
/// name the same pane, terminal lifetime and app epoch it inspected.
public struct TerminalFrameRequest: Sendable {
    public let pane: PaneID
    public let sessionID: String
    public let appInstanceID: String
    public init(_ params: [String: JSONValue]) throws {
        guard Set(params.keys) == ["pane", "sessionId", "expectedInstanceId"],
              let rawPane = params["pane"]?.string, let pane = try? PaneID(parsing: rawPane),
              let session = params["sessionId"]?.string, !session.isEmpty, session.utf8.count <= 256,
              let instance = params["expectedInstanceId"]?.string, !instance.isEmpty else {
            throw RPCFailure(code: -32602, message: "terminal.frame requires explicit pane, sessionId and expectedInstanceId only")
        }
        self.pane = pane; sessionID = session; appInstanceID = instance
    }
}

/// Owned BGRA bytes copied after GPU completion, before reuse of the render target.
/// No borrowed IOSurface memory crosses a concurrency boundary.
public struct TerminalFramePixels: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public init(data: Data, width: Int, height: Int, bytesPerRow: Int) throws {
        guard (1...TerminalFrameLimits.maximumPixelDimension).contains(width),
              (1...TerminalFrameLimits.maximumPixelDimension).contains(height),
              bytesPerRow >= width * 4, bytesPerRow <= TerminalFrameLimits.maximumPixelBytes / height,
              data.count == bytesPerRow * height else {
            throw TerminalFrameLimits.unavailable("invalidPixelBuffer")
        }
        self.data = data; self.width = width; self.height = height; self.bytesPerRow = bytesPerRow
    }

    public func png() throws -> TerminalFramePNG {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: bytesPerRow, space: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw TerminalFrameLimits.unavailable("imageEncodingFailed")
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
            throw TerminalFrameLimits.unavailable("imageEncodingFailed")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TerminalFrameLimits.unavailable("imageEncodingFailed") }
        return try TerminalFramePNG(data: encoded as Data)
    }
}

public struct TerminalFramePNG: Sendable {
    public let data: Data
    public let contentHash: String
    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= TerminalFrameLimits.maximumPNGBytes else {
            throw TerminalFrameLimits.unavailable("pngTooLarge")
        }
        self.data = data
        contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
