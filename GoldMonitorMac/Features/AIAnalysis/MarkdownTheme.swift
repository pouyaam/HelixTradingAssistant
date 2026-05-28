import SwiftUI
import MarkdownUI

/// MarkdownUI theme tuned to the dashboard's dark palette. Used by the
/// AI analysis pane so streamed Claude markdown renders with proper
/// hierarchy (headers, bullets, code fences) instead of as flat text.
///
/// We pin font sizes to the same scale the rest of the analysis card
/// uses (10-12-14-16pt) so the markdown sits comfortably in the panel
/// alongside the kind/engine pickers and action row above/below.
extension Theme {
    static let goldMarkdown = MarkdownUI.Theme()
        .text {
            ForegroundColor(Theme.Color.textPrimary)
            FontSize(13)
        }
        .strong {
            FontWeight(.bold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .code {
            FontFamilyVariant(.monospaced)
            BackgroundColor(Theme.Color.surface)
            ForegroundColor(Theme.Color.textSecondary)
        }
        .link {
            ForegroundColor(Theme.Color.accentStart)
        }
        .heading1 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(18)
                    ForegroundColor(Theme.Color.textPrimary)
                }
                .markdownMargin(top: 14, bottom: 8)
        }
        .heading2 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(15)
                    ForegroundColor(Theme.Color.textPrimary)
                }
                .markdownMargin(top: 12, bottom: 6)
        }
        .heading3 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(13)
                    ForegroundColor(Theme.Color.textPrimary)
                }
                .markdownMargin(top: 10, bottom: 4)
        }
        .paragraph { config in
            config.label
                .lineSpacing(4)
                .markdownMargin(top: 0, bottom: 10)
        }
        .listItem { config in
            // Tighten list items so multi-bullet sections (Claude's
            // typical output) don't take up the whole pane.
            config.label.markdownMargin(top: 0, bottom: 4)
        }
        .codeBlock { config in
            ScrollView(.horizontal) {
                config.label
                    .relativeLineSpacing(.em(0.225))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.95))
                        ForegroundColor(Theme.Color.textPrimary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .markdownMargin(top: 6, bottom: 8)
        }
        .blockquote { config in
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.Color.textMuted.opacity(0.4))
                    .frame(width: 3)
                config.label
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.vertical, 4)
            }
            .markdownMargin(top: 6, bottom: 8)
        }
}
