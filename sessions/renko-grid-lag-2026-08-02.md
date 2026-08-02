# Renko lag in multi-pane layouts — root cause and fix (2026-08-02)

## Report

"Renko chart is so laggy, especially in 2 columns / 2 rows / grid."

## Investigation

Measured rather than guessed. Hypotheses tested and **rejected** first:

- *Shared cache thrashing across panes.* No — `ChartDerivedCache` is a
  `@StateObject` per `ChartView` / `OscillatorPanel`, so panes don't evict
  each other.
- *`Renko.transform` re-running per frame.* No — it is memoized on
  `BaseDisplaySig` (count / firstTS / chartType / renkoConfig) and correctly
  does not recompute on the 1 Hz live tick.
- *Brick-count explosion.* Real but not the cause: a small fixed box size does
  blow up (box 0.1 → 131k bricks from 20k candles, 24 ms) but the transform is
  memoized and `ChartWindow.renderIndices` caps what is actually drawn.
- *Indicator marks flooding the renderer in brick space.* No —
  `indicatorMarks` filters points against the visible index set, which is
  small in Renko mode.

The actual cause, measured on the hot path — the cost of a `displayCandles`
**cache hit**, which is the common case on every frame:

| chart type | cache hit | per `ChartView` body (23 call sites) | 4-pane grid frame |
|------------|-----------|--------------------------------------|-------------------|
| candle     | 240 ns    | 6 µs                                 | 22 µs             |
| **renko**  | **4089 ns** | **94 µs**                          | **376 µs**        |

`ChartDerivedCache.BaseDisplaySig` embeds a `RenkoConfig`, so every cache-hit
check compares one. And `RenkoConfig` is `RawRepresentable` (for
`@AppStorage`), which means the standard library's
`RawRepresentable where RawValue: Equatable` `==` was shadowing the
synthesized memberwise one — **equality was comparing encoded JSON strings**,
two full `JSONEncoder` passes per comparison:

    RenkoConfig ==  3682 ns/op    rawValue 1885 ns/op    plain struct == 95 ns/op

`displayCandles` is a *computed* property on `ChartView` referenced 23 times
per body, and each pane owns a cache — so the cost is multiplied by call sites
and again by pane count, which is exactly why it only became obvious in the
2-column / 2-row / grid layouts.

This is the same defect that made
`RenkoTests.testRenkoConfigRawValueEncodingAndEquality` flaky (`JSONEncoder`
gives no key-ordering guarantee, and Swift's hash seed is randomised per
process, so structurally identical configs compared unequal on ~1 run in 6).
One root cause, two symptoms.

## Fix

`GoldMonitorMac/Models/Renko.swift` — declared an explicit structural `==` on
`RenkoConfig` so the concrete overload wins over the `RawRepresentable` one.
Six lines, with a comment explaining why it must not be deleted.

Re-measured:

| chart type | cache hit before | after |
|------------|------------------|-------|
| candle     | 240 ns           | 242 ns |
| **renko**  | **4089 ns**      | **252 ns** |

16× faster, and Renko now costs the same per frame as a candle chart
(376 µs → 23 µs on a 4-pane grid). The flaky test also passes 6/6 in
isolation, where it previously failed ~1 in 6.

## Tests

`GoldMonitorMacTests/RenkoConfigEqualityTests.swift` (new, 3 tests) — kept in
its own file rather than added to `RenkoTests.swift`, which a concurrently
running session was editing.

- `testEqualityIsStructural` — field-by-field semantics.
- `testRoundTripComparesEqualRepeatedly` — 200 encode/decode round trips, the
  assertion that used to fail intermittently.
- `testEqualityDoesNotEncodeJSON` — a deliberately loose timing guard (100k
  comparisons under 100 ms; structural is ~10 ms, the JSON version ~370 ms).
  This is the only way to catch the regression deterministically: if the
  explicit `==` is deleted the type still compiles and still *usually* returns
  the right answer, just slowly and occasionally wrongly.

Full suite: **121 tests, 0 failures**. macOS build clean.

## Note for whoever picks this up

A background task was spawned earlier today for this same `RenkoConfig`
equality bug and had already been started in a separate session, so it could
not be withdrawn. If it lands its own fix, the two will collide in
`Renko.swift` — keep one structural `==`, not two.

## Remaining Renko limitations (unchanged, not addressed here)

Still true from the earlier Renko rewrite: the price chart is in brick index
space while `VolumeBarsView` / `OscillatorPanel` and the overlay marks are
computed on raw candles at candle indices, so they do not line up with bricks.
That is a design gap, not a performance one — and now that the equality tax is
gone, it is not what makes the chart feel slow.

`@AppStorage` reads still decode `RenkoConfig` from JSON on access
(~2.3 µs/read, roughly 2 reads per pane body ≈ 18 µs on a 4-pane grid). An
order of magnitude below what was just removed, so it was left alone.
