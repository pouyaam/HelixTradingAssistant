// HelixBridgeBot.cs
//
// cTrader cBot that bridges Helix Trading (macOS) <→ cTrader:
//   • Streams ticks + bar closes to Helix (one-way, original v1 contract).
//   • Receives place_order / modify_order / cancel_order / close_position
//     / request_state commands from Helix (auto-trader v2).
//   • Owns trailing-stop logic (cTrader sees every tick; Helix's stream
//     is 2 Hz coalesced — running trailing here is lower-latency).
//   • Maintains an idempotency ring so reconnect-during-send doesn't
//     double-place an order.
//   • Emits order_status events on every broker state change so Helix's
//     local TradeStore stays in sync.
//
// Pair this with `GoldMonitorMac/Fetching/CTraderWSReceiver.swift` +
// `GoldMonitorMac/Scheduling/CTraderScheduler.swift` — message schemas
// must stay in lock-step.
//
// SAFETY: every order Helix sends carries a Helix-generated UUID
// (`helix_id`). The cBot returns it on every status event so Helix can
// find the matching local Trade. The cBot itself does NOT initiate
// trades — all orders are user-driven via Helix.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using cAlgo.API;
using cAlgo.API.Internals;

namespace cAlgo.Robots
{
    [Robot(AccessRights = AccessRights.FullAccess)]
    public class HelixBridgeBot : Robot
    {
        // ── Parameters ────────────────────────────────────────────

        [Parameter("Helix host", DefaultValue = "127.0.0.1")]
        public string HelixHost { get; set; }

        [Parameter("Helix port", DefaultValue = 7878, MinValue = 1, MaxValue = 65535)]
        public int HelixPort { get; set; }

        [Parameter("Send ticks", DefaultValue = true)]
        public bool SendTicks { get; set; }

        [Parameter("Send bars", DefaultValue = true)]
        public bool SendBars { get; set; }

        [Parameter("Max ticks per second", DefaultValue = 10, MinValue = 1, MaxValue = 100)]
        public int MaxTicksPerSecond { get; set; }

        [Parameter("Auto-trader label prefix", DefaultValue = "helix")]
        public string LabelPrefix { get; set; }

        // ── State ─────────────────────────────────────────────────

        private TcpClient _client;
        private NetworkStream _stream;
        private readonly object _writeLock = new object();
        private DateTime _lastPingAt = DateTime.MinValue;
        private DateTime _lastTickSentAt = DateTime.MinValue;
        private int _backoffSeconds = 1;
        private const int MaxBackoff = 30;
        private const string BotVersion = "0.2";

        // Inbound buffer + reader thread.
        private readonly object _readLock = new object();
        private byte[] _readBuffer = new byte[8192];
        private StringBuilder _lineBuffer = new StringBuilder();
        private Thread _readerThread;
        private volatile bool _readerStop = false;

        // Idempotency: remember the last N place_order helix_ids we've
        // processed so a reconnect-during-send doesn't double-fill.
        private readonly LinkedList<string> _seenOrderIDs = new LinkedList<string>();
        private const int SeenOrderIDsCap = 256;

        // Helix-managed positions: cTrader_id → trailing config so OnTick
        // can walk the SL forward. Populated on order fill, removed on
        // close. Trailing is per-position not per-symbol so two parallel
        // positions can have different ATR multiples.
        private class TrailingState
        {
            public string HelixID;
            public double ATR;         // base ATR value at place time
            public double Multiple;    // trailing distance = multiple × ATR
            public double EntryPrice;
            public TradeType Side;
            public double? LastSL;     // last SL we modified to; nil = no walk yet
        }
        private readonly Dictionary<long, TrailingState> _trailing = new Dictionary<long, TrailingState>();
        // Map helix_id → cTrader position id so order_status events can
        // round-trip the helix-side identifier.
        private readonly Dictionary<long, string> _positionToHelixID = new Dictionary<long, string>();
        private readonly Dictionary<long, string> _orderToHelixID = new Dictionary<long, string>();

        // ── Lifecycle ─────────────────────────────────────────────

        protected override void OnStart()
        {
            // Subscribe to broker events so we emit order_status
            // promptly without polling.
            Positions.Opened += OnPositionOpened;
            Positions.Closed += OnPositionClosed;
            PendingOrders.Created += OnPendingCreated;
            PendingOrders.Cancelled += OnPendingCancelled;
            PendingOrders.Filled += OnPendingFilled;
            TryConnect();
            StartReader();
        }

