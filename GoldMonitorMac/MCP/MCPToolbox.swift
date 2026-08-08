import Foundation

/// The tools the local MCP server exposes.
///
/// Every tool reads from the app's own GRDB store and runs the app's own
/// indicator engines, so an external agent sees exactly what the chart
/// shows — same bars, same `RankedOrderBlocks.compute`, same
/// `AlgoSmartAssist.calculate`, same 18:00-ET session boundary for the
/// previous day. Re-implementing any of that on the client side is how
/// two views of one market drift apart.
///
/// Tools are synchronous and pure apart from the DB read. They run on the
/// connection's queue, never the main actor: a 2000-bar ALGOSMART pass is
/// tens of milliseconds and must not touch the UI thread.
struct MCPToolbox {

    /// Bars a single call may return, whatever it asks for. Also caps the
    /// window every indicator sees, so one greedy client can't pull the
    /// whole history into memory.
    let maxBars: Int
    private let repo: OHLCRepo

    init(repo: OHLCRepo, maxBars: Int = 5000) {
        self.repo = repo
        self.maxBars = maxBars
    }

    var tools: [MCPTool] {
        [listSymbols, historyData, rankOB, algoSmartAssist, previousDayLevels, smcBrief, fvgDetector, sessionRanges, mtfBias, positionSizer]
    }

    func tool(named name: String) -> MCPTool? {
        tools.first { $0.name == name }
    }

    // MARK: - list_symbols

    private var listSymbols: MCPTool {
        MCPTool(
            name: "list_symbols",
            title: "List symbols",
            description: """
            List the trading symbols this server can analyse, with the \
            symbol id every other tool expects and how much history is \
            stored per timeframe. Call this first if you don't already \
            know the symbol id — the other tools reject unknown ids \
            rather than guessing.
            """,
            inputSchema: MCPSchema.object(properties: [:]),
            run: { _ in
                let rows: [JSONValue] = TradingPair.catalog.map { def in
                    .object([
                        "symbol": .string(def.id),
                        "name": .string(def.name),
                        "ticker": .string(def.symbol),
                        "category": .string(def.category.rawValue),
                    ])
                }
                return .object([
                    "symbols": .array(rows),
                    "timeframes": .array(Timeframe.allCases.map { .string($0.rawValue) }),
                ])
            }
        )
    }

    // MARK: - history_data

    private var historyData: MCPTool {
        MCPTool(
            name: "history_data",
            title: "OHLCV history",
            description: """
            Raw OHLCV candles for a symbol and timeframe, oldest first. \
            15m / 30m / 4h are folded on read from the stored 5m / 1h \
            series, exactly as the chart does it. Use this when you want \
            to inspect price action yourself; for structure, prefer \
            rank_ob / algosmart_assist / previous_day_levels, which run \
            the real detection engines instead of asking you to eyeball \
            it.
            """,
            inputSchema: MCPSchema.object(
                properties: [
                    "symbol": MCPSchema.string("Symbol id from list_symbols, e.g. \"ounce\", \"btc\"."),
                    "timeframe": MCPSchema.string("Bar size.", enum: Timeframe.allCases.map(\.rawValue), default: "1h"),
                    "bars": MCPSchema.integer("How many of the most recent bars to return.", min: 1, max: maxBars, default: 300),
                    "include_volume": MCPSchema.boolean("Include the volume field on each bar.", default: true),
                ],
                required: ["symbol"]
            ),
            run: { args in
                let req = try self.parseSeriesRequest(args, defaultBars: 300)
                let includeVolume = args["include_volume"]?.boolValue ?? true

                let bars: [JSONValue] = req.candles.map { c in
                    var o: [String: JSONValue] = [
                        "t": .string(ISO8601DateFormatter().string(from: c.bucketStart)),
                        "o": .number(c.open),
                        "h": .number(c.high),
                        "l": .number(c.low),
                        "c": .number(c.close),
                    ]
                    if includeVolume, let v = c.volume { o["v"] = .number(v) }
                    return .object(o)
                }
                return .object([
                    "symbol": .string(req.pairID),
                    "timeframe": .string(req.timeframe.rawValue),
                    "bar_count": .number(Double(req.candles.count)),
                    "bars": .array(bars),
                ])
            }
        )
    }

    // MARK: - rank_ob

