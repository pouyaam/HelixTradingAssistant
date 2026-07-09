import Foundation
import Combine

/// Per-chart memoization of the expensive, *data-derived* arrays:
/// Heikin-Ashi display candles, indicator series, UT Bot output, Order
/// Block / FVG / Trading Session / NY Open Setup zones, and oscillator
/// points.
///
/// Why this exists: these all depend only on the candle data + indicator
/// settings — NOT on the visible window. During a pan/zoom only
/// `xDomain` changes, yet SwiftUI re-evaluates the chart body every
/// frame, which (without caching) re-runs every one of these O(n)
/// computations over the *entire* loaded history and throws the results
/// away. On deep history that's megabytes of transient allocations per
/// frame — the main-thread churn that makes panning feel laggy.
///
/// We key each result on a cheap signature of its inputs and only
/// recompute when that signature actually changes (data reload, the
/// 1 Hz live-tick trailing update, an indicator toggle, a settings
/// tweak). On a signature change we do NOT block `body` waiting for the
/// fresh value — Order Blocks / NY Open Setup / MACD etc. can take real
/// milliseconds on years of 1-minute history, and doing that inline on
/// the main thread is exactly what made the chart feel laggy. Instead
/// each indicator gets its own background `Task` (Swift's cooperative
/// thread pool — the structured-concurrency equivalent of "its own
/// thread", and genuinely concurrent across indicators since they land
/// on different pool threads): `body` reads the previous — possibly
/// stale — value immediately, and the view redraws once the task lands
/// and publishes the fresh one. The candles themselves always render
/// immediately; only the overlay/oscillator math trails behind by a
/// frame or two on a big recompute.
///
/// `@StateObject` in the owning view (`ChartView`, `OscillatorPanel`) so
/// it survives the view struct being re-created on each render AND so
/// `objectWillChange` (fired when a background task publishes a fresh
/// value) actually triggers a redraw.
@MainActor
final class ChartDerivedCache: ObservableObject {

    /// One async-memoized slot: `signature` is the last input we
    /// computed for, `value` is the most recent result (possibly
    /// stale while a fresh compute is in flight). Marked
    /// `@unchecked Sendable` because every mutation happens on
    /// `MainActor` (see `resolve`) — the class itself is never
    /// touched concurrently.
    private final class Slot<Sig: Equatable, Value>: @unchecked Sendable {
        var signature: Sig?
        var value: Value
        var task: Task<Void, Never>?
        init(_ initial: Value) { value = initial }
    }

    /// Coalescing flag for `objectWillChange`. Multiple resolve
    /// slots may complete in the same run-loop frame (e.g. all
    /// indicators recompute after a candle data reload). Without
    /// coalescing, each completion fires `objectWillChange.send()`
    /// independently, causing N full SwiftUI body re-evaluations
    /// for what is logically one data change. The flag + async
    /// dispatch collapses them into a single notification.
    private var publishScheduled = false

