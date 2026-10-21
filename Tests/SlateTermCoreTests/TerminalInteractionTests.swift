import Foundation
import Testing
import SlateTermTestSupport
@testable import SlateTermCore

private let interactionIdentity: [String: JSONValue] = ["pane": .string("p7"), "sessionId": .string("session"), "expectedInstanceId": .string("app")]
private let interactionGeometry: JSONValue = .object(["pointWidth": .number(640), "pointHeight": .number(480), "pixelWidth": .integer(1280), "pixelHeight": .integer(960)])
private let interactionPoint: JSONValue = .object(["x": .number(20), "y": .number(30)])
private func interactionParams(_ name: String) -> [String: JSONValue] {
    var params = interactionIdentity
    if name != "selection" { params["geometry"] = interactionGeometry; params["point"] = interactionPoint }
    if name == "scroll" { params["deltaX"] = .number(0); params["deltaY"] = .number(3) }
    if name == "pointer" { params["action"] = .string("click") }
    return params
}

@Test func terminalInteractionCatalogRequiresIdentityAndGeometryWithoutDefaults() throws {
    for name in ["scroll", "pointer", "selection"] {
        let method = try #require(AutomationMethod(rawValue: "terminal." + name))
        #expect(method.family == .terminal)
        #expect(method.admission == (name == "selection" ? .read : .mutation))
        let contract = try #require(AutomationCatalog.methods[method])
        let valid = interactionParams(name)
        #expect(schemaAccepts(contract.input, .object(valid)))
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            #expect(!schemaAccepts(contract.input, .object(missing)))
        }
        for key in ["tab", "scope", "contextPane", "expectedAnchorSessionId", "expectedLayoutRevision"] {
            #expect(!schemaAccepts(contract.input, .object(valid.merging([key: .string("foreign")]) { _, b in b })))
        }
        #expect(method.resolving([:], defaults: AutomationDefaults(pane: PaneID(9), tab: TabID(9), scope: "tab")).isEmpty)
        #expect(contract.semantics["changesFocusOrGeometry"] == .bool(false))
        #expect(contract.descriptor(for: method).object?["retry"] == .string("never-automatic"))
    }
}

@Test func terminalInteractionRejectsNonfiniteBoundsAndUnsupportedGestures() throws {
    for action in [TerminalInteractionRequest.Action.scroll, .pointer, .selection] {
        let valid = interactionParams(action.rawValue)
        _ = try TerminalInteractionRequest(action: action, params: valid)
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            #expect(throws: RPCFailure.self) { try TerminalInteractionRequest(action: action, params: missing) }
        }
        for key in ["scope", "tab", "expectedLayoutRevision", "button", "buttonDown", "precise"] {
            #expect(throws: RPCFailure.self) { try TerminalInteractionRequest(action: action, params: valid.merging([key: .string("unknown")]) { _, b in b }) }
        }
    }
    for value in [Double.nan, .infinity, -.infinity, -1, 640, 8193] {
        var params = interactionParams("pointer")
        params["point"] = .object(["x": .number(value), "y": .number(10)])
        #expect(throws: RPCFailure.self) { try TerminalInteractionRequest(action: .pointer, params: params) }
    }
    for key in ["pointWidth", "pointHeight", "pixelWidth", "pixelHeight"] {
        for value in [JSONValue.integer(0), .integer(-1), .integer(8193), .number(.nan), .number(.infinity)] {
            var params = interactionParams("scroll")
            var geometry = interactionGeometry.object!; geometry[key] = value; params["geometry"] = .object(geometry)
            #expect(throws: RPCFailure.self) { try TerminalInteractionRequest(action: .scroll, params: params) }
        }
    }
    for value in [Double.nan, .infinity, -.infinity, -100.01, 100.01] {
        var params = interactionParams("scroll"); params["deltaY"] = .number(value)
        #expect(throws: RPCFailure.self) { try TerminalInteractionRequest(action: .scroll, params: params) }
    }
    var zero = interactionParams("scroll"); zero["deltaY"] = .integer(0)
    #expect(throws: RPCFailure.self) { try TerminalInteractionRequest(action: .scroll, params: zero) }
    for action in ["down", "up", "doubleClick", "drag"] {
        var params = interactionParams("pointer"); params["action"] = .string(action)
        #expect(throws: RPCFailure.self) { try TerminalInteractionRequest(action: .pointer, params: params) }
    }
    for value in [JSONValue.array([.string("shift"), .string("shift")]), .array([.string("capsLock")]), .string("shift")] {
        var params = interactionParams("pointer"); params["modifiers"] = value
        #expect(throws: RPCFailure.self) { try TerminalInteractionRequest(action: .pointer, params: params) }
    }
}