    private var rankOB: MCPTool {
        MCPTool(
            name: "rank_ob",
            title: "Ranked order blocks",
            description: """
            Swing order blocks graded A / B / C on Volume-Profile and \
            Ichimoku confluence. Each zone reports its price range, the \
            grade and raw score, how many bars back it formed, whether \
            price is currently inside it, its distance from spot in ATR \
            units, and whether it has become a breaker (traded through, \
            so it now works in the opposite direction). Grade A means \
            the zone scored at least 70% of the available confluence, \
            B at least 40%. Use it to choose which zone to trade, not \
            whether to trade.
            """,
            inputSchema: MCPSchema.object(
                properties: [
                    "symbol": MCPSchema.string("Symbol id from list_symbols."),
                    "timeframe": MCPSchema.string("Bar size.", enum: Timeframe.allCases.map(\.rawValue), default: "1h"),
                    "bars": MCPSchema.integer("History window the detector scans.", min: 60, max: maxBars, default: 800),
                    "zones_per_side": MCPSchema.integer("Zones returned per direction, newest first.", min: 1, max: 10, default: 3),
                    "swing_length": MCPSchema.integer("Pivot lookback that defines a protected swing.", min: 3, max: 50, default: 10),
                    "zone_from": MCPSchema.string("Build zones from the full candle range or the body only.", enum: ["wicks", "body"], default: "wicks"),
                    "invalidation": MCPSchema.string("What counts as trading through a zone.", enum: ["wick", "close"], default: "wick"),
                    "max_atr_mult": MCPSchema.number("Discard zones wider than this multiple of ATR.", min: 0.5, max: 20, default: 3.5),
                    "use_volume_profile": MCPSchema.boolean("Score Volume-Profile overlap (0-2 points).", default: true),
                    "use_ichimoku": MCPSchema.boolean("Score Ichimoku alignment (0-3 points).", default: true),
                    "show_breakers": MCPSchema.boolean("Include zones that have flipped to breakers.", default: true),
                ],
                required: ["symbol"]
            ),
            run: { args in
                let req = try self.parseSeriesRequest(args, defaultBars: 800, minBars: 60)

                var cfg = RankedOrderBlocks.Config()
                cfg.zonesPerSide = args["zones_per_side"]?.intValue ?? cfg.zonesPerSide
                cfg.swingLength = args["swing_length"]?.intValue ?? cfg.swingLength
                if args["zone_from"]?.stringValue == "body" { cfg.zoneSource = .body }
                if args["invalidation"]?.stringValue == "close" { cfg.invalidation = .close }
                cfg.maxATRMult = args["max_atr_mult"]?.doubleValue ?? cfg.maxATRMult
                cfg.useVolumeProfile = args["use_volume_profile"]?.boolValue ?? cfg.useVolumeProfile
                cfg.useIchimoku = args["use_ichimoku"]?.boolValue ?? cfg.useIchimoku
                cfg.showBreakers = args["show_breakers"]?.boolValue ?? cfg.showBreakers

                let candles = req.candles
                let zones = RankedOrderBlocks.compute(candles, config: cfg)
                let spot = candles.last?.close ?? 0
                let atr = SMCEvidence.wilderATR(candles, period: 14)
                let lastIndex = candles.count - 1

                let rows: [JSONValue] = zones.map { z in
                    let location = (spot >= z.bottom && spot <= z.top)
                        ? "inside" : (spot > z.top ? "above" : "below")
                    let edge = spot > z.top ? z.top : (spot < z.bottom ? z.bottom : spot)
                    var o: [String: JSONValue] = [
                        "grade": .string(z.grade.rawValue),
                        "score": .number(Double(z.score)),
                        "max_score": .number(Double(z.maxScore)),
                        "direction": .string(z.isBullish ? "bullish" : "bearish"),
                        "top": .number(z.top),
                        "bottom": .number(z.bottom),
                        "mid": .number((z.top + z.bottom) / 2),
                        "bars_ago": .number(Double(max(0, lastIndex - z.startIndex))),
                        "is_breaker": .bool(z.isBreaker),
                        "is_combined": .bool(z.isCombined),
                        "price_location": .string(location),
                        "zone_atr": .number(z.atr),
                    ]
                    if let atr, atr > 0 {
                        o["distance_atr"] = .number(location == "inside" ? 0 : abs(spot - edge) / atr)
                    }
                    return .object(o)
                }

                return .object([
                    "symbol": .string(req.pairID),
                    "timeframe": .string(req.timeframe.rawValue),
                    "bar_count": .number(Double(candles.count)),
                    "last_close": .number(spot),
                    "atr14": atr.map { JSONValue.number($0) } ?? .null,
                    "zones": .array(rows),
                ])
            }
        )
    }

    // MARK: - algosmart_assist

