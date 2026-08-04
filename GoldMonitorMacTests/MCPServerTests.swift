import Foundation
import XCTest
@testable import HelixTradingApp

/// Covers the MCP wire layer: the `JSONValue` codec, and a real server
/// bound to a loopback port and driven over HTTP.
///
/// The end-to-end half matters more than it looks. Everything about this
/// feature is invisible from inside the app — the failure mode is a
/// client that connects and gets nothing useful — so the tests speak
/// actual JSON-RPC over an actual socket rather than calling the router
/// directly.
final class MCPServerTests: XCTestCase {

    // MARK: - JSONValue

    func testJSONValueRoundTrip() throws {
        let value = JSONValue.object([
            "s": .string("hi"),
            "n": .number(42),
            "f": .number(1.5),
            "b": .bool(true),
            "nil": .null,
            "arr": .array([.number(1), .string("two")]),
            "nested": .object(["deep": .bool(false)]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testWholeNumbersEncodeAsIntegers() throws {
        let data = try JSONEncoder().encode(JSONValue.object(["bars": .number(500)]))
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.contains("\"bars\":500"),
                      "clients validating against an integer schema reject 500.0 — got \(text)")
    }

    func testAccessorsCoerceStringifiedArguments() {
        // Some clients stringify every argument; rejecting those would
        // fail calls that are semantically fine.
        XCTAssertEqual(JSONValue.string("500").intValue, 500)
        XCTAssertEqual(JSONValue.string("true").boolValue, true)
        XCTAssertEqual(JSONValue.number(3.5).doubleValue, 3.5)
        XCTAssertNil(JSONValue.string("abc").doubleValue)
        XCTAssertNil(JSONValue.null.stringValue)
    }

    // MARK: - Live server

    private var server: MCPHTTPServer?
    private var tempDirectory: URL?

    override func tearDown() {
        server?.stop()
        server = nil
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
        super.tearDown()
    }

    /// Boot a server on a high random port against a throwaway database
    /// seeded with `ounce` bars.
    private func startServer(token: String = "") throws -> (port: UInt16, database: AppDatabase) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectory = dir

        let database = try AppDatabase(url: dir.appendingPathComponent("test.db"))

        // Two sessions of 15-minute bars so previous_day_levels has a
        // settled session to profile.
        var bars: [OHLCBar] = []
        let start = Date().addingTimeInterval(-60 * 60 * 72)
        for i in 0..<600 {
            let t = start.addingTimeInterval(TimeInterval(i * 900))
            let drift = Double(i) * 0.3
            let wave = sin(Double(i) / 9.0) * 5
            let close = 2000 + drift + wave
            bars.append(OHLCBar(
                pairID: "ounce", timeframe: "5m", bucketStart: t,
                open: close - 1, high: close + 2, low: close - 2, close: close,
                volume: 1000 + Double(i % 300)
            ))
            bars.append(OHLCBar(
                pairID: "ounce", timeframe: "1h", bucketStart: t,
                open: close - 1, high: close + 2, low: close - 2, close: close,
                volume: 1000 + Double(i % 300)
            ))
        }
        try database.ohlcRepo.upsertMany(bars)

        let server = MCPHTTPServer()
        self.server = server

        // Port 0 lets the OS hand out a free one. Picking randomly
        // collides with sockets the previous test is still tearing down,
        // which is exactly the kind of flake that gets a suite disabled.
        var boundPort: UInt16 = 0
        let ready = expectation(description: "server ready")
        server.onStateChange = { state in
            if case .running(let p) = state {
                boundPort = p
                ready.fulfill()
            }
            if case .failed(let msg) = state { XCTFail("server failed: \(msg)") }
        }
        server.start(
            repo: database.ohlcRepo,
            configuration: .init(port: 0, token: token, maxBars: 5000)
        )
        wait(for: [ready], timeout: 5)
        XCTAssertGreaterThan(boundPort, 0, "the server must report the port it actually bound")
        return (boundPort, database)
    }

    /// One JSON-RPC call over HTTP. Returns the decoded response body.
    @discardableResult
    private func rpc(
        port: UInt16,
        method: String,
        params: JSONValue? = nil,
        token: String? = nil,
        id: Int = 1,
        expectedStatus: Int = 200
    ) throws -> JSONValue {
        var body: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { body["params"] = params }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let done = expectation(description: "rpc \(method)")
        var result: JSONValue = .null
        var status = 0
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { XCTFail("transport error: \(error)") }
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, !data.isEmpty {
                result = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)

        XCTAssertEqual(status, expectedStatus, "unexpected HTTP status for \(method)")
        return result
    }

    /// Call a tool and return its `structuredContent`.
    private func callTool(port: UInt16, _ name: String, _ args: JSONValue) throws -> JSONValue {
        let response = try rpc(port: port, method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": args,
        ]))
        let result = try XCTUnwrap(response["result"], "no result for \(name): \(response)")
        XCTAssertEqual(result["isError"]?.boolValue, false, "\(name) returned an error: \(result)")
        return try XCTUnwrap(result["structuredContent"])
    }