@Test func terminalInteractionGeometryValidationFailsBeforeDispatch() throws {
    let request = try TerminalInteractionRequest(action: .pointer, params: interactionParams("pointer"))
    let geometry = try #require(request.geometry)
    try geometry.validate(pointWidth: 640, pointHeight: 480, pixelWidth: 1280, pixelHeight: 960)
    for (w, h, px, py) in [(641.0, 480.0, 1280, 960), (640, 481, 1280, 960), (640, 480, 1281, 960), (640, 480, 1280, 961)] {
        var events: [String] = []
        #expect(throws: RPCFailure.self) {
            try geometry.validate(pointWidth: w, pointHeight: h, pixelWidth: px, pixelHeight: py)
            try request.performPointer(move: { _ in events.append("move") }, button: { events.append($0 ? "press" : "release") })
        }
        #expect(events.isEmpty)
    }
}

@Test func terminalPointerAlwaysReleasesAndFinishesOneSynchronousGesture() throws {
    enum TestFailure: Error { case move }
    for action in ["move", "click", "drag"] {
        var params = interactionParams("pointer"); params["action"] = .string(action)
        if action == "drag" { params["to"] = .object(["x": .number(200), "y": .number(100)]) }
        let request = try TerminalInteractionRequest(action: .pointer, params: params)
        var events: [String] = []
        try request.performPointer(move: { point in events.append(point.x == 20 ? "start" : "end") },
            button: { events.append($0 ? "press" : "release") }, finish: { events.append("finish") })
        #expect(events == (action == "move" ? ["start", "finish"] : action == "click" ? ["start", "press", "release", "finish"] : ["start", "press", "end", "release", "finish"]))
        if action == "drag" {
            events = []
            #expect(throws: TestFailure.self) {
                try request.performPointer(move: { point in
                    events.append(point.x == 20 ? "start" : "end")
                    if point.x != 20 { throw TestFailure.move }
                }, button: { events.append($0 ? "press" : "release") }, finish: { events.append("finish") })
            }
            #expect(events == ["start", "press", "end", "release", "finish"])
        }
    }
}

@Test func terminalSelectionReturnsBoundedTextWithoutTruncationAndExplicitIdentity() throws {
    let request = try TerminalInteractionRequest(action: .selection, params: interactionParams("selection"))
    let contract = try #require(AutomationMethod(rawValue: "terminal.selection").flatMap { AutomationCatalog.methods[$0] })
    for text in [nil, "", "selected 🦊\ntext", String(repeating: "x", count: TerminalInteractionRequest.maximumSelectionBytes)] as [String?] {
        let fields = try TerminalInteractionRequest.selectionResult(text)
        #expect(fields["hasSelection"] == .bool(text != nil))
        #expect(fields["text"] == .string(text ?? ""))
        #expect(schemaAccepts(contract.result, request.result(fields)))
    }
    #expect(throws: RPCFailure.self) { try TerminalInteractionRequest.selectionResult(String(repeating: "é", count: 65537)) }
}

@Test func terminalInteractionSchemaAndParserAgreeForIndependentConstraints() throws {
    for name in ["scroll", "pointer", "selection"] {
        let valid = interactionParams(name)
        var samples = [valid]
        for field in ["pane", "sessionId", "expectedInstanceId"] { var p = valid; p[field] = .string(""); samples.append(p) }
        if name == "pointer" {
            for action in ["drag", "click", "up"] {
                var p = valid; p["action"] = .string(action); p["to"] = interactionPoint; samples.append(p)
            }
            for modifiers in [["shift"], ["shift", "shift"], ["control", "alt", "super"], ["unknown"]] {
                var p = valid; p["modifiers"] = .array(modifiers.map(JSONValue.string)); samples.append(p)
            }
        }
        if name == "scroll" {
            for delta in [-101, -100, 0, 100, 101] { var p = valid; p["deltaY"] = .integer(delta); samples.append(p) }
        }
        let method = try #require(AutomationMethod(rawValue: "terminal." + name))
        let schema = try #require(AutomationCatalog.methods[method]).input
        for sample in samples {
            #expect(schemaAccepts(schema, .object(sample)) == ((try? TerminalInteractionRequest(action: .init(rawValue: name)!, params: sample)) != nil), "\(name): \(sample)")
        }
    }
}

@Test func terminalScrollCannotInheritPhysicalModifiersAtTheSameNativePoint() throws {
    let request = try TerminalInteractionRequest(action: .scroll, params: interactionParams("scroll"))
    var position = (20.0, 30.0)
    var shift = true
    var wheelShift: Bool?
    var finished = false
    func motion(_ x: Double, _ y: Double, shift next: Bool) {
        // Pinned Ghostty drops unchanged coordinates BEFORE updating modifiers.
        guard position != (x, y) else { return }
        position = (x, y); shift = next
    }
    try request.performScroll(prepare: { motion(-1, -1, shift: false) },
        move: { motion($0.x, $0.y, shift: false) },
        scroll: { x, y in #expect(x == 0 && y == 3); wheelShift = shift },
        finish: { motion(-1, -1, shift: true); finished = true })
    #expect(wheelShift == false && finished && shift)
}