    private var algoSmartAssist: MCPTool {
        MCPTool(
            name: "algosmart_assist",
            title: "ALGOSMART ASSIST v2 (SMC structure)",
            description: """
            Smart-Money market structure from the ALGOSMART ASSIST v2 \
            engine: confirmed BOS / CHoCH / IDM / liquidity-sweep events \
            with prices and age, supply and demand POI zones tagged fresh \
            or mitigated and premium or discount, and the live working \
            levels including the 0.5 equilibrium of the current leg. \
            Optionally also runs the app's SMC rules engine, which \
            requires HTF context, then a liquidity grab, then a POI on \
            the right side of equilibrium, then a trigger — and reports \
            which of those is currently blocking a setup.
            """,
            inputSchema: MCPSchema.object(
                properties: [
                    "symbol": MCPSchema.string("Symbol id from list_symbols."),
                    "timeframe": MCPSchema.string("Entry timeframe.", enum: Timeframe.allCases.map(\.rawValue), default: "15m"),
                    "bars": MCPSchema.integer("History window the engine scans.", min: 60, max: maxBars, default: 800),
                    "events": MCPSchema.integer("How many confirmed structure events to return, newest last.", min: 1, max: 40, default: 8),
                    "poi_per_side": MCPSchema.integer("POI zones returned per side.", min: 1, max: 10, default: 3),
                    "include_setups": MCPSchema.boolean("Run the SMC rules engine for qualified setups with entry / SL / TP.", default: true),
                    "htf_timeframe": MCPSchema.string("Timeframe supplying directional context for the rules engine. Defaults to one step above the entry timeframe.", enum: Timeframe.allCases.map(\.rawValue)),
                ],
                required: ["symbol"]
            ),
            run: { args in
                let req = try self.parseSeriesRequest(args, defaultBars: 800, minBars: 60, defaultTimeframe: .m15)
                let includeSetups = args["include_setups"]?.boolValue ?? true

                let htf = try self.resolveHTF(args, request: req, load: includeSetups)
                var opts = SMCEvidence.Options.default
                opts.structureEvents = args["events"]?.intValue ?? 8
                opts.poiPerSide = args["poi_per_side"]?.intValue ?? 3
                opts.includeSentinel = includeSetups
                // This tool is about structure; ranked zones are the
                // rank_ob tool's job. Keeping one zone per side is enough
                // for the POI-overlap flag to stay meaningful without
                // duplicating that tool's output.
                opts.zonesPerSide = 1

                let evidence = SMCEvidence.build(
                    pairID: req.pairID,
                    symbol: req.symbol,
                    timeframe: req.timeframe,
                    candles: req.candles,
                    htfCandles: htf.candles,
                    htfLabel: htf.label,
                    htfFactor: htf.factor,
                    options: opts
                )

                var out: [String: JSONValue] = [
                    "symbol": .string(req.pairID),
                    "timeframe": .string(req.timeframe.rawValue),
                    "htf_timeframe": htf.label.isEmpty ? .null : .string(htf.label),
                    "last_close": .number(evidence.meta.lastClose),
                    "atr14": evidence.meta.atr14.map { JSONValue.number($0) } ?? .null,
                    "structure_events": try JSONValue.from(evidence.structureEvents),
                    "poi_zones": try JSONValue.from(evidence.poiZones),
                    "live_levels": try JSONValue.from(evidence.liveLevels),
                    "gaps": .array(evidence.gaps.map { .string($0) }),
                ]
                if let sentinel = evidence.sentinel {
                    out["setups"] = try JSONValue.from(sentinel)
                }
                return .object(out)
            }
        )
    }

    // MARK: - previous_day_levels

    private var previousDayLevels: MCPTool {
        MCPTool(
            name: "previous_day_levels",
            title: "Previous day PDH / PDL / POC",
            description: """
            The previous completed trading session's high, low, 50% mid, \
            open and close, plus that session's volume profile (POC, VAH, \
            VAL). Sessions run 18:00 to 17:00 New York time, the CME \
            convention, so these match the chart exactly and never move \
            intraday. Also reports where spot sits relative to the range \
            and value area, and which of PDH / PDL the current session \
            has not yet taken — untouched previous-day extremes are the \
            liquidity price is most often drawn to.
            """,
            inputSchema: MCPSchema.object(
                properties: [
                    "symbol": MCPSchema.string("Symbol id from list_symbols."),
                    "timeframe": MCPSchema.string("Bar size the profile is built from. Finer bars give a finer profile; 15m or below is typical.", enum: Timeframe.allCases.map(\.rawValue), default: "15m"),
                    "bars": MCPSchema.integer("History window. Must span at least two sessions or there is no previous day to profile.", min: 60, max: maxBars, default: 600),
                    "buckets": MCPSchema.integer("Price bands in the volume histogram.", min: 10, max: 100, default: 24),
                    "value_area_pct": MCPSchema.number("Share of session volume inside the value area.", min: 50, max: 95, default: 70),
                    "include_profile": MCPSchema.boolean("Include the full per-bucket histogram, not just POC / VAH / VAL.", default: false),
                ],
                required: ["symbol"]
            ),
            run: { args in
                let req = try self.parseSeriesRequest(args, defaultBars: 600, minBars: 60, defaultTimeframe: .m15)
                let buckets = args["buckets"]?.intValue ?? 24
                let vaPct = args["value_area_pct"]?.doubleValue ?? 70
                let includeProfile = args["include_profile"]?.boolValue ?? false

                guard let vp = VolumeProfile.computePreviousDay(
                    req.candles, bucketCount: buckets, valueAreaPct: vaPct
                ) else {
                    // A miss here is nearly always too short a window, so
                    // say that rather than returning an empty object the
                    // caller has to interpret.
                    return .object([
                        "symbol": .string(req.pairID),
                        "timeframe": .string(req.timeframe.rawValue),
                        "available": .bool(false),
                        "reason": .string("The \(req.candles.count)-bar window does not span two complete 18:00-ET sessions. Request more bars or a finer timeframe."),
                    ])
                }

                let spot = req.candles.last?.close ?? 0
                let location: String
                if spot > vp.high                        { location = "above PDH" }
                else if spot < vp.low                    { location = "below PDL" }
                else if spot >= vp.val && spot <= vp.vah { location = "inside value" }
                else if spot > vp.vah                    { location = "inside range, above value" }
                else                                     { location = "inside range, below value" }

                var unswept: [JSONValue] = []
                let todayBars = req.candles[(vp.endBar + 1)...]
                if !todayBars.isEmpty {
                    if !todayBars.contains(where: { $0.high >= vp.high }) { unswept.append(.string("PDH")) }
                    if !todayBars.contains(where: { $0.low  <= vp.low  }) { unswept.append(.string("PDL")) }
                }

                var out: [String: JSONValue] = [
                    "symbol": .string(req.pairID),
                    "timeframe": .string(req.timeframe.rawValue),
                    "available": .bool(true),
                    "pdh": .number(vp.high),
                    "pdl": .number(vp.low),
                    "mid": .number(vp.mid),
                    "open": .number(vp.open),
                    "close": .number(vp.close),
                    "range": .number(vp.high - vp.low),
                    "poc": .number(vp.poc),
                    "vah": .number(vp.vah),
                    "val": .number(vp.val),
                    "has_real_volume": .bool(vp.hasRealVolume),
                    "last_close": .number(spot),
                    "price_location": .string(location),
                    "unswept_levels": .array(unswept),
                    "session_start": .string(ISO8601DateFormatter().string(from: req.candles[vp.startBar].bucketStart)),
                    "session_end": .string(ISO8601DateFormatter().string(from: req.candles[vp.endBar].bucketStart)),
                ]
                if includeProfile {
                    out["bucket_size"] = .number(vp.bucketSize)
                    out["profile"] = .array(vp.buckets.map { b in
                        .object([
                            "price": .number(b.priceLevel),
                            "volume": .number(b.volume),
                            "up_volume": .number(b.upVolume),
                            "down_volume": .number(b.downVolume),
                        ])
                    })
                }
                return .object(out)
            }
        )
    }