    private func coalescedObjectWillChange() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            self.objectWillChange.send()
        }
    }

    /// Shared concurrency limiter across all `ChartDerivedCache`
    /// instances. In grid mode, 4 panes × 12 indicator slots = 48
    /// `Task.detached` calls competing for the cooperative thread
    /// pool, which saturates every core on iPad. The limiter caps
    /// in-flight background tasks at `maxConcurrent`; excess work
    /// is queued and drains as slots open, keeping the main thread
    /// free so the UI stays responsive during layout switches.
    private static let maxConcurrent = 4
    private nonisolated(unsafe) static var inflightTasks = 0
    private static let inflightLock = NSLock()
    /// Pending work items waiting for a pool slot. Each is a closure
    /// that spawns the actual detached task — called from `release()`
    /// when a slot opens.
    private nonisolated(unsafe) static var pendingQueue: [() -> Void] = []

    /// Try to acquire a concurrency slot. Returns `true` if we can
    /// spawn a background task immediately; `false` if the pool is
    /// full (caller should enqueue instead).
    private nonisolated static func tryAcquire() -> Bool {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        guard inflightTasks < maxConcurrent else { return false }
        inflightTasks += 1
        return true
    }

    private nonisolated static func release() {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        inflightTasks -= 1
        // Drain one queued item if any are waiting.
        if !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            inflightTasks += 1
            // Run outside the lock to avoid deadlock.
            next()
        }
    }

    /// Enqueue work to run when a pool slot opens. The work closure
    /// is expected to spawn a `Task.detached` that calls `release()`
    /// when done.
    private nonisolated static func enqueue(_ work: @escaping () -> Void) {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        pendingQueue.append(work)
    }

    /// Fast path: `signature` unchanged ⇒ return the cached value
    /// synchronously (a couple of `Equatable` field comparisons — this
    /// is what keeps pan/zoom cheap). Slow path: `signature` changed ⇒
    /// cancel any in-flight recompute for this slot, kick off a new one
    /// on a background `Task`, and return the previous value right
    /// away so `body` never blocks. The task publishes its result via
    /// coalesced `objectWillChange` when it lands, which redraws the
    /// chart with the fresh data.
    ///
    /// `compute` must be a pure function over value types — every call
    /// site here is (candles, config) → derived array, so that always
    /// holds.
    private func resolve<Sig: Equatable, Value>(
        _ slot: Slot<Sig, Value>,
        signature: Sig,
        compute: @escaping @Sendable () -> Value
    ) -> Value {
        guard slot.signature != signature else { return slot.value }
        slot.task?.cancel()
        // Capture everything the detached task needs.
        let spawn: () -> Void = { [weak self] in
            slot.task = Task.detached(priority: .utility) {
                let fresh = compute()
                Self.release()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.coalescedObjectWillChange()
                    slot.value = fresh
                    slot.signature = signature
                }
            }
        }
        if Self.tryAcquire() {
            spawn()
        } else {
            Self.enqueue(spawn)
        }
        return slot.value
    }

    // ── Display candles (Heikin-Ashi + live-price patch) ──────────────
    //
    // Two-layer cache: the expensive HA transform is keyed on a
    // *structural* signature (bar count + first timestamp) so it only
    // recomputes when new bars arrive or the series is reloaded. The
    // cheap live-price patch on the last bar is applied on top every
    // call — it's an O(1) array-CoW copy, not a full O(n) transform.
    //
    // Previously the signature included `lastClose`/`lastTS`/`lastHigh`
    // /`lastLow`/`livePrice`, all of which change on every tick,
    // forcing the full HA recomputation ~10×/sec/pane — the primary
    // source of grid lag.

    /// Structural signature for the base HA transform. Only changes
    /// when the candle array's shape changes (new bars, pair/timeframe
    /// switch, full reload) — NOT on a trailing live-price update.
    private struct BaseDisplaySig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let heikinAshi: Bool
    }
    private var baseDisplaySig: BaseDisplaySig?
    private var baseDisplayCache: [Candle] = []

    /// The cached base (possibly HA-transformed) candles before the
    /// live-price overlay. Only recomputes on structural changes.
    private func baseDisplayCandles(candles: [Candle], heikinAshi: Bool) -> [Candle] {
        let sig = BaseDisplaySig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            heikinAshi: heikinAshi
        )
        if sig == baseDisplaySig { return baseDisplayCache }
        let result = heikinAshi ? HeikinAshi.transform(candles) : candles
        baseDisplaySig = sig
        baseDisplayCache = result
        return result
    }

    /// Key for the live-price-patched cache: the base's structural
    /// signature plus the patched-in live price. When both are unchanged
    /// the patched array can be returned as-is.
    private struct PatchedSig: Equatable {
        let base: BaseDisplaySig
        let live: Double
    }
    private var patchedSig: PatchedSig?
    private var patchedCache: [Candle] = []

    /// Candles actually drawn: HA-transformed when requested, with the
    /// in-progress (last) bar patched to the live price.
    ///
    /// The patched array is MEMOIZED. `ChartViewiPad` reads the
    /// `displayCandles` computed property ~13× per render (candle marks,
    /// line marks, UT Bot, hover, auto-Y-domain…), and patching mutates one
    /// element of the cached base array — which, because the cache still
    /// holds a reference, forces a full O(n) copy-on-write EVERY call. On
    /// deep history that was ~13 full-array copies (tens of MB of
    /// allocation) per frame, i.e. the dominant pan/zoom CPU cost. Keying
    /// on (base signature + live price) collapses it to one rebuild per
    /// tick, with every other read hitting the cache.
    func displayCandles(candles: [Candle], heikinAshi: Bool, livePrice: Double?) -> [Candle] {
        let base = baseDisplayCandles(candles: candles, heikinAshi: heikinAshi)
        guard let live = livePrice, let b = base.last, b.close != 0,
              abs(live - b.close) / b.close < 0.10 else { return base }
        if let sig = patchedSig, let baseSig = baseDisplaySig,
           sig.base == baseSig, sig.live == live {
            return patchedCache
        }
        var patched = base
        patched[patched.count - 1] = Candle(
            id: b.id,
            open: b.open,
            high: max(b.high, live),
            low: min(b.low, live),
            close: live,
            volume: b.volume
        )
        if let baseSig = baseDisplaySig {
            patchedSig = PatchedSig(base: baseSig, live: live)
            patchedCache = patched
        }
        return patched
    }

    // ── Indicators (SMA / EMA / Bollinger) ────────────────────────────

    /// Stable identity for one instance's *computation* — kind + params +
    /// hidden, deliberately WITHOUT the random `id`. `ChartViewiPad`
    /// rebuilds `IndicatorInstance(kind:)` from a `Set<IndicatorKind>` on
    /// every render, minting a fresh UUID each time. Keying the cache on the
    /// full instance (id included) meant the signature never matched twice,
    /// so the background recompute was cancelled and restarted forever —
    /// and, because there are two call sites per render (indicatorMarks +
    /// autoYDomain) each with different fresh UUIDs, the second call kept
    /// cancelling the first's in-flight task before it could land. Net
    /// effect: the line indicators (SMA/EMA/Bollinger) never computed, so
    /// they never drew. Keying on the compute-relevant fields fixes the
    /// draw AND stops the perpetual recompute. (iPad indicator fix.)
    private struct IndicatorKey: Equatable {
        let kind: IndicatorKind
        let params: [String: ParamValue]
        let hidden: Bool
    }
    private struct IndicatorSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let instances: [IndicatorKey]
    }
    private let indicatorSlot = Slot<IndicatorSig, [(instance: IndicatorInstance, points: [IndicatorPoint])]>([])

    func indicators(instances: [IndicatorInstance], candles: [Candle])
        -> [(instance: IndicatorInstance, points: [IndicatorPoint])]
    {
        let sig = IndicatorSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            instances: instances.map { IndicatorKey(kind: $0.kind, params: $0.params, hidden: $0.hidden) }
        )
        return resolve(indicatorSlot, signature: sig) {
            Indicators.compute(instances: instances, candles: candles)
        }
    }

    // ── UT Bot ────────────────────────────────────────────────────────

    private struct UTSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let keyValue: Double
        let atrPeriod: Int
        let useHeikinAshi: Bool
    }
    private let utSlot = Slot<UTSig, UTBot.Output>(UTBot.Output(trailingStop: [], positions: [], signals: []))

    func utBot(candles: [Candle], keyValue: Double, atrPeriod: Int, useHeikinAshi: Bool) -> UTBot.Output {
        let sig = UTSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            keyValue: keyValue,
            atrPeriod: atrPeriod,
            useHeikinAshi: useHeikinAshi
        )
        return resolve(utSlot, signature: sig) {
            UTBot.compute(candles, keyValue: keyValue, atrPeriod: atrPeriod, useHeikinAshi: useHeikinAshi)
        }
    }

    // ── Order Blocks ────────────────────────────────────────────────

    private struct OBSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let periods: Int
        let threshold: Double
        let useWicks: Bool
        let detectSteroids: Bool
    }
    private let obSlot = Slot<OBSig, [OrderBlocks.Zone]>([])

    func orderBlocks(
        candles: [Candle],
        periods: Int,
        threshold: Double,
        useWicks: Bool,
        detectSteroids: Bool
    ) -> [OrderBlocks.Zone] {
        let sig = OBSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            periods: periods,
            threshold: threshold,
            useWicks: useWicks,
            detectSteroids: detectSteroids
        )
        return resolve(obSlot, signature: sig) {
            OrderBlocks.compute(
                candles,
                periods: periods,
                threshold: threshold,
                useWicks: useWicks,
                detectSteroids: detectSteroids
            )
        }
    }

    // ── Steroid Order Blocks ─────────────────────────────────────────

    private struct SteroidOBSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let periods: Int
        let threshold: Double
        let useWicks: Bool
        let volumeMultiplier: Double
        let detectSteroids: Bool
    }
    private let sobSlot = Slot<SteroidOBSig, [SteroidOrderBlocks.Zone]>([])

    func steroidOrderBlocks(
        candles: [Candle],
        periods: Int,
        threshold: Double,
        useWicks: Bool,
        volumeMultiplier: Double,
        detectSteroids: Bool
    ) -> [SteroidOrderBlocks.Zone] {
        let sig = SteroidOBSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            periods: periods,
            threshold: threshold,
            useWicks: useWicks,
            volumeMultiplier: volumeMultiplier,
            detectSteroids: detectSteroids
        )
        return resolve(sobSlot, signature: sig) {
            SteroidOrderBlocks.compute(
                candles,
                periods: periods,
                threshold: threshold,
                useWicks: useWicks,
                detectSteroids: detectSteroids,
                volumeMultiplier: volumeMultiplier
            )
        }
    }

    // ── Fair Value Gap ────────────────────────────────────────────────

    private struct FVGSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let threshold: Double
    }
    private let fvgSlot = Slot<FVGSig, [FairValueGap.Zone]>([])

    func fairValueGaps(candles: [Candle], threshold: Double) -> [FairValueGap.Zone] {
        let sig = FVGSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            threshold: threshold
        )
        return resolve(fvgSlot, signature: sig) {
            FairValueGap.compute(candles, threshold: threshold)
        }
    }

    // ── FVG→OB ──────────────────────────────────────────────────────

    private struct FVGFirstOBSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let fvgThreshold: Double
        let searchMin: Int
        let searchMax: Int
        let detectVolume: Bool
        let volumeMultiplier: Double
    }
    private let fvgFirstOBSlot = Slot<FVGFirstOBSig, [FVGFirstOB.Zone]>([])

    func fvgFirstOB(
        candles: [Candle], fvgThreshold: Double,
        searchMin: Int, searchMax: Int,
        detectVolume: Bool, volumeMultiplier: Double
    ) -> [FVGFirstOB.Zone] {
        let sig = FVGFirstOBSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            fvgThreshold: fvgThreshold,
            searchMin: searchMin, searchMax: searchMax,
            detectVolume: detectVolume, volumeMultiplier: volumeMultiplier
        )
        return resolve(fvgFirstOBSlot, signature: sig) {
            FVGFirstOB.compute(
                candles, fvgThreshold: fvgThreshold,
                searchMin: searchMin, searchMax: searchMax,
                detectVolume: detectVolume, volumeMultiplier: volumeMultiplier
            )
        }
    }

    // ── Sonarlab Order Blocks ─────────────────────────────────────

    private struct SonarlabOBSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let sensitivity: Double
        let mitigationType: String
    }
    private let sonarlabOBSlot = Slot<SonarlabOBSig, [SonarlabOrderBlocks.Zone]>([])

    func sonarlabOrderBlocks(
        candles: [Candle],
        sensitivity: Double,
        mitigationType: SonarlabOrderBlocks.MitigationType
    ) -> [SonarlabOrderBlocks.Zone] {
        let sig = SonarlabOBSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            sensitivity: sensitivity,
            mitigationType: mitigationType.rawValue
        )
        return resolve(sonarlabOBSlot, signature: sig) {
            SonarlabOrderBlocks.compute(
                candles,
                sensitivity: sensitivity,
                mitigationType: mitigationType
            )
        }
    }

    // ── Volume Profile ─────────────────────────────────────────────────

    private struct VPSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let bucketCount: Int
        let valueAreaPct: Double
    }
    private let vpSlot = Slot<VPSig, [VolumeProfile.SessionVP]>([])

    func volumeProfile(candles: [Candle], bucketCount: Int, valueAreaPct: Double) -> [VolumeProfile.SessionVP] {
        let sig = VPSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            bucketCount: bucketCount,
            valueAreaPct: valueAreaPct
        )
        return resolve(vpSlot, signature: sig) {
            VolumeProfile.compute(candles, bucketCount: bucketCount, valueAreaPct: valueAreaPct)
        }
    }

    // ── ZigZag-based Volume Profile (last trend segment) ───────────────

    private struct ZigzagVPSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let bucketCount: Int
        let valueAreaPct: Double
        let zzDepth: Int
        let zzMinChange: Double
    }
    private let zigzagVPSlot = Slot<ZigzagVPSig, VolumeProfile.TrendVP?>(nil)

    func zigzagVolumeProfile(
        candles: [Candle],
        bucketCount: Int,
        valueAreaPct: Double,
        zzDepth: Int,
        zzMinChange: Double
    ) -> VolumeProfile.TrendVP? {
        let sig = ZigzagVPSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            bucketCount: bucketCount,
            valueAreaPct: valueAreaPct,
            zzDepth: zzDepth,
            zzMinChange: zzMinChange
        )
        return resolve(zigzagVPSlot, signature: sig) {
            VolumeProfile.computeLastTrend(
                candles,
                bucketCount: bucketCount,
                valueAreaPct: valueAreaPct,
                zigzagDepth: zzDepth,
                zigzagMinChange: zzMinChange
            )
        }
    }

    // ── ZigZag pivots (for rendering the zigzag line overlay) ──────────

    private struct ZigzagLineSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let depth: Int
        let minChange: Double
    }
    private let zigzagLineSlot = Slot<ZigzagLineSig, [ZigZag.Pivot]>([])

    func zigzagPivots(candles: [Candle], depth: Int, minChange: Double) -> [ZigZag.Pivot] {
        let sig = ZigzagLineSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            depth: depth,
            minChange: minChange
        )
        return resolve(zigzagLineSlot, signature: sig) {
            ZigZag.compute(candles, depth: depth, minChangePct: minChange)
        }
    }

    // ── Trading Sessions ──────────────────────────────────────────────

    private struct SessionSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
    }
    private let sessionSlot = Slot<SessionSig, [TradingSessions.SessionRun]>([])

    /// Memoized session runs over the full catalog. Depends only on the
    /// candle data — *which* presets are shown (and which lines draw) is
    /// applied at render time, so toggling a session on/off never busts
    /// this cache.
    func tradingSessions(candles: [Candle]) -> [TradingSessions.SessionRun] {
        let sig = SessionSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0
        )
        return resolve(sessionSlot, signature: sig) {
            TradingSessions.compute(candles)
        }
    }

    // ── NY Open Setup ─────────────────────────────────────────────────

    private struct NYSetupSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastHigh: Double
        let lastLow: Double
        let atrMult: Double
        let amOnly: Bool
    }
    private let nySetupSlot = Slot<NYSetupSig, [NYOpenSetup.Result]>([])

    /// Memoized NY Open Setup detection. Folds the last bar's high/low
    /// into the signature (not just close) so the live in-progress bar
    /// pushing through entry/SL/TP re-runs detection — the setup's stage
    /// can change intrabar.
    func nyOpenSetup(candles: [Candle], atrMult: Double, amOnly: Bool) -> [NYOpenSetup.Result] {
        let last = candles.last
        let sig = NYSetupSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastHigh: last?.high ?? 0,
            lastLow: last?.low ?? 0,
            atrMult: atrMult,
            amOnly: amOnly
        )
        return resolve(nySetupSlot, signature: sig) {
            NYOpenSetup.compute(candles, atrMultiple: atrMult, amOnly: amOnly)
        }
    }

    // ── Oscillator points (RSI / MACD / Stochastic) ───────────────────
    //
    // Each `OscillatorPanel` owns its own `ChartDerivedCache` instance
    // scoped to a single `OscillatorKind`, so this slot is never
    // multiplexed across kinds within one cache — safe to key on the
    // scalar config fields alone.

    private struct OscSig: Equatable {
        let kind: OscillatorKind
        let count: Int
        let firstTS: TimeInterval
        let rsiPeriod: Int
        let macdFast: Int
        let macdSlow: Int
        let macdSignal: Int
        let stochK: Int
        let stochD: Int
    }
    private let oscSlot = Slot<OscSig, [IndicatorPoint]>([])

    func oscillatorPoints(kind: OscillatorKind, candles: [Candle], config: OscillatorConfig) -> [IndicatorPoint] {
        let sig = OscSig(
            kind: kind,
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            rsiPeriod: config.rsiPeriod,
            macdFast: config.macdFast,
            macdSlow: config.macdSlow,
            macdSignal: config.macdSignal,
            stochK: config.stochK,
            stochD: config.stochD
        )
        return resolve(oscSlot, signature: sig) {
            switch kind {
            case .rsi:
                return Oscillators.rsi(candles, period: config.rsiPeriod)
            case .macd:
                return Oscillators.macd(candles, fast: config.macdFast,
                                         slow: config.macdSlow, signal: config.macdSignal)
            case .stochastic:
                return Oscillators.stochastic(candles, kPeriod: config.stochK, dPeriod: config.stochD)
            }
        }
    }

    // ── Overlay Y extremes (S/R, FVG, OB, drawings, trades, etc.) ──
    //
    // The `autoYDomain` computed property in ChartView needs to fold
    // every overlay's price extremes into the Y axis so nothing clips
    // off-screen. Most overlays don't depend on the visible window —
    // they're global arrays that only change on data reload or AI
    // result arrival. Scanning them on every pan/zoom frame was a
    // primary source of lag. Here we cache the min/max across all
    // such overlays; the per-frame work reduces to just the visible
    // candle + indicator point scan. (Pan/zoom Performance Fix.)

    /// A generic overlay zone with just price bounds.
    struct OverlayBounds {
        let low: Double
        let high: Double
    }

    /// A generic point with a price value.
    struct PricePoint {
        let price: Double
    }

    private struct OverlayYExtremesSig: Equatable {
        // S/R levels — count + boundary values
        let srSupportCount: Int
        let srResistanceCount: Int
        let srMin: Double
        let srMax: Double
        // Overlay zone bounds (all zones merged — counts tracked via
        // the bounds themselves changing)
        let zoneCount: Int
        let zoneMin: Double
        let zoneMax: Double
        // Scenarios
        let scenarioEntry: Double?
        let scenarioTP: Double
        let scenarioSL: Double
        let altScenarioEntry: Double?
        let altScenarioTP: Double
        let altScenarioSL: Double
        // Drawings
        let drawingCount: Int
        let drawingMin: Double
        let drawingMax: Double
        // Trades
        let tradeCount: Int
        let tradeMin: Double
        let tradeMax: Double
        // Journal entries
        let journalCount: Int
        let journalMin: Double
        let journalMax: Double
    }

    private let overlayYExtremesSlot = Slot<OverlayYExtremesSig, (lo: Double, hi: Double)?>((lo: Double.greatestFiniteMagnitude, hi: -Double.greatestFiniteMagnitude))

    /// Cached min/max price across all overlays that don't depend on
    /// the visible window. Returns nil when there are no overlays.
    func overlayYExtremes(
        srLevels: PromptBuilder.SRLevels,
        overlayZones: [OverlayBounds],
        scenario: (entry: Double?, takeProfit: Double, stopLoss: Double)?,
        altScenario: (entry: Double?, takeProfit: Double, stopLoss: Double)?,
        drawings: [PricePoint],
        trades: [PricePoint],
        journalEntries: [PricePoint]
    ) -> (lo: Double, hi: Double)? {
        let allSR = srLevels.support + srLevels.resistance

        let sig = OverlayYExtremesSig(
            srSupportCount: srLevels.support.count,
            srResistanceCount: srLevels.resistance.count,
            srMin: allSR.min() ?? 0,
            srMax: allSR.max() ?? 0,
            zoneCount: overlayZones.count,
            zoneMin: overlayZones.map(\.low).min() ?? 0,
            zoneMax: overlayZones.map(\.high).max() ?? 0,
            scenarioEntry: scenario?.entry,
            scenarioTP: scenario?.takeProfit ?? 0,
            scenarioSL: scenario?.stopLoss ?? 0,
            altScenarioEntry: altScenario?.entry,
            altScenarioTP: altScenario?.takeProfit ?? 0,
            altScenarioSL: altScenario?.stopLoss ?? 0,
            drawingCount: drawings.count,
            drawingMin: drawings.map(\.price).min() ?? 0,
            drawingMax: drawings.map(\.price).max() ?? 0,
            tradeCount: trades.count,
            tradeMin: trades.map(\.price).min() ?? 0,
            tradeMax: trades.map(\.price).max() ?? 0,
            journalCount: journalEntries.count,
            journalMin: journalEntries.map(\.price).min() ?? 0,
            journalMax: journalEntries.map(\.price).max() ?? 0
        )
        return resolve(overlayYExtremesSlot, signature: sig) {
            var lo = Double.greatestFiniteMagnitude
            var hi = -Double.greatestFiniteMagnitude
            for v in allSR {
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
            for zone in overlayZones {
                if zone.low  < lo { lo = zone.low }
                if zone.high > hi { hi = zone.high }
            }
            if let scenario {
                for v in [scenario.takeProfit, scenario.stopLoss] + [scenario.entry].compactMap({ $0 }) {
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            if let altScenario {
                for v in [altScenario.takeProfit, altScenario.stopLoss] + [altScenario.entry].compactMap({ $0 }) {
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            for p in drawings {
                if p.price < lo { lo = p.price }
                if p.price > hi { hi = p.price }
            }
            for p in trades {
                if p.price < lo { lo = p.price }
                if p.price > hi { hi = p.price }
            }
            for p in journalEntries {
                if p.price < lo { lo = p.price }
                if p.price > hi { hi = p.price }
            }
            guard lo <= hi else { return nil }
            return (lo, hi)
        }
    }
}