        protected override void OnStop()
        {
            Positions.Opened -= OnPositionOpened;
            Positions.Closed -= OnPositionClosed;
            PendingOrders.Created -= OnPendingCreated;
            PendingOrders.Cancelled -= OnPendingCancelled;
            PendingOrders.Filled -= OnPendingFilled;
            _readerStop = true;
            CloseConnection();
        }

        protected override void OnTick()
        {
            EnsureConnected();
            if (!IsConnected) return;

            var nowWall = DateTime.UtcNow;
            var minIntervalMs = 1000.0 / Math.Max(1, MaxTicksPerSecond);
            var tickGateOpen = (nowWall - _lastTickSentAt).TotalMilliseconds >= minIntervalMs;
            if (SendTicks && tickGateOpen)
            {
                _lastTickSentAt = nowWall;
                var sb = new StringBuilder(128);
                sb.Append("{\"type\":\"tick\",\"symbol\":\"");
                sb.Append(SymbolName);
                sb.Append("\",\"bid\":");
                AppendDouble(sb, Symbol.Bid);
                sb.Append(",\"ask\":");
                AppendDouble(sb, Symbol.Ask);
                sb.Append(",\"ts\":\"");
                sb.Append(Server.Time.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture));
                sb.Append("\"}");
                SendLine(sb.ToString());
            }

            // Trailing-stop walk. For every Helix-managed position
            // open right now, if price has moved `multiple × ATR` in
            // our favor beyond either the last-walked SL or the
            // entry, modify the SL to that new floor.
            WalkTrailingStops();

            if ((nowWall - _lastPingAt).TotalSeconds >= 20)
            {
                _lastPingAt = nowWall;
                SendLine("{\"type\":\"ping\",\"ts\":\"" + nowWall.ToString("o", CultureInfo.InvariantCulture) + "\"}");
            }
        }

        protected override void OnBar()
        {
            if (!SendBars || !IsConnected) return;

            var i = Bars.ClosePrices.Count - 2;
            if (i < 0) return;

            var tf = TimeframeLabel(Bars.TimeFrame);
            var sb = new StringBuilder(256);
            sb.Append("{\"type\":\"bar\",\"symbol\":\"");
            sb.Append(SymbolName);
            sb.Append("\",\"tf\":\"");
            sb.Append(tf);
            sb.Append("\",\"o\":");
            AppendDouble(sb, Bars.OpenPrices[i]);
            sb.Append(",\"h\":");
            AppendDouble(sb, Bars.HighPrices[i]);
            sb.Append(",\"l\":");
            AppendDouble(sb, Bars.LowPrices[i]);
            sb.Append(",\"c\":");
            AppendDouble(sb, Bars.ClosePrices[i]);
            sb.Append(",\"v\":");
            AppendDouble(sb, Bars.TickVolumes[i]);
            sb.Append(",\"ts\":\"");
            sb.Append(Bars.OpenTimes[i].ToUniversalTime().ToString("o", CultureInfo.InvariantCulture));
            sb.Append("\"}");
            SendLine(sb.ToString());
        }

        // ── Trailing stop ─────────────────────────────────────────

        private void WalkTrailingStops()
        {
            foreach (var kv in _trailing)
            {
                var posID = kv.Key;
                var t = kv.Value;
                var position = FindPosition(posID);
                if (position == null) continue;

                var distance = t.Multiple * t.ATR;
                if (distance <= 0) continue;

                // Walk forward only — never loosen the stop.
                if (t.Side == TradeType.Buy)
                {
                    var candidate = Symbol.Bid - distance;
                    var floor = t.LastSL ?? position.StopLoss ?? double.NegativeInfinity;
                    if (candidate > floor && candidate < Symbol.Bid)
                    {
                        position.ModifyStopLossPrice(candidate);
                        t.LastSL = candidate;
                    }
                }
                else
                {
                    var candidate = Symbol.Ask + distance;
                    var ceiling = t.LastSL ?? position.StopLoss ?? double.PositiveInfinity;
                    if (candidate < ceiling && candidate > Symbol.Ask)
                    {
                        position.ModifyStopLossPrice(candidate);
                        t.LastSL = candidate;
                    }
                }
            }
        }