    // MARK: - smc_brief

    private var smcBrief: MCPTool {
        MCPTool(
            name: "smc_brief",
            title: "Smart Money brief",
            description: """
            Everything the other tools return, assembled into one \
            Smart-Money evidence pack for a symbol: ranked order blocks \
            with grades and ATR distances, ALGOSMART structure and POI \
            zones, previous-day PDH / PDL / POC, and the mechanical \
            setups the app's rules engine already qualified — on the \
            entry timeframe and the one above it for bias. Returns both \
            structured JSON and a markdown rendering, plus the desk's \
            analysis instructions. Prefer this over calling the \
            individual tools when you actually want an SMC read: one \
            call, and the two timeframes are guaranteed consistent.
            """,
            inputSchema: MCPSchema.object(
                properties: [
                    "symbol": MCPSchema.string("Symbol id from list_symbols."),
                    "timeframe": MCPSchema.string("Entry timeframe.", enum: Timeframe.allCases.map(\.rawValue), default: "15m"),
                    "bars": MCPSchema.integer("History window per timeframe.", min: 60, max: maxBars, default: 800),
                    "htf_timeframe": MCPSchema.string("Bias timeframe. Defaults to one step above the entry timeframe.", enum: Timeframe.allCases.map(\.rawValue)),
                    "format": MCPSchema.string("\"markdown\" is the readable brief, \"json\" the structured pack, \"both\" returns each.", enum: ["both", "markdown", "json"], default: "both"),
                    "include_instructions": MCPSchema.boolean("Include the SMC desk's analysis method — the reasoning order and output contract the Helix app uses.", default: true),
                ],
                required: ["symbol"]
            ),
            run: { args in
                let req = try self.parseSeriesRequest(args, defaultBars: 800, minBars: 60, defaultTimeframe: .m15)
                let format = args["format"]?.stringValue ?? "both"
                let htf = try self.resolveHTF(args, request: req, load: true)

                let evidence = SMCEvidence.build(
                    pairID: req.pairID,
                    symbol: req.symbol,
                    timeframe: req.timeframe,
                    candles: req.candles,
                    htfCandles: htf.candles,
                    htfLabel: htf.label,
                    htfFactor: htf.factor
                )

                var htfEvidence: SMCEvidence? = nil
                if !htf.candles.isEmpty, let htfTF = htf.timeframe {
                    var opts = SMCEvidence.Options.default
                    opts.includeSentinel = false
                    opts.zonesPerSide = 2
                    opts.poiPerSide = 2
                    opts.structureEvents = 4
                    htfEvidence = SMCEvidence.build(
                        pairID: req.pairID, symbol: req.symbol, timeframe: htfTF,
                        candles: htf.candles, options: opts
                    )
                }

                var out: [String: JSONValue] = [
                    "symbol": .string(req.pairID),
                    "timeframe": .string(req.timeframe.rawValue),
                    "htf_timeframe": htf.label.isEmpty ? .null : .string(htf.label),
                ]
                if format != "json" {
                    var md = ""
                    if let htfEvidence, let htfTF = htf.timeframe {
                        md += "# Higher timeframe — \(htfTF.label) (bias)\n\n\(htfEvidence.markdown())\n\n"
                    }
                    md += "# Entry timeframe — \(req.timeframe.label)\n\n\(evidence.markdown())"
                    out["markdown"] = .string(md)
                }
                if format != "markdown" {
                    out["evidence"] = try JSONValue.from(evidence)
                    if let htfEvidence { out["htf_evidence"] = try JSONValue.from(htfEvidence) }
                }
                if args["include_instructions"]?.boolValue ?? true {
                    out["instructions"] = .string(PromptBuilder.systemSMCDesk)
                }
                return .object(out)
            }
        )
    }

