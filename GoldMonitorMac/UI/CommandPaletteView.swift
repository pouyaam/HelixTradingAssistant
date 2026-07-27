import SwiftUI
import AppKit

/// Command item representation in the palette with a stable identifier for 120Hz performance.
struct CommandPaletteItem: Identifiable, Hashable {
    let id: String // Stable unique key (e.g. "pair_ounce", "nav_dashboard")
    let category: String
    let title: String
    let subtitle: String?
    let icon: String
    let action: () -> Void

    static func == (lhs: CommandPaletteItem, rhs: CommandPaletteItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Fast, 120Hz Command Palette (Cmd + K) overlay for native macOS app with full keyboard navigation.
struct CommandPaletteView: View {
    @EnvironmentObject private var app: AppState
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var eventMonitor: Any?

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack {
            // Semi-transparent backdrop — click to dismiss
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            // Command Card Window
            VStack(spacing: 0) {
                // Search Input Header
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Color.accentStart)

                    TextField("Type a command, symbol, timeframe, or AI action...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .focused($isSearchFocused)
                        .onSubmit {
                            executeCurrentSelection()
                        }

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.Color.textMuted)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("ESC")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.Color.surfaceHi)
                        .foregroundStyle(Theme.Color.textMuted)
                        .cornerRadius(4)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, 14)
                .background(Theme.Color.surfaceHi.opacity(0.6))

                Divider()
                    .overlay(Theme.Color.border)

                // Scrollable Item List
                let currentItems = filteredItems

                if currentItems.isEmpty {
                    VStack(spacing: Theme.Spacing.sm) {
                        Spacer()
                        Image(systemName: "exclamationmark.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(Theme.Color.textMuted)
                        Text("No matching commands found")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Color.textMuted)
                        Spacer()
                    }
                    .frame(height: 280)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(currentItems.enumerated()), id: \.element.id) { index, item in
                                    let isSelected = index == selectedIndex

                                    Button {
                                        item.action()
                                        isPresented = false
                                    } label: {
                                        HStack(spacing: Theme.Spacing.md) {
                                            Image(systemName: item.icon)
                                                .font(.system(size: 14))
                                                .frame(width: 22, height: 22)
                                                .foregroundStyle(isSelected ? Theme.Color.accentStart : Theme.Color.textSecondary)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.title)
                                                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                                    .foregroundStyle(isSelected ? Theme.Color.textPrimary : Theme.Color.textPrimary.opacity(0.9))

                                                if let sub = item.subtitle {
                                                    Text(sub)
                                                        .font(.system(size: 11))
                                                        .foregroundStyle(Theme.Color.textMuted)
                                                }
                                            }

                                            Spacer()

                                            Text(item.category)
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(isSelected ? Theme.Color.accentStart.opacity(0.25) : Theme.Color.surfaceHi)
                                                .foregroundStyle(isSelected ? Theme.Color.accentStart : Theme.Color.textMuted)
                                                .cornerRadius(4)
                                        }
                                        .padding(.horizontal, Theme.Spacing.md)
                                        .padding(.vertical, 8)
                                        .background(isSelected ? Theme.Color.accentStart.opacity(0.15) : Color.clear)
                                        .cornerRadius(Theme.Radius.sm)
                                    }
                                    .buttonStyle(.plain)
                                    .id(item.id)
                                }
                            }
                            .padding(Theme.Spacing.sm)
                        }
                        .contentShape(Rectangle())
                        .frame(maxHeight: 340)
                        .onChange(of: selectedIndex) { newIdx in
                            if newIdx >= 0 && newIdx < currentItems.count {
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    proxy.scrollTo(currentItems[newIdx].id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 580)
            .glassmorphicCard(cornerRadius: Theme.Radius.lg)
            .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 12)
        }
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
            attachKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
        .onChange(of: query) { _ in
            selectedIndex = 0
        }
    }

    private func attachKeyboardMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isPresented else { return event }

            let items = filteredItems
            let count = items.count

            switch event.keyCode {
            case 125: // Down Arrow
                if count > 0 {
                    selectedIndex = (selectedIndex + 1) % count
                }
                return nil // consume
            case 126: // Up Arrow
                if count > 0 {
                    selectedIndex = (selectedIndex - 1 + count) % count
                }
                return nil // consume
            case 36: // Return / Enter
                executeCurrentSelection()
                return nil
            case 53: // Escape
                isPresented = false
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func executeCurrentSelection() {
        let items = filteredItems
        guard !items.isEmpty, selectedIndex >= 0, selectedIndex < items.count else { return }
        items[selectedIndex].action()
        isPresented = false
    }

    private var filteredItems: [CommandPaletteItem] {
        let all = buildAllItems()
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return all
        }
        return all.filter { item in
            item.title.localizedCaseInsensitiveContains(query) ||
            item.category.localizedCaseInsensitiveContains(query) ||
            (item.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func buildAllItems() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // 1. Trading Pairs
        for pair in app.pairs {
            items.append(CommandPaletteItem(
                id: "pair_\(pair.id)",
                category: "Pairs",
                title: "Switch to \(pair.name)",
                subtitle: "\(pair.symbol) · \(pair.category.label)",
                icon: "chart.line.uptrend.xyaxis",
                action: {
                    app.selectedPairID = pair.id
                    app.selectedSidebarItem = .dashboard
                }
            ))
        }

        // 2. Navigation
        for sidebarItem in SidebarItem.allCases {
            items.append(CommandPaletteItem(
                id: "nav_\(sidebarItem.rawValue)",
                category: "Navigation",
                title: "Go to \(sidebarItem.label)",
                subtitle: nil,
                icon: sidebarItem.symbol,
                action: {
                    app.selectedSidebarItem = sidebarItem
                }
            ))
        }

        // 3. View Controls
        items.append(CommandPaletteItem(
            id: "view_fullscreen",
            category: "View",
            title: "Toggle Fullscreen Chart",
            subtitle: app.isChartFullscreen ? "Exit chart fullscreen" : "Enter chart fullscreen",
            icon: "arrow.up.left.and.arrow.down.right",
            action: {
                app.isChartFullscreen.toggle()
            }
        ))

        return items
    }
}