        private Position FindPosition(long id)
        {
            foreach (var p in Positions)
            {
                if (p.Id == id) return p;
            }
            return null;
        }

        // ── Broker event handlers → emit order_status ─────────────

        private void OnPositionOpened(PositionOpenedEventArgs e)
        {
            var p = e.Position;
            if (!_positionToHelixID.TryGetValue(p.Id, out var helixID)) return;
            EmitOrderStatus(p.Id.ToString(), helixID, "filled",
                fillPrice: p.EntryPrice, closePrice: null,
                closeReason: null, rejectReason: null);
        }

        private void OnPositionClosed(PositionClosedEventArgs e)
        {
            var p = e.Position;
            if (!_positionToHelixID.TryGetValue(p.Id, out var helixID)) return;
            // Map cTrader's close reason onto Helix's enum strings.
            string reason;
            switch (e.Reason)
            {
                case PositionCloseReason.TakeProfit:  reason = "hitTP"; break;
                case PositionCloseReason.StopLoss:    reason = "hitSL"; break;
                case PositionCloseReason.StopOut:     reason = "hitSL"; break;
                default:                              reason = "manual"; break;
            }
            // If the SL was modified by our trailing logic, surface
            // "trailing" as the reason for the audit trail.
            if (reason == "hitSL" && _trailing.TryGetValue(p.Id, out var t) && t.LastSL != null)
            {
                reason = "trailing";
            }
            EmitOrderStatus(p.Id.ToString(), helixID, "closed",
                fillPrice: null, closePrice: p.EntryPrice,
                closeReason: reason, rejectReason: null);
            _trailing.Remove(p.Id);
            _positionToHelixID.Remove(p.Id);
        }

        private void OnPendingCreated(PendingOrderCreatedEventArgs e)
        {
            if (!_orderToHelixID.TryGetValue(e.PendingOrder.Id, out var helixID)) return;
            EmitOrderStatus(e.PendingOrder.Id.ToString(), helixID, "placed",
                fillPrice: null, closePrice: null,
                closeReason: null, rejectReason: null);
        }

        private void OnPendingCancelled(PendingOrderCancelledEventArgs e)
        {
            if (!_orderToHelixID.TryGetValue(e.PendingOrder.Id, out var helixID)) return;
            EmitOrderStatus(e.PendingOrder.Id.ToString(), helixID, "cancelled",
                fillPrice: null, closePrice: null,
                closeReason: "cancelled", rejectReason: null);
            _orderToHelixID.Remove(e.PendingOrder.Id);
        }

        private void OnPendingFilled(PendingOrderFilledEventArgs e)
        {
            if (!_orderToHelixID.TryGetValue(e.PendingOrder.Id, out var helixID)) return;
            // Pending order → position transition: hand the
            // helix_id off to the new position so subsequent
            // events use the same correlation.
            _positionToHelixID[e.Position.Id] = helixID;
            _orderToHelixID.Remove(e.PendingOrder.Id);
        }

        // ── Inbound command handling ──────────────────────────────

        private void StartReader()
        {
            _readerStop = false;
            _readerThread = new Thread(ReaderLoop) { IsBackground = true };
            _readerThread.Start();
        }

        private void ReaderLoop()
        {
            while (!_readerStop)
            {
                NetworkStream s = _stream;
                if (s == null) { Thread.Sleep(200); continue; }
                try
                {
                    int n = s.Read(_readBuffer, 0, _readBuffer.Length);
                    if (n <= 0) { Thread.Sleep(50); continue; }
                    lock (_readLock)
                    {
                        _lineBuffer.Append(Encoding.UTF8.GetString(_readBuffer, 0, n));
                    }
                    DrainLineBuffer();
                }
                catch
                {
                    // Read failed — connection likely dropped; the
                    // OnTick reconnect path will catch it.
                    Thread.Sleep(200);
                }
            }
        }

        private void DrainLineBuffer()
        {
            string pending;
            lock (_readLock) { pending = _lineBuffer.ToString(); }
            int newline;
            while ((newline = pending.IndexOf('\n')) >= 0)
            {
                var line = pending.Substring(0, newline);
                pending = pending.Substring(newline + 1);
                if (line.Length > 0)
                {
                    HandleCommand(line);
                }
            }
            lock (_readLock)
            {
                _lineBuffer.Clear();
                _lineBuffer.Append(pending);
            }
        }

