import SwiftUI

/// Add / edit form for a single trade-journal entry. Presented from the
/// Journal screen (blank draft) and from the AI analysis page (draft
/// pre-filled with the analysed position + a reference back to the run).
///
/// Works on a local @State copy so edits aren't committed until the
/// user hits Save; the parent owns persistence via `onSave`.
struct JournalEntrySheet: View {
    @State var entry: JournalEntry
    /// Window title — "New journal entry" vs "Edit journal entry".
    var heading: String = "New journal entry"
    var onSave: (JournalEntry) -> Void
    /// Present only when editing an existing row; shows a Delete button.
    var onDelete: (() -> Void)? = nil

    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Color.border)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if entry.hasAIReference { aiReferenceCard }
                    metaSection
                    positionSection
                    outcomeSection
                    notesSection
                }
                .padding(Theme.Spacing.xl)
            }
            Divider().background(Theme.Color.border)
            actions
        }
        .frame(width: 540, height: 660)
        .background(Theme.Color.surfaceHi)
    }

    // ── Header ────────────────────────────────────────────────────
    private var header: some View {
        HStack {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Color.accentStart)
            Text(heading)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(Theme.Spacing.lg)
    }

    // ── AI reference (read-only) ──────────────────────────────────
    private var aiReferenceCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.accentStart)
                Text("FROM AI ANALYSIS")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
            }
            HStack(spacing: 6) {
                if let engine = referencedEngine {
                    HStack(spacing: 4) {
                        EngineGlyph(kind: engine, size: 12)
                        Text(engine.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Color.surface))
                } else if let label = entry.aiEngineLabel {
                    refChip(label)
                }
                if let kind = entry.aiKindLabel { refChip(kind) }
                if let tf = entry.aiTimeframeLabel { refChip(tf) }
                Spacer()
            }
            if let excerpt = entry.aiReportExcerpt, !excerpt.isEmpty {
                ScrollView {
                    Text(excerpt)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 96)
                .padding(Theme.Spacing.sm)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.accentStart.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Color.accentStart.opacity(0.25), lineWidth: 1))
    }

    private func refChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.Color.surface))
    }

    private var referencedEngine: AIEngineKind? {
        guard let label = entry.aiEngineLabel else { return nil }
        return AIEngineKind.allCases.first { $0.label == label }
    }

    // ── Meta: pair / date / title ─────────────────────────────────
    private var metaSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.lg) {
                fieldLabeled("PAIR") {
                    Picker("", selection: Binding(
                        get: { entry.pairID },
                        set: { newID in
                            entry.pairID = newID
                            entry.pairName = app.pairs.first { $0.id == newID }?.name ?? entry.pairName
                        }
                    )) {
                        ForEach(app.pairs) { p in Text(p.name).tag(p.id) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                fieldLabeled("DATE") {
                    DatePicker("", selection: $entry.date, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                Spacer()
            }
            fieldLabeled("TITLE") {
                TextField("e.g. London breakout long", text: $entry.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }

    // ── Position ──────────────────────────────────────────────────
    private var positionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle("POSITION")
            fieldLabeled("SIDE") {
                Picker("", selection: $entry.side) {
                    ForEach(JournalEntry.Side.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            HStack(spacing: Theme.Spacing.lg) {
                numField("ENTRY", optional: $entry.entry)
                numField("TAKE PROFIT", optional: $entry.takeProfit)
                numField("STOP LOSS", optional: $entry.stopLoss)
                numField("LOTS", optional: $entry.lots)
            }
        }
    }

    // ── Outcome ───────────────────────────────────────────────────
    private var outcomeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle("OUTCOME")
            HStack(spacing: Theme.Spacing.lg) {
                fieldLabeled("RESULT") {
                    Picker("", selection: $entry.result) {
                        ForEach(JournalEntry.Result.allCases) { r in Text(r.label).tag(r) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                }
                fieldLabeled("PROFIT / LOSS") {
                    HStack(spacing: 4) {
                        TextField("0.00", text: plBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                            .font(.system(size: 12).monospacedDigit())
                        Text(plPreview)
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(entry.profitLoss >= 0 ? Theme.Color.success : Theme.Color.danger)
                    }
                }
                Spacer()
            }
        }
    }

    // ── Notes ─────────────────────────────────────────────────────
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionTitle("NOTES")
            TextEditor(text: $entry.notes)
                .font(.system(size: 12))
                .frame(height: 110)
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.border, lineWidth: 1))
        }
    }

    // ── Actions ───────────────────────────────────────────────────
    private var actions: some View {
        HStack {
            if let onDelete = onDelete {
                Button {
                    onDelete()
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.danger)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            SecondaryButton(title: "Cancel") { dismiss() }
            Button {
                onSave(entry)
                dismiss()
            } label: {
                Label("Save", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.success))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Spacing.lg)
    }

    // ── Building blocks ───────────────────────────────────────────
    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.8)
            .foregroundStyle(Theme.Color.textMuted)
    }

    private func fieldLabeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
            content()
        }
    }

    /// Optional-Double numeric field. Empty text ⇒ nil; any parseable
    /// number ⇒ that value. Prices/lots never legitimately equal 0, so
    /// a blank field is the clean "no value" representation.
    private func numField(_ label: String, optional binding: Binding<Double?>) -> some View {
        fieldLabeled(label) {
            TextField("—", text: Binding(
                get: { binding.wrappedValue.map(Self.numStr) ?? "" },
                set: { binding.wrappedValue = Double($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
            .font(.system(size: 12).monospacedDigit())
        }
    }

    private var plBinding: Binding<String> {
        Binding(
            get: { entry.profitLoss == 0 ? "" : Self.numStr(entry.profitLoss) },
            set: { entry.profitLoss = Double($0) ?? 0 }
        )
    }

    private var plPreview: String {
        entry.profitLoss == 0 ? "" : String(format: "%+.2f", entry.profitLoss)
    }

    private static func numStr(_ v: Double) -> String {
        String(format: "%g", v)
    }
}