    // MARK: - fvg_detector

    private var fvgDetector: MCPTool {
        MCPTool(
            name: "fvg_detector",
            title: "Fair Value Gap detector",
            description: """
            Scans 3-bar Fair Value Gaps (Bullish & Bearish FVGs), calculates \
            gap size and gap %, and checks if subsequent price action has \
            mitigated the gap.
            """,
            inputSchema: MCPSchema.object(
                properties: [
                    "symbol": MCPSchema.string("Symbol id from list_symbols."),
                    "source": MCPSchema.string("Data source feed.", default: "derived"),
                    "timeframe": MCPSchema.string("Bar size.", enum: Timeframe.allCases.map(\.rawValue), default: "1h"),
                    "limit": MCPSchema.integer("How many bars to scan.", min: 10, max: maxBars, default: 300),
                    "bars": MCPSchema.integer("Alias for limit.", min: 10, max: maxBars),
                    "min_gap_pct": MCPSchema.number("Minimum gap size as a percentage threshold (e.g. 0.001 for 0.1%).", min: 0, default: 0.001),
                    "max_events": MCPSchema.integer("Maximum gap events to return.", min: 1, max: 50, default: 10),
                ],
                required: ["symbol"]
            ),
            run: { args in
                let barCount = args["limit"]?.intValue ?? args["bars"]?.intValue ?? 300
                var modifiedArgs = args
                modifiedArgs["bars"] = .number(Double(barCount))
                let req = try self.parseSeriesRequest(modifiedArgs, defaultBars: 300, minBars: 10, defaultTimeframe: .h1)

                let rawMinGap = args["min_gap_pct"]?.doubleValue ?? 0.001
                let thresholdPct = rawMinGap <= 0.05 ? rawMinGap * 100.0 : rawMinGap
                let maxEvents = args["max_events"]?.intValue ?? 10

                let zones = FairValueGap.compute(req.candles, threshold: thresholdPct, maxZones: maxEvents)
                let spot = req.candles.last?.close ?? 0
                let lastIndex = req.candles.count - 1

                let rows: [JSONValue] = zones.map { z in
                    let size = z.high - z.low
                    let pct = z.low > 0 ? (size / z.low) : 0
                    return .object([
                        "direction": .string(z.isBullish ? "bullish" : "bearish"),
                        "high": .number(z.high),
                        "low": .number(z.low),
                        "mid": .number(z.mid),
                        "gap_size": .number(size),
                        "gap_pct": .number(pct),
                        "is_mitigated": .bool(z.isMitigated),
                        "bars_ago": .number(Double(max(0, lastIndex - z.index))),
                    ])
                }

                return .object([
                    "symbol": .string(req.pairID),
                    "source": .string(args["source"]?.stringValue ?? "derived"),
                    "timeframe": .string(req.timeframe.rawValue),
                    "last_close": .number(spot),
                    "total_gaps": .number(Double(zones.count)),
                    "gaps": .array(rows),
                ])
            }
        )
    }

    // MARK: - session_ranges