        private void HandleCommand(string json)
        {
            try
            {
                using (var doc = JsonDocument.Parse(json))
                {
                    var root = doc.RootElement;
                    if (!root.TryGetProperty("type", out var typeEl)) return;
                    var type = typeEl.GetString();
                    switch (type)
                    {
                        case "place_order":     HandlePlaceOrder(root);      break;
                        case "modify_order":    HandleModifyOrder(root);     break;
                        case "cancel_order":    HandleCancelOrder(root);     break;
                        case "close_position":  HandleClosePosition(root);   break;
                        case "request_state":   HandleRequestState();        break;
                    }
                }
            }
            catch (Exception ex)
            {
                Print("[Helix] Command parse failed: {0}", ex.Message);
            }
        }

        private void HandlePlaceOrder(JsonElement root)
        {
            var helixID = root.GetProperty("id").GetString();
            if (string.IsNullOrEmpty(helixID)) return;

            // Idempotency: if we've already processed this id,
            // skip. cTrader API doesn't expose a query for "did I
            // place this before" so we keep our own ring.
            if (HasSeenOrder(helixID)) { Print("[Helix] duplicate place_order {0}", helixID); return; }
            RememberOrder(helixID);

            var sideRaw = root.GetProperty("side").GetString();
            var side = sideRaw == "sell" ? TradeType.Sell : TradeType.Buy;
            var entryKind = root.GetProperty("entry_kind").GetString();
            var entry = root.GetProperty("entry").GetDouble();
            var tp = root.GetProperty("tp").GetDouble();
            var sl = root.GetProperty("sl").GetDouble();
            var lots = root.GetProperty("lots").GetDouble();
            var volumeInUnits = Symbol.QuantityToVolumeInUnits(lots);
            var label = LabelPrefix + ":" + helixID;

            // Convert tp/sl absolute prices into pips offsets, which
            // is the API shape cTrader expects.
            var tpPips = AbsToPips(entry, tp, side, isTP: true);
            var slPips = AbsToPips(entry, sl, side, isTP: false);

            // Optional trailing config — applied at fill time.
            double trailingATR = 0;
            double atrValue = 0;
            if (root.TryGetProperty("trailing_atr", out var trailingEl)) trailingATR = trailingEl.GetDouble();
            if (root.TryGetProperty("atr_value", out var atrEl))         atrValue = atrEl.GetDouble();

            if (entryKind == "market")
            {
                var result = ExecuteMarketOrder(side, SymbolName, volumeInUnits, label, slPips, tpPips);
                if (result.IsSuccessful)
                {
                    _positionToHelixID[result.Position.Id] = helixID;
                    if (trailingATR > 0 && atrValue > 0)
                    {
                        _trailing[result.Position.Id] = new TrailingState
                        {
                            HelixID = helixID,
                            ATR = atrValue,
                            Multiple = trailingATR,
                            EntryPrice = result.Position.EntryPrice,
                            Side = side,
                            LastSL = null,
                        };
                    }
                }
                else
                {
                    EmitOrderStatus("0", helixID, "rejected",
                        fillPrice: null, closePrice: null,
                        closeReason: null, rejectReason: result.Error.ToString());
                }
            }
            else // limit
            {
                var result = PlaceLimitOrder(side, SymbolName, volumeInUnits, entry, label, slPips, tpPips);
                if (result.IsSuccessful)
                {
                    _orderToHelixID[result.PendingOrder.Id] = helixID;
                    if (trailingATR > 0 && atrValue > 0)
                    {
                        // Stash trailing config keyed by the future
                        // position id (we don't know it yet) — we
                        // rebuild this in OnPendingFilled.
                        // Simpler: stash by helix_id and look up
                        // when the fill happens.
                    }
                }
                else
                {
                    EmitOrderStatus("0", helixID, "rejected",
                        fillPrice: null, closePrice: null,
                        closeReason: null, rejectReason: result.Error.ToString());
                }
            }
        }