    // MARK: - Handshake

    func testInitializeReportsProtocolAndTools() throws {
        let (port, _) = try startServer()
        let response = try rpc(port: port, method: "initialize")
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["protocolVersion"]?.stringValue, MCP.protocolVersion)
        XCTAssertEqual(result["serverInfo"]?["name"]?.stringValue, MCP.serverName)
        XCTAssertNotNil(result["capabilities"]?["tools"])
        XCTAssertNotNil(result["instructions"]?.stringValue)
    }

    func testToolsListAdvertisesEveryTool() throws {
        let (port, _) = try startServer()
        let response = try rpc(port: port, method: "tools/list")
        let tools = try XCTUnwrap(response["result"]?["tools"]?.arrayValue)
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        XCTAssertEqual(names, [
            "list_symbols", "history_data", "rank_ob",
            "algosmart_assist", "previous_day_levels", "smc_brief",
        ])
        // A tool with no schema or description is unusable by an agent —
        // the listing IS the documentation.
        for tool in tools {
            XCTAssertFalse(tool["description"]?.stringValue?.isEmpty ?? true)
            XCTAssertEqual(tool["inputSchema"]?["type"]?.stringValue, "object")
        }
    }

    func testNotificationGetsNoBody() throws {
        let (port, _) = try startServer()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)

        let done = expectation(description: "notification")
        var status = 0
        var length = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            length = data?.count ?? 0
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)

        XCTAssertEqual(status, 202, "a notification must be accepted without a response body")
        XCTAssertEqual(length, 0)
    }

    func testUnknownMethodReturnsMethodNotFound() throws {
        let (port, _) = try startServer()
        let response = try rpc(port: port, method: "does/not/exist")
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32601)
    }

    // MARK: - Tools

    func testListSymbolsIncludesTheCatalog() throws {
        let (port, _) = try startServer()
        let out = try callTool(port: port, "list_symbols", .object([:]))
        let ids = Set((out["symbols"]?.arrayValue ?? []).compactMap { $0["symbol"]?.stringValue })
        XCTAssertTrue(ids.contains("ounce"))
        XCTAssertEqual(ids.count, TradingPair.catalog.count)
    }

    func testHistoryDataReturnsRequestedBars() throws {
        let (port, _) = try startServer()
        let out = try callTool(port: port, "history_data", .object([
            "symbol": .string("ounce"),
            "timeframe": .string("1h"),
            "bars": .number(50),
        ]))
        let bars = try XCTUnwrap(out["bars"]?.arrayValue)
        XCTAssertEqual(bars.count, 50)
        let first = try XCTUnwrap(bars.first)
        for key in ["t", "o", "h", "l", "c"] {
            XCTAssertNotNil(first[key], "bar is missing \(key)")
        }
        XCTAssertGreaterThanOrEqual(first["h"]!.doubleValue!, first["l"]!.doubleValue!)
    }

    func testRankOBReturnsGradedZones() throws {
        let (port, _) = try startServer()
        let out = try callTool(port: port, "rank_ob", .object([
            "symbol": .string("ounce"),
            "timeframe": .string("1h"),
            "bars": .number(400),
        ]))
        XCTAssertNotNil(out["last_close"]?.doubleValue)
        for zone in out["zones"]?.arrayValue ?? [] {
            let grade = try XCTUnwrap(zone["grade"]?.stringValue)
            XCTAssertTrue(["A", "B", "C", "–"].contains(grade))
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(zone["top"]?.doubleValue),
                try XCTUnwrap(zone["bottom"]?.doubleValue)
            )
            XCTAssertTrue(["inside", "above", "below"].contains(zone["price_location"]?.stringValue ?? ""))
        }
    }

    func testAlgoSmartAssistReturnsStructure() throws {
        let (port, _) = try startServer()
        let out = try callTool(port: port, "algosmart_assist", .object([
            "symbol": .string("ounce"),
            "timeframe": .string("1h"),
            "bars": .number(400),
        ]))
        XCTAssertNotNil(out["structure_events"]?.arrayValue)
        XCTAssertNotNil(out["poi_zones"]?.arrayValue)
        XCTAssertNotNil(out["live_levels"]?.arrayValue)
    }

    func testPreviousDayLevelsAreOrdered() throws {
        let (port, _) = try startServer()
        let out = try callTool(port: port, "previous_day_levels", .object([
            "symbol": .string("ounce"),
            "timeframe": .string("1h"),
            "bars": .number(400),
        ]))
        guard out["available"]?.boolValue == true else {
            // A window that doesn't span two sessions must explain
            // itself rather than return a blank object.
            XCTAssertNotNil(out["reason"]?.stringValue)
            return
        }
        let pdh = try XCTUnwrap(out["pdh"]?.doubleValue)
        let pdl = try XCTUnwrap(out["pdl"]?.doubleValue)
        let poc = try XCTUnwrap(out["poc"]?.doubleValue)
        let vah = try XCTUnwrap(out["vah"]?.doubleValue)
        let val = try XCTUnwrap(out["val"]?.doubleValue)
        XCTAssertGreaterThan(pdh, pdl)
        XCTAssertTrue(val <= poc && poc <= vah, "POC must sit inside the value area")
        XCTAssertTrue(pdl <= val && vah <= pdh, "the value area must sit inside the session range")
    }

    func testSMCBriefBundlesMarkdownAndJSON() throws {
        let (port, _) = try startServer()
        let out = try callTool(port: port, "smc_brief", .object([
            "symbol": .string("ounce"),
            "timeframe": .string("1h"),
            "bars": .number(400),
        ]))
        let markdown = try XCTUnwrap(out["markdown"]?.stringValue)
        XCTAssertTrue(markdown.contains("Ranked Order Blocks"))
        XCTAssertNotNil(out["evidence"]?["meta"])
        XCTAssertNotNil(out["instructions"]?.stringValue)
    }

    // MARK: - Errors

    func testUnknownSymbolIsAToolErrorNotATransportError() throws {
        let (port, _) = try startServer()
        let response = try rpc(port: port, method: "tools/call", params: .object([
            "name": .string("rank_ob"),
            "arguments": .object(["symbol": .string("dogecoin")]),
        ]))
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        // The model has to see the message to correct itself, so it
        // belongs in the result, not in a JSON-RPC error the client eats.
        let text = try XCTUnwrap(result["structuredContent"]?["error"]?.stringValue)
        XCTAssertTrue(text.contains("dogecoin"))
        XCTAssertTrue(text.contains("ounce"), "the error should list valid symbols")
    }

    func testMissingRequiredArgumentIsReported() throws {
        let (port, _) = try startServer()
        let response = try rpc(port: port, method: "tools/call", params: .object([
            "name": .string("rank_ob"),
            "arguments": .object([:]),
        ]))
        XCTAssertEqual(response["result"]?["isError"]?.boolValue, true)
    }

    /// An unknown *tool* is a protocol error, unlike a tool that runs and
    /// fails — the spec splits those, and clients rely on the split to
    /// tell "you called something that doesn't exist" from "your
    /// arguments were wrong".
    func testUnknownToolNameIsAProtocolError() throws {
        let (port, _) = try startServer()
        let response = try rpc(port: port, method: "tools/call", params: .object([
            "name": .string("nope"),
            "arguments": .object([:]),
        ]))
        XCTAssertNil(response["result"])
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32602)
        let message = try XCTUnwrap(response["error"]?["message"]?.stringValue)
        XCTAssertTrue(message.contains("rank_ob"), "the error should list what is available: \(message)")
    }

    // MARK: - Security

    func testBearerTokenIsEnforced() throws {
        let (port, _) = try startServer(token: "s3cret")
        // Wrong token → 401 before any routing happens.
        _ = try rpc(port: port, method: "tools/list", token: "wrong", expectedStatus: 401)
        // Right token → normal response.
        let ok = try rpc(port: port, method: "tools/list", token: "s3cret")
        XCTAssertNotNil(ok["result"]?["tools"])
    }

    func testCrossOriginRequestIsRejected() throws {
        let (port, _) = try startServer()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        // A page on the open web scripting the user's loopback port —
        // the DNS-rebinding attack the MCP spec calls out.
        request.setValue("https://evil.example.com", forHTTPHeaderField: "Origin")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)

        let done = expectation(description: "origin check")
        var status = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(status, 403)
    }

    func testLoopbackOriginIsAccepted() throws {
        let (port, _) = try startServer()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("http://localhost:3000", forHTTPHeaderField: "Origin")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)

        let done = expectation(description: "loopback origin")
        var status = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(status, 200, "a local dev client must not be blocked by the rebinding guard")
    }

    func testHealthEndpoint() throws {
        let (port, _) = try startServer()
        let done = expectation(description: "health")
        var payload: JSONValue = .null
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/health")!) { data, _, _ in
            if let data { payload = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(payload["status"]?.stringValue, "ok")
        XCTAssertEqual(payload["tools"]?.intValue, 6)
    }
}