    private var sessionRanges: MCPTool {
        MCPTool(
            name: "session_ranges",
            title: "Trading session ranges",
            description: """
            Tracks Asia (00:00–08:00 UTC), London (07:00–16:00 UTC), and \
            NY (13:00–21:00 UTC) session Highs, Lows, Mids (50% equilibrium), \
            Range, and flags if current spot price has swept session extremes.
            """,
            inputSchema: MCPSchema.object(
                properties: [
                    "symbol": MCPSchema.string("Symbol id from list_symbols."),
                    "source": MCPSchema.string("Data source feed.", default: "derived"),
                    "timeframe": MCPSchema.string("Bar size.", enum: Timeframe.allCases.map(\.rawValue), default: "15m"),
                    "lookback_days": MCPSchema.integer("How many days of session history to analyze.", min: 1, max: 30, default: 5),
                ],
                required: ["symbol"]
            ),
            run: { args in
                let lookbackDays = args["lookback_days"]?.intValue ?? 5
                let tfArg = args["timeframe"]?.stringValue ?? "15m"
                let tf = Timeframe(rawValue: tfArg) ?? .m15
                let estimatedBars = Int(Double(lookbackDays * 86400) / tf.seconds) + 100

                var modifiedArgs = args
                modifiedArgs["bars"] = .number(Double(min(estimatedBars, self.maxBars)))
                let req = try self.parseSeriesRequest(modifiedArgs, defaultBars: min(estimatedBars, 600), minBars: 20, defaultTimeframe: .m15)

                let utcDefs = [
                    TradingSessions.SessionDef(id: "asia", name: "Asia", session: "0000-0800", timezone: "UTC", color: .blue),
                    TradingSessions.SessionDef(id: "london", name: "London", session: "0700-1600", timezone: "UTC", color: .orange),
                    TradingSessions.SessionDef(id: "newYork", name: "New York", session: "1300-2100", timezone: "UTC", color: .green),
                ]

                let runs = TradingSessions.compute(req.candles, defs: utcDefs)
                let spot = req.candles.last?.close ?? 0
                let totalBars = req.candles.count

                let rows: [JSONValue] = runs.suffix(lookbackDays * 3).map { r in
                    var isHighSwept = false
                    var isLowSwept = false
                    if r.end + 1 < totalBars {
                        let subsequent = req.candles[(r.end + 1)...]
                        isHighSwept = subsequent.contains(where: { $0.high > r.high })
                        isLowSwept = subsequent.contains(where: { $0.low < r.low })
                    }

                    let startTime = ISO8601DateFormatter().string(from: req.candles[r.start].bucketStart)
                    let endTime = ISO8601DateFormatter().string(from: req.candles[r.end].bucketStart)

                    return .object([
                        "session": .string(r.sessionID),
                        "name": .string(r.name),
                        "start_time": .string(startTime),
                        "end_time": .string(endTime),
                        "high": .number(r.high),
                        "low": .number(r.low),
                        "mid": .number((r.high + r.low) / 2.0),
                        "range": .number(r.range),
                        "open": .number(r.open),
                        "close": .number(r.close),
                        "is_high_swept": .bool(isHighSwept),
                        "is_low_swept": .bool(isLowSwept),
                    ])
                }

                return .object([
                    "symbol": .string(req.pairID),
                    "source": .string(args["source"]?.stringValue ?? "derived"),
                    "timeframe": .string(req.timeframe.rawValue),
                    "last_close": .number(spot),
                    "sessions": .array(rows),
                ])
            }
        )
    }

    // MARK: - mtf_bias

    private var mtfBias: MCPTool {
        MCPTool(
            name: "mtf_bias",
            title: "Multi-timeframe directional bias",
            description: """
            Evaluates price vs. EMA20 & EMA50 alignment across 6 timeframes \
            (1m, 5m, 15m, 1h, 4h, 1d) to output an overall directional bias \
            (Strongly Bullish, Bullish, Neutral, Bearish, Strongly Bearish).
            """,
            inputSchema: MCPSchema.object(
                properties: [
                    "symbol": MCPSchema.string("Symbol id from list_symbols."),
                    "source": MCPSchema.string("Data source feed.", default: "derived"),
                    "limit": MCPSchema.integer("Bar history limit per timeframe.", min: 60, max: maxBars, default: 200),
                    "bars": MCPSchema.integer("Alias for limit.", min: 60, max: maxBars),
                ],
                required: ["symbol"]
            ),
            run: { args in
                guard let symbolArg = args["symbol"]?.stringValue, !symbolArg.isEmpty else {
                    throw JSONRPCError.invalidParams("`symbol` is required. Call list_symbols for valid ids.")
                }
                let needle = symbolArg.lowercased()
                guard let def = TradingPair.catalog.first(where: {
                    $0.id.lowercased() == needle || $0.symbol.lowercased() == needle
                }) else {
                    let known = TradingPair.catalog.map(\.id).joined(separator: ", ")
                    throw JSONRPCError.invalidParams("Unknown symbol \"\(symbolArg)\". Known symbols: \(known).")
                }

                let limit = args["limit"]?.intValue ?? args["bars"]?.intValue ?? 200
                let timeframesToScan: [Timeframe] = [.m1, .m5, .m15, .h1, .h4, .d1]

                var tfReports: [JSONValue] = []
                var totalScore = 0

                for tf in timeframesToScan {
                    let until = Date()
                    let since = until.addingTimeInterval(-tf.seconds * Double(limit) * 3)
                    let loaded = OHLCCandleLoader.load(
                        repo: self.repo,
                        pairID: def.id,
                        tf: tf,
                        since: since,
                        until: until,
                        dropClosedDays: def.category != .crypto
                    )

                    guard loaded.count >= 50 else {
                        tfReports.append(.object([
                            "timeframe": .string(tf.rawValue),
                            "status": .string("insufficient_data"),
                        ]))
                        continue
                    }

                    let candles = Array(loaded.suffix(limit))
                    let closes = candles.map(\.close)
                    let ema20s = Self.emaSeries(closes, period: 20)
                    let ema50s = Self.emaSeries(closes, period: 50)

                    guard let lastClose = closes.last,
                          let lastEMA20 = ema20s.last ?? nil,
                          let lastEMA50 = ema50s.last ?? nil else {
                        continue
                    }

                    let score: Int
                    let alignment: String
                    let bias: String

                    if lastClose > lastEMA20 && lastEMA20 > lastEMA50 {
                        score = 2
                        alignment = "bullish"
                        bias = "Bullish"
                    } else if lastClose < lastEMA20 && lastEMA20 < lastEMA50 {
                        score = -2
                        alignment = "bearish"
                        bias = "Bearish"
                    } else if lastClose > lastEMA20 {
                        score = 1
                        alignment = "mixed"
                        bias = "Slightly Bullish"
                    } else if lastClose < lastEMA20 {
                        score = -1
                        alignment = "mixed"
                        bias = "Slightly Bearish"
                    } else {
                        score = 0
                        alignment = "neutral"
                        bias = "Neutral"
                    }

                    totalScore += score

                    tfReports.append(.object([
                        "timeframe": .string(tf.rawValue),
                        "close": .number(lastClose),
                        "ema20": .number(lastEMA20),
                        "ema50": .number(lastEMA50),
                        "alignment": .string(alignment),
                        "bias": .string(bias),
                        "score": .number(Double(score)),
                    ]))
                }

                let overallBias: String
                switch totalScore {
                case 6...:   overallBias = "Strongly Bullish"
                case 2...5:  overallBias = "Bullish"
                case -1...1: overallBias = "Neutral"
                case -5...(-2): overallBias = "Bearish"
                default:     overallBias = "Strongly Bearish"
                }

                return .object([
                    "symbol": .string(def.id),
                    "source": .string(args["source"]?.stringValue ?? "derived"),
                    "overall_bias": .string(overallBias),
                    "composite_score": .number(Double(totalScore)),
                    "timeframes": .array(tfReports),
                ])
            }
        )
    }