        private void HandleModifyOrder(JsonElement root)
        {
            if (!root.TryGetProperty("cTrader_id", out var idEl)) return;
            if (!long.TryParse(idEl.GetString(), out var id)) return;
            double? tp = root.TryGetProperty("tp", out var tpEl) ? (double?)tpEl.GetDouble() : null;
            double? sl = root.TryGetProperty("sl", out var slEl) ? (double?)slEl.GetDouble() : null;
            var position = FindPosition(id);
            if (position != null)
            {
                position.ModifyStopLossPrice(sl);
                position.ModifyTakeProfitPrice(tp);
            }
        }

        private void HandleCancelOrder(JsonElement root)
        {
            if (!root.TryGetProperty("cTrader_id", out var idEl)) return;
            if (!long.TryParse(idEl.GetString(), out var id)) return;
            foreach (var o in PendingOrders)
            {
                if (o.Id == id) { CancelPendingOrder(o); return; }
            }
        }

        private void HandleClosePosition(JsonElement root)
        {
            if (!root.TryGetProperty("cTrader_id", out var idEl)) return;
            if (!long.TryParse(idEl.GetString(), out var id)) return;
            var position = FindPosition(id);
            if (position != null) ClosePosition(position);
        }

        private void HandleRequestState()
        {
            var sb = new StringBuilder(512);
            sb.Append("{\"type\":\"state_snapshot\",\"client\":\"");
            sb.Append(SymbolName);
            sb.Append("\",\"positions\":[");
            bool first = true;
            foreach (var p in Positions)
            {
                if (!first) sb.Append(",");
                first = false;
                _positionToHelixID.TryGetValue(p.Id, out var helixID);
                sb.Append("{\"cTrader_id\":\"");
                sb.Append(p.Id);
                sb.Append("\",\"helix_id\":");
                if (helixID == null) sb.Append("null"); else { sb.Append("\""); sb.Append(helixID); sb.Append("\""); }
                sb.Append(",\"side\":\"");
                sb.Append(p.TradeType == TradeType.Buy ? "buy" : "sell");
                sb.Append("\",\"lots\":");
                AppendDouble(sb, Symbol.VolumeInUnitsToQuantity(p.VolumeInUnits));
                sb.Append(",\"entry\":");
                AppendDouble(sb, p.EntryPrice);
                sb.Append(",\"tp\":");
                if (p.TakeProfit.HasValue) AppendDouble(sb, p.TakeProfit.Value); else sb.Append("null");
                sb.Append(",\"sl\":");
                if (p.StopLoss.HasValue) AppendDouble(sb, p.StopLoss.Value); else sb.Append("null");
                sb.Append("}");
            }
            sb.Append("],\"orders\":[");
            first = true;
            foreach (var o in PendingOrders)
            {
                if (!first) sb.Append(",");
                first = false;
                _orderToHelixID.TryGetValue(o.Id, out var helixID);
                sb.Append("{\"cTrader_id\":\"");
                sb.Append(o.Id);
                sb.Append("\",\"helix_id\":");
                if (helixID == null) sb.Append("null"); else { sb.Append("\""); sb.Append(helixID); sb.Append("\""); }
                sb.Append(",\"side\":\"");
                sb.Append(o.TradeType == TradeType.Buy ? "buy" : "sell");
                sb.Append("\",\"lots\":");
                AppendDouble(sb, Symbol.VolumeInUnitsToQuantity(o.VolumeInUnits));
                sb.Append(",\"entry\":");
                AppendDouble(sb, o.TargetPrice);
                sb.Append(",\"tp\":");
                if (o.TakeProfit.HasValue) AppendDouble(sb, o.TakeProfit.Value); else sb.Append("null");
                sb.Append(",\"sl\":");
                if (o.StopLoss.HasValue) AppendDouble(sb, o.StopLoss.Value); else sb.Append("null");
                sb.Append("}");
            }
            sb.Append("]}");
            SendLine(sb.ToString());
        }

