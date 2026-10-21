import Foundation

/// Explicit mobile/native interactions never inherit a focused terminal target.
public struct TerminalInteractionRequest: Sendable {
    public enum Action: String, Sendable { case scroll, pointer, selection }
    public enum PointerAction: String, Sendable { case move, click, drag }
    public enum Modifier: String, CaseIterable, Sendable { case shift, control, alt, `super` }
    public struct Point: Sendable, Equatable {
        public let x: Double
        public let y: Double
        init(_ value: JSONValue?, geometry: Geometry) throws {
            guard let value = value?.object, Set(value.keys) == ["x", "y"],
                  let x = number(value["x"]), let y = number(value["y"]),
                  x >= 0, x < geometry.pointWidth, y >= 0, y < geometry.pointHeight else {
                throw invalid("point must be inside the guarded geometry")
            }
            self.x = x; self.y = y
        }
    }
    public struct Geometry: Sendable, Equatable {
        public let pointWidth: Double
        public let pointHeight: Double
        public let pixelWidth: Int
        public let pixelHeight: Int
        init(_ value: JSONValue?) throws {
            guard let value = value?.object, Set(value.keys) == ["pointWidth", "pointHeight", "pixelWidth", "pixelHeight"],
                  let width = number(value["pointWidth"]), let height = number(value["pointHeight"]),
                  width > 0, width <= 8192, height > 0, height <= 8192,
                  case .integer(let pixelsX) = value["pixelWidth"], case .integer(let pixelsY) = value["pixelHeight"],
                  (1...8192).contains(pixelsX), (1...8192).contains(pixelsY) else {
                throw invalid("geometry requires bounded positive point and integer pixel dimensions")
            }
            pointWidth = width; pointHeight = height; pixelWidth = pixelsX; pixelHeight = pixelsY
        }
        public func validate(pointWidth: Double, pointHeight: Double, pixelWidth: Int, pixelHeight: Int) throws {
            guard self.pointWidth == pointWidth, self.pointHeight == pointHeight,
                  self.pixelWidth == pixelWidth, self.pixelHeight == pixelHeight else {
                throw TerminalInteractionRequest.unavailable("geometryChanged")
            }
        }
    }
    public static let maximumSelectionBytes = 128 * 1024
    public let action: Action
    public let target: TerminalFrameRequest
    public let geometry: Geometry?
    public let point: Point?
    public let to: Point?
    public let pointerAction: PointerAction?
    public let modifiers: [Modifier]
    public let deltaX: Double
    public let deltaY: Double

    public init(action: Action, params: [String: JSONValue]) throws {
        self.action = action
        let targetFields: Set<String> = ["pane", "sessionId", "expectedInstanceId"]
        target = try TerminalFrameRequest(params.filter { targetFields.contains($0.key) })
        let required = action == .selection ? targetFields : targetFields.union(["geometry", "point"])
            .union(action == .scroll ? ["deltaX", "deltaY"] : ["action"])
        let allowed = action == .pointer ? required.union(["modifiers", "to"]) : required
        guard required.isSubset(of: Set(params.keys)), Set(params.keys).isSubset(of: allowed) else {
            throw Self.invalid("missing or unsupported terminal interaction parameter")
        }
        if action == .selection {
            geometry = nil; point = nil; to = nil; pointerAction = nil; modifiers = []; deltaX = 0; deltaY = 0
            return
        }
        let geometry = try Geometry(params["geometry"])
        self.geometry = geometry; point = try Point(params["point"], geometry: geometry)
        if action == .scroll {
            guard let x = Self.number(params["deltaX"]), let y = Self.number(params["deltaY"]),
                  abs(x) <= 100, abs(y) <= 100, x != 0 || y != 0 else {
                throw Self.invalid("wheel deltas must be finite in -100...100 and not both zero")
            }
            deltaX = x; deltaY = y; to = nil; pointerAction = nil; modifiers = []
        } else {
            guard let raw = params["action"]?.string, let pointerAction = PointerAction(rawValue: raw),
                  (pointerAction == .drag) == (params["to"] != nil) else {
                throw Self.invalid("pointer action must be move, click or drag; only drag requires to")
            }
            self.pointerAction = pointerAction
            to = try params["to"].map { try Point($0, geometry: geometry) }
            let values: [JSONValue]
            if let value = params["modifiers"] {
                guard let list = value.array else { throw Self.invalid("modifiers must be an array") }
                values = list
            } else { values = [] }
            let parsed = values.compactMap { $0.string.flatMap(Modifier.init(rawValue:)) }
            guard parsed.count == values.count, Set(parsed).count == parsed.count else {
                throw Self.invalid("modifiers must be unique shift, control, alt or super values")
            }
            modifiers = parsed; deltaX = 0; deltaY = 0
        }
    }

    /// One synchronous gesture owns its left-button lifetime. A failed move still
    /// releases the button; the transport never exposes a pending button-down.
    public func performPointer(move: (Point) throws -> Void, button: (Bool) -> Void, finish: () -> Void = {}) throws {
        guard action == .pointer, let point, let pointerAction else { throw Self.invalid("not a pointer request") }
        defer { finish() }
        try move(point)
        guard pointerAction != .move else { return }
        button(true)
        defer { button(false) }
        if let to { try move(to) }
    }

    /// Ghostty ignores unchanged coordinates before updating mouse modifiers.
    /// Reset outside the viewport before positioning to prevent physical Shift/
    /// Control at the same point from altering a modifier-free remote wheel.
    public func performScroll(prepare: () -> Void, move: (Point) -> Void,
                              scroll: (Double, Double) -> Void, finish: () -> Void) throws {
        guard action == .scroll, let point else { throw Self.invalid("not a scroll request") }
        prepare()
        defer { finish() }
        move(point)
        scroll(deltaX, deltaY)
    }

    public func result(_ fields: [String: JSONValue]) -> JSONValue {
        .object(["paneId": .string(target.pane.description), "sessionId": .string(target.sessionID),
                 "appInstanceId": .string(target.appInstanceID)].merging(fields) { _, new in new })
    }
    public static func selectionResult(_ text: String?) throws -> [String: JSONValue] {
        guard text?.utf8.count ?? 0 <= maximumSelectionBytes else { throw unavailable("selectionTooLarge") }
        return ["hasSelection": .bool(text != nil), "text": .string(text ?? "")]
    }
    public static func unavailable(_ reason: String) -> RPCFailure {
        RPCFailure(code: -32022, message: "Terminal interaction unavailable: \(reason)", data: .object(["availability": .string(reason)]))
    }
    private static func invalid(_ reason: String) -> RPCFailure { RPCFailure(code: -32602, message: reason) }
    private static func number(_ value: JSONValue?) -> Double? {
        let number: Double
        switch value { case .integer(let value): number = Double(value); case .number(let value): number = value; default: return nil }
        return number.isFinite ? number : nil
    }
}