    /// Helper for calculation of EMA series over array of Double values.
    private static func emaSeries(_ values: [Double], period: Int) -> [Double?] {
        guard values.count >= period, period > 0 else { return Array(repeating: nil, count: values.count) }
        var result: [Double?] = Array(repeating: nil, count: values.count)
        let k = 2.0 / Double(period + 1)
        let sma = values[0..<period].reduce(0, +) / Double(period)
        result[period - 1] = sma
        var prev = sma
        for i in period..<values.count {
            let current = values[i] * k + prev * (1 - k)
            result[i] = current
            prev = current
        }
        return result
    }

    // MARK: - position_sizer

    private var positionSizer: MCPTool {
        MCPTool(
            name: "position_sizer",
            title: "Position size and risk calculator",
            description: """
            Calculates unit position size, lot size, monetary risk ($), \
            and Risk-to-Reward (R:R) ratio based on account balance, risk %, \
            entry price, stop loss, take profit, and contract size.
            """,
            inputSchema: MCPSchema.object(
                properties: [
                    "account_balance": MCPSchema.number("Account balance currency units.", default: 10000),
                    "risk_pct": MCPSchema.number("Percentage of account to risk per trade.", default: 1.0),
                    "entry_price": MCPSchema.number("Entry price level."),
                    "stop_loss": MCPSchema.number("Stop loss price level."),
                    "take_profit": MCPSchema.number("Take profit price level (optional)."),
                    "contract_size": MCPSchema.number("Units per 1 lot (e.g. 100 for gold, 100000 for forex).", default: 100),
                ],
                required: ["entry_price", "stop_loss"]
            ),
            run: { args in
                guard let entry = args["entry_price"]?.doubleValue else {
                    throw JSONRPCError.invalidParams("`entry_price` parameter is required.")
                }
                guard let sl = args["stop_loss"]?.doubleValue else {
                    throw JSONRPCError.invalidParams("`stop_loss` parameter is required.")
                }
                let balance = args["account_balance"]?.doubleValue ?? 10000.0
                let riskPct = args["risk_pct"]?.doubleValue ?? 1.0
                let contractSize = args["contract_size"]?.doubleValue ?? 100.0

                let slDistance = abs(entry - sl)
                guard slDistance > 0 else {
                    throw JSONRPCError.invalidParams("`stop_loss` cannot equal `entry_price`.")
                }

                let monetaryRisk = balance * (riskPct / 100.0)
                let units = monetaryRisk / slDistance
                let lots = contractSize > 0 ? (units / contractSize) : 0
                let positionValue = units * entry
                let direction = entry > sl ? "long" : "short"

                var out: [String: JSONValue] = [
                    "account_balance": .number(balance),
                    "risk_pct": .number(riskPct),
                    "monetary_risk": .number(monetaryRisk),
                    "entry_price": .number(entry),
                    "stop_loss": .number(sl),
                    "sl_distance": .number(slDistance),
                    "direction": .string(direction),
                    "units": .number(units),
                    "lots": .number(lots),
                    "contract_size": .number(contractSize),
                    "position_value": .number(positionValue),
                ]

                if let tp = args["take_profit"]?.doubleValue {
                    let tpDistance = abs(tp - entry)
                    let rrRatio = tpDistance / slDistance
                    let potentialReward = monetaryRisk * rrRatio
                    out["take_profit"] = .number(tp)
                    out["tp_distance"] = .number(tpDistance)
                    out["rr_ratio"] = .number(rrRatio)
                    out["potential_reward"] = .number(potentialReward)
                } else {
                    out["take_profit"] = .null
                    out["tp_distance"] = .null
                    out["rr_ratio"] = .null
                    out["potential_reward"] = .null
                }

                return .object(out)
            }
        )
    }

