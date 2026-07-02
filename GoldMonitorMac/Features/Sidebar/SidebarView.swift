import SwiftUI

/// CleanMyMac X-style left sidebar. Three sections:
///   1. Brand header with gradient logo badge
///   2. Top-level nav (Dashboard / News / Portfolio / Settings)
///   3. Pair list — color-coded rows with live prices
///
/// Width is fixed at 240pt — same as the web app's sidebar — to keep the
/// design consistent across products.
struct SidebarView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var notificationInbox: NotificationInbox

    // Market visibility — set by the Settings page. Hidden
    // categories drop out of the sidebar entirely (their pairs
    // remain in the DB and reappear when toggled back on).
    @AppStorage("markets.forex.enabled")   private var forexEnabled: Bool = true
    @AppStorage("markets.crypto.enabled")  private var cryptoEnabled: Bool = true
    @AppStorage("markets.indices.enabled") private var indicesEnabled: Bool = true

    /// Persisted category ordering — comma-joined list of
    /// `TradingPair.Category.rawValue` strings. Empty string falls
    /// back to `allCases` order. Drag-and-drop reorders write a
    /// new comma list here.
    @AppStorage("sidebar.categoryOrder") private var categoryOrderRaw: String = ""
    /// Persisted per-category pair ordering — one comma-joined
    /// list of pair IDs per category, keyed `sidebar.pairOrder.<cat>`.
    /// Pairs not in the saved list fall to the end in catalog order
    /// so newly-added symbols don't get hidden by stale ordering.
    @AppStorage("sidebar.pairOrder.forex")   private var pairOrderForex: String = ""
    @AppStorage("sidebar.pairOrder.crypto")  private var pairOrderCrypto: String = ""
    @AppStorage("sidebar.pairOrder.indices") private var pairOrderIndices: String = ""

    /// Local drag-state — tracks which row is being dragged and
    /// where it's hovering. Used to draw the drop indicator and
    /// commit the move on release. Plain `@State` because this is
    /// strictly ephemeral UI.
    @State private var draggingCategory: TradingPair.Category? = nil
    @State private var draggingPair: String? = nil

    private func isMarketEnabled(_ category: TradingPair.Category) -> Bool {
        switch category {
        case .forex:   return forexEnabled
        case .crypto:  return cryptoEnabled
        case .indices: return indicesEnabled
        }
    }

    /// Categories in the user's preferred display order, filtered
    /// down to enabled markets. Falls back to `allCases` order when
    /// no preference is set OR when the saved list has drifted
    /// (e.g. a new category was added in a later version — we
    /// append it at the end rather than dropping it).
    private var orderedCategories: [TradingPair.Category] {
        let saved = categoryOrderRaw.split(separator: ",")
            .compactMap { TradingPair.Category(rawValue: String($0)) }
        let union = saved + TradingPair.Category.allCases.filter { !saved.contains($0) }
        return union.filter { isMarketEnabled($0) }
    }

    /// Pair binding for a category — chooses the right AppStorage
    /// slot so each category persists independently.
    private func pairOrderBinding(_ category: TradingPair.Category) -> Binding<String> {
        switch category {
        case .forex:   return $pairOrderForex
        case .crypto:  return $pairOrderCrypto
        case .indices: return $pairOrderIndices
        }
    }

    /// Pairs for a category in the user's preferred order, with
    /// any newly-discovered IDs appended at the end. Returns
    /// `TradingPair` rows already-resolved from `app.pairs` so the
    /// caller can render without re-looking-up.
    private func orderedPairs(in category: TradingPair.Category) -> [TradingPair] {
        let pool = app.pairs.filter { $0.category == category }
        let savedIDs = pairOrderBinding(category).wrappedValue
            .split(separator: ",")
            .map(String.init)
        let known = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
        let ordered = savedIDs.compactMap { known[$0] }
        let leftovers = pool.filter { p in !savedIDs.contains(p.id) }
        return ordered + leftovers
    }

    /// Persist a fresh category ordering after a drag commit.
    private func saveCategoryOrder(_ order: [TradingPair.Category]) {
        categoryOrderRaw = order.map(\.rawValue).joined(separator: ",")
    }

    /// Persist a fresh pair ordering for one category after a
    /// drag commit. Writes the full list — drift-correction
    /// happens at read time via `orderedPairs`.
    private func savePairOrder(_ order: [TradingPair], in category: TradingPair.Category) {
        let raw = order.map(\.id).joined(separator: ",")
        pairOrderBinding(category).wrappedValue = raw
    }

    /// Move category `dragged` to the position currently occupied
    /// by `target`. Both must be enabled (the user can't reorder
    /// against a hidden one). No-op when they're equal or one
    /// can't be located.
    private func reorderCategories(dragging: TradingPair.Category, before target: TradingPair.Category) {
        guard dragging != target else { return }
        var order = orderedCategories
        guard let from = order.firstIndex(of: dragging) else { return }
        order.remove(at: from)
        if let to = order.firstIndex(of: target) {
            order.insert(dragging, at: to)
        } else {
            order.append(dragging)
        }
        // Carry over disabled categories at the end so toggling
        // them back on later doesn't lose their relative position.
        let disabled = TradingPair.Category.allCases.filter { !isMarketEnabled($0) }
        saveCategoryOrder(order + disabled.filter { !order.contains($0) })
    }

    /// Move pair `draggedID` within its category to the position
    /// currently occupied by `targetID`. Both must be in the
    /// same category — we don't support cross-category drags.
    private func reorderPair(in category: TradingPair.Category, draggedID: String, before targetID: String) {
        guard draggedID != targetID else { return }
        var order = orderedPairs(in: category)
        guard let from = order.firstIndex(where: { $0.id == draggedID }) else { return }
        let item = order.remove(at: from)
        if let to = order.firstIndex(where: { $0.id == targetID }) {
            order.insert(item, at: to)
        } else {
            order.append(item)
        }
        savePairOrder(order, in: category)
    }

    var body: some View {
        VStack(spacing: 0) {
            brand
                .padding(.horizontal, Theme.Spacing.lg)
                // .windowStyle(.hiddenTitleBar) keeps the
                // traffic-light buttons floating in the top-left
                // of the window — they paint at roughly
                // y=0…28pt, overlapping anything we draw at the
                // top of the sidebar. Push the brand down past
                // them so the icon + title clear the controls.
                .padding(.top, 36)
                .padding(.bottom, Theme.Spacing.md)

            Divider().background(Theme.Color.border)

            navSection
                .padding(.vertical, Theme.Spacing.md)

            Divider().background(Theme.Color.border)

            pairsSection

            Spacer(minLength: 0)

            footer
                .padding(Theme.Spacing.md)
        }
        .frame(width: 240)
        .background(Theme.Color.surface)
    }

    // ── Brand ──────────────────────────────────────────────────────
    private var brand: some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: 32, height: 32)
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Helix Trading")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Helix Trading Club · v0.1")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            Spacer()
        }
    }

    // ── Top-level nav ──────────────────────────────────────────────
    private var navSection: some View {
        VStack(spacing: 2) {
            ForEach(SidebarItem.allCases) { item in
                SidebarRow(
                    item: item,
                    isSelected: app.selectedSidebarItem == item,
                    badgeCount: item == .inbox ? notificationInbox.unreadCount : 0,
                    action: { app.selectedSidebarItem = item }
                )
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
    }

    // ── Pair list ──────────────────────────────────────────────────
    //
    // Grouped by `TradingPair.Category` so the user reads the sidebar
    // as three distinct markets — Iran (Toman gold sellers), Metal
    // (XAU/USD ounce), Crypto (BTC/SOL/ETH). Empty categories are
    // skipped so a future "only-crypto" build wouldn't show empty
    // section headers.
    private var pairsSection: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(orderedCategories, id: \.self) { category in
                    let pairsInCategory = orderedPairs(in: category)
                    if !pairsInCategory.isEmpty {
                        // Section header is the drag handle for
                        // the category — dropping another header
                        // onto it reorders the categories.
                        sectionHeader(category)
                        ForEach(pairsInCategory) { pair in
                            PairRow(
                                pair: pair,
                                isSelected: app.selectedPairID == pair.id,
                                action: {
                                    app.selectedPairID = pair.id
                                    app.selectedSidebarItem = .dashboard
                                }
                            )
                            // Drag source: capture the pair ID
                            // we're moving so the drop target
                            // knows what to insert.
                            .onDrag {
                                draggingPair = pair.id
                                return NSItemProvider(object: "pair:\(pair.id)" as NSString)
                            }
                            // Drop target: accept the dragged
                            // pair ID and move it to this row's
                            // position. We restrict the cross-
                            // category drag at the reorder helper
                            // — if the user drops a pair onto a
                            // different category's row, we no-op
                            // rather than implement migration
                            // semantics.
                            .onDrop(of: [.text], isTargeted: nil) { providers in
                                guard let provider = providers.first else { return false }
                                _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                                    guard let raw = obj as? String,
                                          raw.hasPrefix("pair:")
                                    else { return }
                                    let draggedID = String(raw.dropFirst("pair:".count))
                                    // Only reorder when the
                                    // dragged pair is in this
                                    // category — cross-category
                                    // drag is not supported.
                                    guard app.pairs.first(where: { $0.id == draggedID })?.category == category
                                    else { return }
                                    DispatchQueue.main.async {
                                        reorderPair(in: category, draggedID: draggedID, before: pair.id)
                                        draggingPair = nil
                                    }
                                }
                                return true
                            }
                            .opacity(draggingPair == pair.id ? 0.4 : 1)
                        }
                    }
                }

                if app.pairs.isEmpty {
                    emptyPairsHint
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
        }
    }

    /// Section header for one category. Doubles as the drag
    /// handle + drop target for category reordering: drag the
    /// label up/down to swap entire markets around.
    private func sectionHeader(_ category: TradingPair.Category) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Color.textMuted.opacity(0.5))
            Text(category.label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.Color.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .onDrag {
            draggingCategory = category
            return NSItemProvider(object: "cat:\(category.rawValue)" as NSString)
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let raw = obj as? String,
                      raw.hasPrefix("cat:"),
                      let dragged = TradingPair.Category(rawValue: String(raw.dropFirst("cat:".count)))
                else { return }
                DispatchQueue.main.async {
                    reorderCategories(dragging: dragged, before: category)
                    draggingCategory = nil
                }
            }
            return true
        }
        .opacity(draggingCategory == category ? 0.5 : 1)
    }

    private var emptyPairsHint: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Color.textMuted)
            Text("No data yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Import a database to get started.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.lg)
    }

    // ── Footer ─────────────────────────────────────────────────────
    private var footer: some View {
        Button {
            app.showWizard = true
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                Text("Setup wizard")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.Color.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.Color.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// ── Top-level nav row ──────────────────────────────────────────────
private struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    var badgeCount: Int = 0
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .frame(width: 18, height: 18)
                Text(item.label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                Spacer()
                if badgeCount > 0 {
                    Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.Color.danger))
                }
            }
            .foregroundStyle(isSelected
                ? Theme.Color.textPrimary
                : (hovered ? Theme.Color.textSecondary : Theme.Color.textMuted))
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 7)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Color.surfaceMax)
        } else if hovered {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Color.surfaceHi)
        }
    }
}