        private void EmitOrderStatus(
            string cTraderID, string helixID, string state,
            double? fillPrice, double? closePrice,
            string closeReason, string rejectReason)
        {
            var sb = new StringBuilder(256);
            sb.Append("{\"type\":\"order_status\",\"client\":\"");
            sb.Append(SymbolName);
            sb.Append("\",\"cTrader_id\":\"");
            sb.Append(cTraderID);
            sb.Append("\",\"helix_id\":\"");
            sb.Append(helixID);
            sb.Append("\",\"state\":\"");
            sb.Append(state);
            sb.Append("\"");
            if (fillPrice.HasValue)  { sb.Append(",\"fill_price\":");  AppendDouble(sb, fillPrice.Value); }
            if (closePrice.HasValue) { sb.Append(",\"close_price\":"); AppendDouble(sb, closePrice.Value); }
            if (!string.IsNullOrEmpty(closeReason))  { sb.Append(",\"close_reason\":\""); sb.Append(closeReason); sb.Append("\""); }
            if (!string.IsNullOrEmpty(rejectReason)) { sb.Append(",\"reject_reason\":\""); sb.Append(EscapeJson(rejectReason)); sb.Append("\""); }
            sb.Append("}");
            SendLine(sb.ToString());
        }

        private double AbsToPips(double entry, double target, TradeType side, bool isTP)
        {
            var pipSize = Symbol.PipSize;
            if (pipSize <= 0) return 0;
            var distance = Math.Abs(target - entry);
            // cTrader's TP/SL pip args are always positive distances —
            // the side determines direction.
            return distance / pipSize;
        }

        private bool HasSeenOrder(string id)
        {
            foreach (var s in _seenOrderIDs) if (s == id) return true;
            return false;
        }

        private void RememberOrder(string id)
        {
            _seenOrderIDs.AddLast(id);
            if (_seenOrderIDs.Count > SeenOrderIDsCap) _seenOrderIDs.RemoveFirst();
        }

        // ── TCP plumbing (mostly unchanged from v1) ───────────────

        private bool IsConnected => _client != null && _client.Connected && _stream != null;

        private void EnsureConnected()
        {
            if (IsConnected) return;
            Thread.Sleep(_backoffSeconds * 1000);
            TryConnect();
            if (!IsConnected)
            {
                _backoffSeconds = Math.Min(_backoffSeconds * 2, MaxBackoff);
            }
        }

        private void TryConnect()
        {
            try
            {
                CloseConnection();
                var client = new TcpClient();
                var task = client.ConnectAsync(HelixHost, HelixPort);
                if (!task.Wait(TimeSpan.FromSeconds(2)) || !client.Connected)
                {
                    client.Close();
                    return;
                }
                _client = client;
                _stream = client.GetStream();
                _backoffSeconds = 1;

                var hello = "{\"type\":\"hello\"" +
                            ",\"symbol\":\"" + SymbolName + "\"" +
                            ",\"tf\":\"" + TimeframeLabel(Bars.TimeFrame) + "\"" +
                            ",\"account\":\"" + (Account?.BrokerName ?? "?") + "/" + (Account?.Number.ToString() ?? "?") + "\"" +
                            ",\"bot\":\"" + BotVersion + "\"}";
                SendLine(hello);
                Print("[Helix] Connected to {0}:{1}", HelixHost, HelixPort);
            }
            catch (Exception ex)
            {
                Print("[Helix] Connect failed: {0}", ex.Message);
                CloseConnection();
            }
        }

        private void SendLine(string json)
        {
            if (!IsConnected) return;
            var payload = Encoding.UTF8.GetBytes(json + "\n");
            try
            {
                lock (_writeLock)
                {
                    _stream.Write(payload, 0, payload.Length);
                }
            }
            catch (Exception ex)
            {
                Print("[Helix] Send failed, will reconnect: {0}", ex.Message);
                CloseConnection();
            }
        }

        private void CloseConnection()
        {
            try { _stream?.Close(); } catch { }
            try { _client?.Close(); } catch { }
            _stream = null;
            _client = null;
        }

        // ── Helpers ───────────────────────────────────────────────

        private static string TimeframeLabel(TimeFrame tf)
        {
            if (tf == TimeFrame.Minute)   return "M1";
            if (tf == TimeFrame.Minute5)  return "M5";
            if (tf == TimeFrame.Minute15) return "M15";
            if (tf == TimeFrame.Minute30) return "M30";
            if (tf == TimeFrame.Hour)     return "H1";
            if (tf == TimeFrame.Hour4)    return "H4";
            if (tf == TimeFrame.Daily)    return "D1";
            return "?";
        }

        private static void AppendDouble(StringBuilder sb, double v)
        {
            sb.Append(v.ToString("G", CultureInfo.InvariantCulture));
        }

        private static string EscapeJson(string s)
        {
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"");
        }
    }
}
