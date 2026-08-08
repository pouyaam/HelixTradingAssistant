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

        // Always compute on a background `Task` — including the FIRST time
        // for a slot. The old fast-path computed the initial value inline
        // on the main thread "so the indicator appears immediately", but
        // that's exactly what hitches the UI when the multi-chart grid
        // mounts: every new pane's every indicator/order-block/… computes
        // synchronously over full history, on the main thread, for 2–4
        // panes at once. Deferring it a frame (the chart draws candles
        // now, overlays land a beat later) keeps the split-screen switch
        // smooth. The concurrency limiter (`maxConcurrent`) still caps how
        // many run at once so the pool doesn't saturate.
        //
        // Set `signature` OPTIMISTICALLY here, before the task runs, rather
        // than on completion. Otherwise every re-render before the compute
        // lands would see an unchanged (stale) `slot.signature`, decide the
        // work is still pending, and cancel + re-spawn — a perpetual
        // recompute that never finishes when renders outpace the compute.
        // A genuinely newer signature still differs from this one, so it
        // correctly cancels and supersedes.
        slot.signature = signature
        let spawn: () -> Void = { [weak self] in
            slot.task = Task.detached(priority: .userInitiated) {
                let fresh = compute()
                Self.release()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    // A superseding recompute may have raced ahead while
                    // this one was queued (queued spawns can't be
                    // cancelled before they start). Only publish if this
                    // result is still for the wanted signature, so a stale
                    // compute can never clobber a fresher value.
                    guard slot.signature == signature else { return }
                    slot.value = fresh
                    self.coalescedObjectWillChange()
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
        let chartType: ChartType
        let renkoConfig: RenkoConfig?
    }
    private var baseDisplaySig: BaseDisplaySig?
    private var baseDisplayCache: [Candle] = []

    /// The cached base (possibly HA or Renko transformed) candles before the
    /// live-price overlay. Only recomputes on structural changes.
    private func baseDisplayCandles(candles: [Candle], chartType: ChartType, renkoConfig: RenkoConfig = .default) -> [Candle] {
        let sig = BaseDisplaySig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            chartType: chartType,
            renkoConfig: chartType == .renko ? renkoConfig : nil
        )
        if sig == baseDisplaySig { return baseDisplayCache }
        let result: [Candle]
        switch chartType {
        case .line, .candle:
            result = candles
        case .heikinAshi:
            result = HeikinAshi.transform(candles)
        case .renko:
            result = Renko.transform(candles, config: renkoConfig)
        }
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

    /// Candles actually drawn: HA/Renko-transformed when requested, with the
    /// in-progress (last) bar patched to the live price.
    func displayCandles(candles: [Candle], chartType: ChartType, renkoConfig: RenkoConfig = .default, livePrice: Double?) -> [Candle] {
        let base = baseDisplayCandles(candles: candles, chartType: chartType, renkoConfig: renkoConfig)
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

    func displayCandles(candles: [Candle], heikinAshi: Bool, livePrice: Double?) -> [Candle] {
        displayCandles(candles: candles, chartType: heikinAshi ? .heikinAshi : .candle, renkoConfig: .default, livePrice: livePrice)
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

    // ── Enhanced Sonarlab Order Blocks ─────────────────────────────

    private struct EnhancedSonarlabOBSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let sensitivity: Double
        let mitigationType: String
        let requireVolumeSpike: Bool
        let minVolumeMult: Double
        let minDisplacementATR: Double
        let requireFVG: Bool
        let trendFilter: String
        let minGradeFilter: String
        let maxZones: Int
    }
    private let enhancedSonarlabOBSlot = Slot<EnhancedSonarlabOBSig, [EnhancedSonarlabOrderBlocks.Zone]>([])

    func enhancedSonarlabOrderBlocks(
        candles: [Candle],
        sensitivity: Double,
        mitigationType: EnhancedSonarlabOrderBlocks.MitigationType,
        requireVolumeSpike: Bool,
        minVolumeMult: Double,
        minDisplacementATR: Double,
        requireFVG: Bool,
        trendFilter: String,
        minGradeFilter: String,
        maxZones: Int
    ) -> [EnhancedSonarlabOrderBlocks.Zone] {
        let sig = EnhancedSonarlabOBSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            sensitivity: sensitivity,
            mitigationType: mitigationType.rawValue,
            requireVolumeSpike: requireVolumeSpike,
            minVolumeMult: minVolumeMult,
            minDisplacementATR: minDisplacementATR,
            requireFVG: requireFVG,
            trendFilter: trendFilter,
            minGradeFilter: minGradeFilter,
            maxZones: maxZones
        )
        return resolve(enhancedSonarlabOBSlot, signature: sig) {
            EnhancedSonarlabOrderBlocks.compute(
                candles,
                sensitivity: sensitivity,
                mitigationType: mitigationType,
                requireVolumeSpike: requireVolumeSpike,
                minVolumeMult: minVolumeMult,
                minDisplacementATR: minDisplacementATR,
                requireFVG: requireFVG,
                trendFilter: trendFilter,
                minGradeFilter: minGradeFilter,
                maxZones: maxZones
            )
        }
    }

    // ── Ranked Order Blocks (swing + VP + Ichimoku) ────────────────

    private struct RankedOBSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastClose: Double
        let config: RankedOrderBlocks.Config
    }
    private let rankedOBSlot = Slot<RankedOBSig, [RankedOrderBlocks.Zone]>([])

    func rankedOrderBlocks(
        candles: [Candle],
        config: RankedOrderBlocks.Config
    ) -> [RankedOrderBlocks.Zone] {
        let sig = RankedOBSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastClose: candles.last?.close ?? 0,
            config: config
        )
        return resolve(rankedOBSlot, signature: sig) {
            RankedOrderBlocks.compute(candles, config: config)
        }
    }

    // ── Ranked OB strategy (entry / SL / TP plans) ─────────────────

    private struct RankedOBStrategySig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastClose: Double
        /// Zone identities + geometry. The plans are derived from these,
        /// so a re-grade that leaves every zone where it was must not
        /// invalidate the slot.
        let zoneKeys: [String]
        let config: RankedOBStrategy.Config
    }
    private let rankedOBStrategySlot = Slot<RankedOBStrategySig, [RankedOBStrategy.Setup]>([])

    func rankedOBStrategy(
        candles: [Candle],
        zones: [RankedOrderBlocks.Zone],
        config: RankedOBStrategy.Config
    ) -> [RankedOBStrategy.Setup] {
        guard config.enabled else { return [] }
        let sig = RankedOBStrategySig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastClose: candles.last?.close ?? 0,
            zoneKeys: zones.map { "\($0.id)|\($0.top)|\($0.bottom)|\($0.grade.rawValue)" },
            config: config
        )
        return resolve(rankedOBStrategySlot, signature: sig) {
            RankedOBStrategy.compute(candles, zones: zones, config: config)
        }
    }

    // ── Volume-Ranked Order Blocks (Volume + Volume Profile) ───────────

    private struct VolumeRankedOBSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastClose: Double
        let config: VolumeRankedOrderBlocks.Config
    }
    private let volumeRankedOBSlot = Slot<VolumeRankedOBSig, [VolumeRankedOrderBlocks.Zone]>([])

    func volumeRankedOrderBlocks(
        candles: [Candle],
        config: VolumeRankedOrderBlocks.Config
    ) -> [VolumeRankedOrderBlocks.Zone] {
        let sig = VolumeRankedOBSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastClose: candles.last?.close ?? 0,
            config: config
        )
        return resolve(volumeRankedOBSlot, signature: sig) {
            VolumeRankedOrderBlocks.compute(candles, config: config)
        }
    }

    // ── Change of Character (CHoCH + OB/FVG confluence) ────────────────

    private struct CHoCHSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastClose: Double
        let swingLength: Int
        let minSwingPct: Double
        let requireFVG: Bool
        let showMitigated: Bool
    }
    private let chochSlot = Slot<CHoCHSig, [ChangeOfCharacter.Zone]>([])

    /// Memoized CHoCH detection. Folds the last bar's close into the
    /// signature so the live in-progress bar closing beyond a protected
    /// swing (i.e. a CHoCH forming right now) re-runs detection.
    func changeOfCharacter(
        candles: [Candle],
        swingLength: Int,
        minSwingPct: Double,
        requireFVG: Bool,
        showMitigated: Bool
    ) -> [ChangeOfCharacter.Zone] {
        let sig = CHoCHSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastClose: candles.last?.close ?? 0,
            swingLength: swingLength,
            minSwingPct: minSwingPct,
            requireFVG: requireFVG,
            showMitigated: showMitigated
        )
        return resolve(chochSlot, signature: sig) {
            ChangeOfCharacter.compute(
                candles,
                swingLength: swingLength,
                minSwingPct: minSwingPct,
                requireFVG: requireFVG,
                showMitigated: showMitigated
            )
        }
    }

    // ── Ichimoku Cloud ─────────────────────────────────────────────────

    private struct IchimokuSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastClose: Double
        let tenkan: Int
        let kijun: Int
        let senkouB: Int
        let displacement: Int
    }
    private let ichimokuSlot = Slot<IchimokuSig, Ichimoku.Output>(.empty)

    func ichimoku(
        candles: [Candle],
        tenkan: Int,
        kijun: Int,
        senkouB: Int,
        displacement: Int
    ) -> Ichimoku.Output {
        let sig = IchimokuSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastClose: candles.last?.close ?? 0,
            tenkan: tenkan,
            kijun: kijun,
            senkouB: senkouB,
            displacement: displacement
        )
        return resolve(ichimokuSlot, signature: sig) {
            Ichimoku.compute(
                candles,
                tenkan: tenkan,
                kijun: kijun,
                senkouB: senkouB,
                displacement: displacement
            )
        }
    }

    // ── Ichimoku-confluence Order Blocks ───────────────────────────────

    private struct IchimokuOBSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let periods: Int
        let threshold: Double
        let useWicks: Bool
        let tenkan: Int
        let kijun: Int
        let senkouB: Int
        let displacement: Int
        let minScore: Int
        let requireTrend: Bool
    }
    private let ichimokuOBSlot = Slot<IchimokuOBSig, [IchimokuOrderBlocks.Zone]>([])

    func ichimokuOrderBlocks(
        candles: [Candle],
        periods: Int,
        threshold: Double,
        useWicks: Bool,
        tenkan: Int,
        kijun: Int,
        senkouB: Int,
        displacement: Int,
        minScore: Int,
        requireTrend: Bool
    ) -> [IchimokuOrderBlocks.Zone] {
        let sig = IchimokuOBSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            periods: periods,
            threshold: threshold,
            useWicks: useWicks,
            tenkan: tenkan,
            kijun: kijun,
            senkouB: senkouB,
            displacement: displacement,
            minScore: minScore,
            requireTrend: requireTrend
        )
        return resolve(ichimokuOBSlot, signature: sig) {
            IchimokuOrderBlocks.compute(
                candles,
                periods: periods,
                threshold: threshold,
                useWicks: useWicks,
                tenkan: tenkan,
                kijun: kijun,
                senkouB: senkouB,
                displacement: displacement,
                minScore: minScore,
                requireTrendAgreement: requireTrend
            )
        }
    }

    // ── Volume-Filtered Order Blocks ───────────────────────────────────

    private struct VFOBSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let lastClose: Double
        let lastHigh: Double
        let lastLow: Double
        let lastVolume: Double
        let swingLength: Int
        let invalidationWick: Bool
        let maxZonesPerSide: Int
        let showHistoric: Bool
        let combine: Bool
    }
    private let vfobSlot = Slot<VFOBSig, VolumeFilteredOrderBlocks.Output>(.empty)

    func volumeFilteredOrderBlocks(
        candles: [Candle],
        swingLength: Int,
        invalidationWick: Bool,
        maxZonesPerSide: Int,
        showHistoric: Bool,
        combine: Bool
    ) -> VolumeFilteredOrderBlocks.Output {
        let last = candles.last
        let sig = VFOBSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: last?.id.timeIntervalSince1970 ?? 0,
            lastClose: last?.close ?? 0,
            lastHigh: last?.high ?? 0,
            lastLow: last?.low ?? 0,
            lastVolume: last?.volume ?? 0,
            swingLength: swingLength,
            invalidationWick: invalidationWick,
            maxZonesPerSide: maxZonesPerSide,
            showHistoric: showHistoric,
            combine: combine
        )
        return resolve(vfobSlot, signature: sig) {
            VolumeFilteredOrderBlocks.compute(
                candles,
                swingLength: swingLength,
                invalidationWick: invalidationWick,
                maxZonesPerSide: maxZonesPerSide,
                showHistoric: showHistoric,
                combine: combine
            )
        }
    }

    private struct HelixOBComboSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let lastClose: Double
        let lastHigh: Double
        let lastLow: Double
        let lastVolume: Double
        let params: [String: ParamValue]
    }
    private let helixOBComboSlot = Slot<HelixOBComboSig, HelixOBCombo.Output>(.empty)

    func helixOBCombo(candles: [Candle], params: [String: ParamValue]) -> HelixOBCombo.Output {
        let last = candles.last
        let sig = HelixOBComboSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: last?.id.timeIntervalSince1970 ?? 0,
            lastClose: last?.close ?? 0,
            lastHigh: last?.high ?? 0,
            lastLow: last?.low ?? 0,
            lastVolume: last?.volume ?? 0,
            params: params
        )
        return resolve(helixOBComboSlot, signature: sig) {
            HelixOBCombo.compute(candles, params: params)
        }
    }

    /// Keyed on bar identity + inputs only. The previous day is by definition
    /// settled, so nothing about it can change until a *new* bar arrives —
    /// re-deriving it on every live tick would be pure waste.
    private struct PreviousDayVPSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let bucketCount: Int
        let valueAreaPct: Double
    }
    private let previousDayVPSlot = Slot<PreviousDayVPSig, VolumeProfile.PreviousDayVP?>(nil)

    func previousDayVP(
        candles: [Candle],
        bucketCount: Int,
        valueAreaPct: Double
    ) -> VolumeProfile.PreviousDayVP? {
        let sig = PreviousDayVPSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: candles.last?.id.timeIntervalSince1970 ?? 0,
            bucketCount: bucketCount,
            valueAreaPct: valueAreaPct
        )
        return resolve(previousDayVPSlot, signature: sig) {
            VolumeProfile.computePreviousDay(
                candles,
                bucketCount: bucketCount,
                valueAreaPct: valueAreaPct
            )
        }
    }

    /// Deliberately keyed on bar *identity* only — no trailing OHLC, unlike
    /// e.g. `RankedOBSig`. This is the heaviest structural pass in the app
    /// (~28 ms over 3k bars, on the main thread during view update), and
    /// including the live bar's close/high/low made every 1 Hz tick rewrite of
    /// the trailing bar recompute the whole series. The other structural zone
    /// engines (`OBSig`, `SonarlabOBSig`, `EnhancedSonarlabOBSig`) already key
    /// on count + firstTS for exactly this reason. The visible effect is that
    /// BOS/CHoCH confirm on bar close rather than intra-bar, which is how the
    /// Pine script's own structure rules read anyway.
    private struct AlgoSmartAssistSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let params: [String: ParamValue]
    }
    private let algoSmartAssistSlot = Slot<AlgoSmartAssistSig, AlgoSmartAssist.Output>(.empty)

    func algoSmartAssist(candles: [Candle], params: [String: ParamValue]) -> AlgoSmartAssist.Output {
        let last = candles.last
        let sig = AlgoSmartAssistSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: last?.id.timeIntervalSince1970 ?? 0,
            params: params
        )
        return resolve(algoSmartAssistSlot, signature: sig) {
            AlgoSmartAssist.calculate(candles: candles, params: params)
        }
    }

    /// AMD phase cycles. Keyed on bar identity plus the trailing bar's
    /// OHLC: unlike the pure structure engines, a live tick genuinely
    /// changes this output — the current bar can extend a sweep, fill an
    /// entry gap, or hit a target, and all three should show up without
    /// waiting for the bar to close.
    private struct AMDSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let lastHigh: Double
        let lastLow: Double
        let lastClose: Double
        let config: AMDCycle.Configuration
    }
    private let amdSlot = Slot<AMDSig, [AMDCycle.Cycle]>([])

    func amdCycles(candles: [Candle], config: AMDCycle.Configuration) -> [AMDCycle.Cycle] {
        let last = candles.last
        let sig = AMDSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: last?.id.timeIntervalSince1970 ?? 0,
            lastHigh: last?.high ?? 0,
            lastLow: last?.low ?? 0,
            lastClose: last?.close ?? 0,
            config: config
        )
        return resolve(amdSlot, signature: sig) {
            AMDCycle.compute(candles, configuration: config)
        }
    }

    // ── Volume Profile ─────────────────────────────────────────────────

    /// Includes the trailing bar's timestamp/close/volume so the 1 Hz
    /// live tick (which rewrites the last bar in place, leaving `count`
    /// unchanged) still invalidates the cache — otherwise the profile
    /// freezes for the whole live session.
    private struct VPSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let lastClose: Double
        let lastVolume: Double
        let bucketCount: Int
        let valueAreaPct: Double
    }
    private let vpSlot = Slot<VPSig, [VolumeProfile.SessionVP]>([])

    func volumeProfile(candles: [Candle], bucketCount: Int, valueAreaPct: Double) -> [VolumeProfile.SessionVP] {
        let last = candles.last
        let sig = VPSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: last?.id.timeIntervalSince1970 ?? 0,
            lastClose: last?.close ?? 0,
            lastVolume: last?.volume ?? 0,
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
        let lastTS: TimeInterval
        let lastClose: Double
        let lastVolume: Double
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
        let last = candles.last
        let sig = ZigzagVPSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: last?.id.timeIntervalSince1970 ?? 0,
            lastClose: last?.close ?? 0,
            lastVolume: last?.volume ?? 0,
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

    // ── Visible-range Volume Profile (levels with volume) ──────────────

    /// Unlike the other slots this one *does* depend on the visible
    /// window — the bar range is part of the signature. The compute is
    /// O(visible bars), so a recompute per pan frame stays cheap.
    private struct VisibleRangeVPSig: Equatable {
        let count: Int
        let startBar: Int
        let endBar: Int
        let lastTS: TimeInterval
        let lastClose: Double
        let lastVolume: Double
        let bucketCount: Int
        let valueAreaPct: Double
        let levelCount: Int
    }
    private let visibleRangeVPSlot = Slot<VisibleRangeVPSig, VolumeProfile.VisibleRangeVP?>(nil)

    func visibleRangeVolumeProfile(
        candles: [Candle],
        barRange: ClosedRange<Int>,
        bucketCount: Int,
        valueAreaPct: Double,
        levelCount: Int
    ) -> VolumeProfile.VisibleRangeVP? {
        let last = candles.last
        let sig = VisibleRangeVPSig(
            count: candles.count,
            startBar: barRange.lowerBound,
            endBar: barRange.upperBound,
            lastTS: last?.id.timeIntervalSince1970 ?? 0,
            lastClose: last?.close ?? 0,
            lastVolume: last?.volume ?? 0,
            bucketCount: bucketCount,
            valueAreaPct: valueAreaPct,
            levelCount: levelCount
        )
        return resolve(visibleRangeVPSlot, signature: sig) {
            VolumeProfile.computeVisibleRange(
                candles,
                barRange: barRange,
                bucketCount: bucketCount,
                valueAreaPct: valueAreaPct,
                levelCount: levelCount
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

    // ── SP2L Strategy ────────────────────────────────────────────────

    private struct SP2LSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let lastClose: Double
        let lastHigh: Double
        let lastLow: Double
        let minSpikeBars: Int
        let maxSpikeBars: Int
        let rangeBars: Int
        let atrPeriod: Int
        let minSpikeATR: Double
        let maxSpikeATR: Double
        let maxRangeATR: Double
        let minGapPct: Double
        let maxPressureGapBar: Int
        let emaPeriod: Int
        let useEMAContext: Bool
        let maxEMADistanceATR: Double
        let maxPullbackBars: Int
        let maxContinuationBars: Int
        let riskReward: Double
        let targetCount: Int
    }
    private let sp2lSlot = Slot<SP2LSig, [SP2LSetup.Result]>([])

    func sp2lSetup(candles: [Candle], config: OscillatorConfig) -> [SP2LSetup.Result] {
        let last = candles.last
        let minSpikeBars = config.sp2lMinSpikeBars
        let maxSpikeBars = config.sp2lMaxSpikeBars
        let rangeBars = config.sp2lRangeBars
        let atrPeriod = config.sp2lATRPeriod
        let minSpikeATR = config.sp2lMinSpikeATR
        let maxSpikeATR = config.sp2lMaxSpikeATR
        let maxRangeATR = config.sp2lMaxRangeATR
        let minGapPct = config.sp2lMinGapPct
        let maxPressureGapBar = config.sp2lMaxPressureGapBar
        let emaPeriod = config.sp2lEMAPeriod
        let useEMAContext = config.sp2lUseEMAContext
        let maxEMADistanceATR = config.sp2lMaxEMADistanceATR
        let maxPullbackBars = config.sp2lMaxPullbackBars
        let maxContinuationBars = config.sp2lMaxContinuationBars
        let riskReward = config.sp2lRiskReward
        let targetCount = config.sp2lTargetCount
        let sig = SP2LSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: last?.id.timeIntervalSince1970 ?? 0,
            lastClose: last?.close ?? 0,
            lastHigh: last?.high ?? 0,
            lastLow: last?.low ?? 0,
            minSpikeBars: minSpikeBars,
            maxSpikeBars: maxSpikeBars,
            rangeBars: rangeBars,
            atrPeriod: atrPeriod,
            minSpikeATR: minSpikeATR,
            maxSpikeATR: maxSpikeATR,
            maxRangeATR: maxRangeATR,
            minGapPct: minGapPct,
            maxPressureGapBar: maxPressureGapBar,
            emaPeriod: emaPeriod,
            useEMAContext: useEMAContext,
            maxEMADistanceATR: maxEMADistanceATR,
            maxPullbackBars: maxPullbackBars,
            maxContinuationBars: maxContinuationBars,
            riskReward: riskReward,
            targetCount: targetCount
        )
        return resolve(sp2lSlot, signature: sig) {
            SP2LSetup.compute(
                candles,
                minSpikeBars: minSpikeBars,
                maxSpikeBars: maxSpikeBars,
                rangeBars: rangeBars,
                atrPeriod: atrPeriod,
                minSpikeATR: minSpikeATR,
                maxSpikeATR: maxSpikeATR,
                maxRangeATR: maxRangeATR,
                minGapPct: minGapPct,
                maxPressureGapBar: maxPressureGapBar,
                emaPeriod: emaPeriod,
                useEMAContext: useEMAContext,
                maxEMADistanceATR: maxEMADistanceATR,
                maxPullbackBars: maxPullbackBars,
                maxContinuationBars: maxContinuationBars,
                riskReward: riskReward,
                targetCount: targetCount
            )
        }
    }

    // ── Pin Bar · SP2L + BTB ────────────────────────────────────────

    private struct PinBarComboSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let lastOpen: Double
        let lastHigh: Double
        let lastLow: Double
        let lastClose: Double
        let sp2lHash: Int
        let config: PinBarComboSetup.Configuration
    }
    private let pinBarComboSlot = Slot<PinBarComboSig, [PinBarComboSetup.Result]>([])

    func pinBarComboSetup(
        candles: [Candle],
        sp2lResults: [SP2LSetup.Result],
        config: OscillatorConfig
    ) -> [PinBarComboSetup.Result] {
        let last = candles.last
        let strategyConfig = config.pinBarComboConfiguration
        let signature = PinBarComboSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: last?.id.timeIntervalSince1970 ?? 0,
            lastOpen: last?.open ?? 0,
            lastHigh: last?.high ?? 0,
            lastLow: last?.low ?? 0,
            lastClose: last?.close ?? 0,
            sp2lHash: sp2lResults.hashValue,
            config: strategyConfig
        )
        return resolve(pinBarComboSlot, signature: signature) {
            PinBarComboSetup.compute(
                candles,
                sp2lResults: sp2lResults,
                configuration: strategyConfig
            )
        }
    }

    // ── MicroMap Strategy ────────────────────────────────────────────

    private struct MicroMapSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let lastOpen: Double
        let lastHigh: Double
        let lastLow: Double
        let lastClose: Double
        let config: MicroMapSetup.Configuration
    }
    private let microMapSlot = Slot<MicroMapSig, [MicroMapSetup.Result]>([])

    func microMapSetup(candles: [Candle], config: OscillatorConfig) -> [MicroMapSetup.Result] {
        let last = candles.last
        let strategyConfig = config.microMapConfiguration
        let signature = MicroMapSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: last?.id.timeIntervalSince1970 ?? 0,
            lastOpen: last?.open ?? 0,
            lastHigh: last?.high ?? 0,
            lastLow: last?.low ?? 0,
            lastClose: last?.close ?? 0,
            config: strategyConfig
        )
        return resolve(microMapSlot, signature: signature) {
            MicroMapSetup.compute(candles, configuration: strategyConfig)
        }
    }

    // ── Major Trend Reversal ────────────────────────────────────────

    private struct MTRSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let lastTS: TimeInterval
        let lastOpen: Double
        let lastHigh: Double
        let lastLow: Double
        let lastClose: Double
        let config: MTRSetup.Configuration
    }
    private let mtrSlot = Slot<MTRSig, [MTRSetup.Result]>([])

    func mtrSetup(candles: [Candle], config: OscillatorConfig) -> [MTRSetup.Result] {
        let last = candles.last
        let strategyConfig = config.mtrConfiguration
        let signature = MTRSig(
            count: candles.count,
            firstTS: candles.first?.id.timeIntervalSince1970 ?? 0,
            lastTS: last?.id.timeIntervalSince1970 ?? 0,
            lastOpen: last?.open ?? 0,
            lastHigh: last?.high ?? 0,
            lastLow: last?.low ?? 0,
            lastClose: last?.close ?? 0,
            config: strategyConfig
        )
        return resolve(mtrSlot, signature: signature) {
            MTRSetup.compute(candles, configuration: strategyConfig)
        }
    }

    // ── Overlay extremes (for autoYDomain) ────────────────────────────
    //
    // `ChartView.autoYDomain` scans every overlay zone array + indicator
    // points to find the price extremes for the Y-axis range. In grid
    // mode with 4 panes × 1 Hz ticks, this ~200-line loop runs 4× per
    // second PER PANE. The overlay data rarely changes (only on AI
    // analysis, trade edits, drawing adds) — yet the loop ran every
    // frame because `autoYDomain` was an uncached computed property.
    //
    // This cache keys on candle structure + overlay array counts.
    // During pan/zoom the signature is unchanged → synchronous cache
    // hit. The candle-range scan (visible-window dependent, O(visible
    // bars)) stays in `ChartView.autoYDomain` — only the expensive
    // overlay+indicator scan is cached here.

    /// All the data that feeds the overlay-extremes scan. Passed as a
    /// single value so the cache signature can be computed cheaply.
    struct OverlayData {
        let candles: [Candle]
        let indicatorInstances: [IndicatorInstance]
        let indicatorConfig: OscillatorConfig
        let indicators: Set<IndicatorKind>
        let srLevels: PromptBuilder.SRLevels
        let fvgZones: [PromptBuilder.FVGZone]
        let supplyDemandZones: [PromptBuilder.SupplyDemandZone]
        let indicatorFvgZones: [FairValueGap.Zone]
        let orderBlockZones: [OrderBlocks.Zone]
        let steroidOrderBlockZones: [SteroidOrderBlocks.Zone]
        let sonarlabOBZones: [SonarlabOrderBlocks.Zone]
        let enhancedSonarlabOBZones: [EnhancedSonarlabOrderBlocks.Zone]
        let ichimokuOutput: Ichimoku.Output
        let ichimokuOBZones: [IchimokuOrderBlocks.Zone]
        let rankedOBZones: [RankedOrderBlocks.Zone]
        let volumeRankedOBZones: [VolumeRankedOrderBlocks.Zone]
        var rankedOBSetups: [RankedOBStrategy.Setup] = []
        let volumeFilteredOBZones: [VolumeFilteredOrderBlocks.Zone]
        let helixOBComboOutput: HelixOBCombo.Output
        let algoSmartAssistOutput: AlgoSmartAssist.Output
        var amdCycles: [AMDCycle.Cycle] = []
        let chochZones: [ChangeOfCharacter.Zone]
        let htfChochZones: [ChangeOfCharacter.DatedZone]
        let sessionRuns: [TradingSessions.SessionRun]
        let nySetupResults: [NYOpenSetup.Result]
        let sp2lResults: [SP2LSetup.Result]
        let pinBarComboResults: [PinBarComboSetup.Result]
        let microMapResults: [MicroMapSetup.Result]
        let mtrResults: [MTRSetup.Result]
        let volumeProfileSessions: [VolumeProfile.SessionVP]
        let zigzagTrendVP: VolumeProfile.TrendVP?
        let visibleRangeVP: VolumeProfile.VisibleRangeVP?
        let zigzagPivots: [ZigZag.Pivot]
        let taScenario: PromptBuilder.TAScenario?
        let taAltScenario: PromptBuilder.TAScenario?
        let drawings: [ChartDrawing]
        let trades: [Trade]
        let journalEntries: [JournalEntry]
    }

    private struct OverlayExtremesSig: Equatable {
        let count: Int
        let firstTS: TimeInterval
        let indicatorHiddenStates: [Bool]
        let utOn: Bool
        let srSupportCount: Int
        let srResistanceCount: Int
        let fvgCount: Int
        let sdCount: Int
        let ifvgCount: Int
        let obCount: Int
        let sobCount: Int
        let sonarlabCount: Int
        let enhancedSonarlabCount: Int
        let ichimokuLineCount: Int
        let ichimokuOBCount: Int
        let rankedOBCount: Int
        let volumeRankedOBCount: Int
        let rankedOBSetupKeys: [String]
        let volumeFilteredOBCount: Int
        let helixOBComboCount: Int
        let algoSmartAssistCount: Int
        /// Count alone won't do: a live cycle's plan levels and phase
        /// move while the cycle set stays the same size.
        let amdKeys: [String]
        let chochCount: Int
        let htfChochCount: Int
        let sessionCount: Int
        let nySetupCount: Int
        let sp2lCount: Int
        let pinBarCount: Int
        let microMapCount: Int
        let mtrCount: Int
        let vpSessionCount: Int
        let zigzagVPBuckets: Int
        let visibleRangeVPBuckets: Int
        let zigzagPivotCount: Int
        let scenarioOn: Bool
        let altScenarioOn: Bool
        let drawingCount: Int
        let tradeCount: Int
        let journalCount: Int
    }
    private let overlayExtremesSlot = Slot<OverlayExtremesSig, (lo: Double, hi: Double)>(
        (Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
    )

    /// Cached overlay+indicator price extremes (excludes candle OHLC).
    /// Call from `ChartView.autoYDomain` — the candle-range scan stays
    /// there since it depends on the visible window.
    func overlayExtremes(_ data: OverlayData) -> (lo: Double, hi: Double) {
        let sig = OverlayExtremesSig(
            count: data.candles.count,
            firstTS: data.candles.first?.id.timeIntervalSince1970 ?? 0,
            indicatorHiddenStates: data.indicatorInstances.map(\.hidden),
            utOn: data.indicators.contains(.utBot),
            srSupportCount: data.srLevels.support.count,
            srResistanceCount: data.srLevels.resistance.count,
            fvgCount: data.fvgZones.count,
            sdCount: data.supplyDemandZones.count,
            ifvgCount: data.indicatorFvgZones.count,
            obCount: data.orderBlockZones.count,
            sobCount: data.steroidOrderBlockZones.count,
            sonarlabCount: data.sonarlabOBZones.count,
            enhancedSonarlabCount: data.enhancedSonarlabOBZones.count,
            ichimokuLineCount: data.ichimokuOutput.kijun.count,
            ichimokuOBCount: data.ichimokuOBZones.count,
            rankedOBCount: data.rankedOBZones.count,
            volumeRankedOBCount: data.volumeRankedOBZones.count,
            // Count alone won't do here: a plan's levels move when it
            // re-bases on a confirmation close, without the set changing
            // size, and the Y-domain has to follow.
            rankedOBSetupKeys: data.rankedOBSetups.map {
                "\($0.id)|\($0.stopLoss)|\($0.takeProfit2)"
            },
            volumeFilteredOBCount: data.volumeFilteredOBZones.count,
            helixOBComboCount: data.helixOBComboOutput.bullishOBs.count + data.helixOBComboOutput.bearishOBs.count,
            algoSmartAssistCount: data.algoSmartAssistOutput.zones.count + data.algoSmartAssistOutput.lines.count,
            amdKeys: data.amdCycles.map {
                "\($0.id)|\($0.phase.rawValue)|\($0.gap?.takeProfit2 ?? 0)"
            },
            chochCount: data.chochZones.count,
            htfChochCount: data.htfChochZones.count,
            sessionCount: data.sessionRuns.count,
            nySetupCount: data.nySetupResults.count,
            sp2lCount: data.sp2lResults.count,
            pinBarCount: data.pinBarComboResults.count,
            microMapCount: data.microMapResults.count,
            mtrCount: data.mtrResults.count,
            vpSessionCount: data.volumeProfileSessions.count,
            zigzagVPBuckets: data.zigzagTrendVP?.buckets.count ?? 0,
            visibleRangeVPBuckets: data.visibleRangeVP?.buckets.count ?? 0,
            zigzagPivotCount: data.zigzagPivots.count,
            scenarioOn: data.taScenario != nil,
            altScenarioOn: data.taAltScenario != nil,
            drawingCount: data.drawings.count,
            tradeCount: data.trades.count,
            journalCount: data.journalEntries.count
        )
        return resolve(overlayExtremesSlot, signature: sig) {
            var lo = Double.greatestFiniteMagnitude
            var hi = -Double.greatestFiniteMagnitude
            let candles = data.candles

            // Indicator points — from the already-memoized indicator cache
            if !data.indicatorInstances.isEmpty {
                let computed = Indicators.compute(instances: data.indicatorInstances, candles: candles)
                for entry in computed {
                    for p in entry.points {
                        if p.value < lo { lo = p.value }
                        if p.value > hi { hi = p.value }
                    }
                }
            }
            // UT Bot trailing stop
            if data.indicators.contains(.utBot) {
                let output = UTBot.compute(
                    candles,
                    keyValue: data.indicatorConfig.utKeyValue,
                    atrPeriod: data.indicatorConfig.utATRPeriod,
                    useHeikinAshi: data.indicatorConfig.utUseHeikinAshi
                )
                for v in output.trailingStop.compactMap({ $0 }) {
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            // Zone arrays — inline scans, no allocations
            for level in data.srLevels.support {
                if level < lo { lo = level }
                if level > hi { hi = level }
            }
            for level in data.srLevels.resistance {
                if level < lo { lo = level }
                if level > hi { hi = level }
            }
            for zone in data.fvgZones {
                if zone.low < lo { lo = zone.low }
                if zone.high > hi { hi = zone.high }
            }
            for zone in data.supplyDemandZones {
                if zone.low < lo { lo = zone.low }
                if zone.high > hi { hi = zone.high }
            }
            for zone in data.indicatorFvgZones {
                if zone.low < lo { lo = zone.low }
                if zone.high > hi { hi = zone.high }
            }
            for zone in data.orderBlockZones {
                if zone.low < lo { lo = zone.low }
                if zone.high > hi { hi = zone.high }
            }
            for zone in data.steroidOrderBlockZones {
                if zone.low < lo { lo = zone.low }
                if zone.high > hi { hi = zone.high }
            }
            for zone in data.sonarlabOBZones {
                if zone.low < lo { lo = zone.low }
                if zone.high > hi { hi = zone.high }
            }
            for zone in data.enhancedSonarlabOBZones {
                if zone.low < lo { lo = zone.low }
                if zone.high > hi { hi = zone.high }
            }
            for zone in data.ichimokuOBZones {
                if zone.low < lo { lo = zone.low }
                if zone.high > hi { hi = zone.high }
            }
            for zone in data.rankedOBZones {
                if zone.bottom < lo { lo = zone.bottom }
                if zone.top > hi { hi = zone.top }
            }
            for zone in data.volumeRankedOBZones {
                if zone.bottom < lo { lo = zone.bottom }
                if zone.top > hi { hi = zone.top }
            }
            for setup in data.rankedOBSetups {
                for v in [setup.entry, setup.stopLoss, setup.takeProfit1, setup.takeProfit2] {
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            for zone in data.volumeFilteredOBZones {
                if zone.bottom < lo { lo = zone.bottom }
                if zone.top > hi { hi = zone.top }
            }
            for ob in data.helixOBComboOutput.bullishOBs + data.helixOBComboOutput.bearishOBs {
                if ob.btm < lo { lo = ob.btm }
                if ob.top > hi { hi = ob.top }
            }
            for pt in data.helixOBComboOutput.points {
                if let ls = pt.longStop { if ls < lo { lo = ls }; if ls > hi { hi = ls } }
                if let ss = pt.shortStop { if ss < lo { lo = ss }; if ss > hi { hi = ss } }
            }
            for z in data.algoSmartAssistOutput.zones {
                if z.bottom < lo { lo = z.bottom }
                if z.top > hi { hi = z.top }
            }
            for l in data.algoSmartAssistOutput.lines {
                if l.price < lo { lo = l.price }
                if l.price > hi { hi = l.price }
            }
            for ll in data.algoSmartAssistOutput.liveLines {
                if ll.price < lo { lo = ll.price }
                if ll.price > hi { hi = ll.price }
            }
            for cycle in data.amdCycles {
                var values = [cycle.rangeHigh, cycle.rangeLow]
                if let p = cycle.sweepPrice { values.append(p) }
                if let e = cycle.expansionExtreme { values.append(e) }
                if let gap = cycle.gap {
                    values.append(contentsOf: [
                        gap.high, gap.low, gap.stopLoss, gap.takeProfit1, gap.takeProfit2,
                    ])
                }
                for v in values {
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            // Ichimoku lines — Span B (widest window) and Kijun bound the
            // system; scanning both spans covers the cloud extremes too.
            let ichi = data.ichimokuOutput
            for p in ichi.senkouA { if p.value < lo { lo = p.value }; if p.value > hi { hi = p.value } }
            for p in ichi.senkouB { if p.value < lo { lo = p.value }; if p.value > hi { hi = p.value } }
            for p in ichi.tenkan { if p.value < lo { lo = p.value }; if p.value > hi { hi = p.value } }
            for p in ichi.kijun { if p.value < lo { lo = p.value }; if p.value > hi { hi = p.value } }
            for zone in data.chochZones {
                if zone.low < lo { lo = zone.low }
                if zone.high > hi { hi = zone.high }
            }
            for zone in data.htfChochZones {
                if zone.low < lo { lo = zone.low }
                if zone.high > hi { hi = zone.high }
            }
            for run in data.sessionRuns {
                if run.low < lo { lo = run.low }
                if run.high > hi { hi = run.high }
            }
            for r in data.nySetupResults {
                if r.orLow < lo { lo = r.orLow }
                if r.orHigh > hi { hi = r.orHigh }
            }
            for r in data.sp2lResults {
                for v in [
                    r.brokenLevel, r.spikeLow, r.spikeHigh,
                    r.entry, r.stopLoss,
                ] + r.takeProfits(count: data.indicatorConfig.sp2lTargetCount) {
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            for result in data.pinBarComboResults {
                for value in [
                    result.level, result.pinBarLow, result.pinBarHigh,
                    result.entry, result.stopLoss, result.takeProfit
                ] {
                    if value < lo { lo = value }
                    if value > hi { hi = value }
                }
            }
            for result in data.microMapResults {
                if result.spikeLow < lo { lo = result.spikeLow }
                if result.spikeHigh > hi { hi = result.spikeHigh }
                for attempt in result.attempts {
                    for value in [attempt.entry, attempt.stopLoss, attempt.takeProfit].compactMap({ $0 }) {
                        if value < lo { lo = value }
                        if value > hi { hi = value }
                    }
                }
            }
            for result in data.mtrResults {
                let channelBars = result.channelEndIndex - result.channelStartIndex
                let channelSlope = channelBars == 0 ? 0 :
                    (result.channelEndPrice - result.channelStartPrice) / Double(channelBars)
                let projectedMain = result.channelStartPrice
                    + channelSlope * Double(result.breakoutIndex - result.channelStartIndex)
                let projectedParallel = projectedMain
                    + (result.parallelStartPrice - result.channelStartPrice)
                var values = [
                    result.channelStartPrice, result.channelEndPrice,
                    result.parallelStartPrice, result.parallelEndPrice,
                    projectedMain, projectedParallel,
                    result.trendExtremePrice, result.retestPrice, result.neckline
                ]
                values += [result.entry, result.stopLoss, result.takeProfit].compactMap { $0 }
                for value in values {
                    if value < lo { lo = value }
                    if value > hi { hi = value }
                }
            }
            for session in data.volumeProfileSessions {
                for bucket in session.buckets {
                    if bucket.priceLevel < lo { lo = bucket.priceLevel }
                    if bucket.priceLevel > hi { hi = bucket.priceLevel }
                }
            }
            if let vp = data.zigzagTrendVP {
                for bucket in vp.buckets {
                    if bucket.priceLevel < lo { lo = bucket.priceLevel }
                    if bucket.priceLevel > hi { hi = bucket.priceLevel }
                }
            }
            if let vp = data.visibleRangeVP {
                for bucket in vp.buckets {
                    if bucket.priceLevel < lo { lo = bucket.priceLevel }
                    if bucket.priceLevel > hi { hi = bucket.priceLevel }
                }
            }
            for pivot in data.zigzagPivots {
                if pivot.price < lo { lo = pivot.price }
                if pivot.price > hi { hi = pivot.price }
            }
            if let scenario = data.taScenario {
                for v in [scenario.takeProfit, scenario.stopLoss] + [scenario.entry].compactMap({ $0 }) {
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            if let alt = data.taAltScenario {
                for v in [alt.takeProfit, alt.stopLoss] + [alt.entry].compactMap({ $0 }) {
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            for d in data.drawings where d.visible {
                if d.start.price < lo { lo = d.start.price }
                if d.start.price > hi { hi = d.start.price }
                if let e = d.end {
                    if e.price < lo { lo = e.price }
                    if e.price > hi { hi = e.price }
                }
            }
            for t in data.trades {
                for v in [t.entry, t.takeProfit, t.stopLoss, t.fillPrice ?? t.entry] {
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            for je in data.journalEntries {
                for v in [je.entry, je.takeProfit, je.stopLoss].compactMap({ $0 }) {
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
            }
            guard lo != Double.greatestFiniteMagnitude else { return (0, 1) }
            return (lo, hi)
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
            case .helixOBCombo:
                return []
            }
        }
    }
}