    // MARK: - Argument parsing

    private struct SeriesRequest {
        let pairID: String
        let symbol: String
        let timeframe: Timeframe
        let candles: [Candle]
    }

    /// Resolve the symbol + timeframe + bar-count arguments shared by
    /// every tool and load the series.
    ///
    /// Reads a generous multiple of the requested window from disk before
    /// trimming: `dropClosedDays` removes weekend bars and folded
    /// timeframes consume several stored bars each, so asking SQLite for
    /// exactly `bars × interval` reliably comes back short.
    private func parseSeriesRequest(
        _ args: [String: JSONValue],
        defaultBars: Int,
        minBars: Int = 1,
        defaultTimeframe: Timeframe = .h1
    ) throws -> SeriesRequest {
        guard let symbolArg = args["symbol"]?.stringValue, !symbolArg.isEmpty else {
            throw JSONRPCError.invalidParams("`symbol` is required. Call list_symbols for valid ids.")
        }
        let needle = symbolArg.lowercased()
        guard let def = TradingPair.catalog.first(where: {
            $0.id.lowercased() == needle || $0.symbol.lowercased() == needle
        }) else {
            let known = TradingPair.catalog.map(\.id).joined(separator: ", ")
            throw JSONRPCError.invalidParams("Unknown symbol \"\(symbolArg)\". Known symbols: \(known).")
        }

        let tfArg = args["timeframe"]?.stringValue
        let timeframe: Timeframe
        if let tfArg {
            guard let tf = Timeframe(rawValue: tfArg) else {
                throw JSONRPCError.invalidParams(
                    "Unknown timeframe \"\(tfArg)\". Valid: \(Timeframe.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            timeframe = tf
        } else {
            timeframe = defaultTimeframe
        }

        let requested = args["bars"]?.intValue ?? defaultBars
        let bars = min(max(requested, minBars), maxBars)

        let until = Date()
        let since = until.addingTimeInterval(-timeframe.seconds * Double(bars) * 3)
        let loaded = OHLCCandleLoader.load(
            repo: repo,
            pairID: def.id,
            tf: timeframe,
            since: since,
            until: until,
            dropClosedDays: def.category != .crypto
        )
        guard !loaded.isEmpty else {
            throw JSONRPCError.invalidParams(
                "No stored \(timeframe.rawValue) history for \"\(def.id)\". Open the symbol in the Helix app once so it backfills, then retry."
            )
        }

        return SeriesRequest(
            pairID: def.id,
            symbol: def.symbol,
            timeframe: timeframe,
            candles: Array(loaded.suffix(bars))
        )
    }

    private struct HTFSeries {
        let timeframe: Timeframe?
        let candles: [Candle]
        let label: String
        let factor: Int
    }

    /// Load the bias timeframe: whatever `htf_timeframe` names, else one
    /// step up on the 4× ladder traders actually layer (15m → 1h → 4h).
    private func resolveHTF(
        _ args: [String: JSONValue],
        request: SeriesRequest,
        load: Bool
    ) throws -> HTFSeries {
        guard load else { return HTFSeries(timeframe: nil, candles: [], label: "", factor: 1) }

        let tf: Timeframe?
        if let named = args["htf_timeframe"]?.stringValue {
            guard let parsed = Timeframe(rawValue: named) else {
                throw JSONRPCError.invalidParams("Unknown htf_timeframe \"\(named)\".")
            }
            tf = parsed
        } else {
            tf = Self.higherTimeframe(above: request.timeframe)
        }
        guard let tf, tf.seconds > request.timeframe.seconds else {
            // Daily entry, or a caller that named a timeframe at or below
            // the entry one. No bias series — the evidence pack falls back
            // to its own read and reports the gap.
            return HTFSeries(timeframe: nil, candles: [], label: "", factor: 1)
        }

        let until = Date()
        let since = until.addingTimeInterval(-tf.seconds * 400 * 3)
        let candles = OHLCCandleLoader.load(
            repo: repo,
            pairID: request.pairID,
            tf: tf,
            since: since,
            until: until,
            dropClosedDays: TradingPair.catalog.first { $0.id == request.pairID }?.category != .crypto
        )
        return HTFSeries(
            timeframe: candles.isEmpty ? nil : tf,
            candles: Array(candles.suffix(400)),
            label: candles.isEmpty ? "" : tf.rawValue,
            factor: max(1, Int(tf.seconds / request.timeframe.seconds))
        )
    }

    /// Mirrors `AnalysisPage.higherTimeframe(above:)` — the 4× ladder.
    static func higherTimeframe(above tf: Timeframe) -> Timeframe? {
        switch tf {
        case .m1:  return .m15
        case .m5:  return .m30
        case .m15: return .h1
        case .m30: return .h4
        case .h1:  return .h4
        case .h4:  return .d1
        case .d1:  return nil
        }
    }
}
