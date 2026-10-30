import SwiftUI
import WaraqaCore

/// Page-by-page differences: added words in green, removed words struck through in red.
struct ComparisonView: View {
    @Environment(\.appLanguage) private var lang
    let comparison: DocumentComparison
    @State private var showUnchanged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            let pages = showUnchanged ? comparison.pages : comparison.changedPages
            if comparison.changedPages.isEmpty {
                NoteBox(systemImage: "equal.circle", text: lang.t("لا توجد فروق في النص بين النسختين.", "The two versions have the same text."), tint: .green)
            }
            ForEach(pages) { page in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(lang.t("صفحة \(page.id + 1)", "Page \(page.id + 1)")).font(.app(.headline, .bold))
                        Spacer()
                        if !page.summary.isIdentical {
                            Text("+\(page.summary.insertedWords)  −\(page.summary.deletedWords)")
                                .font(.app(.caption).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Text(attributed(page.segments))
                        .font(.app(.body))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .card()
            }
            if !comparison.changedPages.isEmpty {
                Toggle(lang.t("اعرض الصفحات المتطابقة أيضاً", "Show unchanged pages too"), isOn: $showUnchanged)
            }
            NoteBox(systemImage: "info.circle", text: lang.t(
                "المقارنة تتم على النص. التغييرات في الصور أو التنسيق فقط لا تظهر هنا.",
                "The comparison is on the text. Changes to images or formatting alone aren't shown."))
        }
    }

    private var summary: some View {
        let total = comparison.total
        return HStack {
            stat("\(comparison.changedPages.count)", lang.t("صفحات متغيرة", "changed pages"))
            stat("+\(total.insertedWords)", lang.t("كلمات مضافة", "words added"), .green)
            stat("−\(total.deletedWords)", lang.t("كلمات محذوفة", "words removed"), .red)
            stat("\(total.similarityPercent)٪", lang.t("تطابق", "similar"))
        }
        .padding(12)
        .card()
    }

    private func stat(_ value: String, _ label: String, _ color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.app(.headline, .bold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.app(.caption2)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func attributed(_ segments: [TextDiff.Segment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text + " ")
            // Explicit SwiftUI types: with UIKit also imported, bare `.green` / `.single` are ambiguous.
            switch segment.kind {
            case .equal:
                part.foregroundColor = Color.primary
            case .inserted:
                part.foregroundColor = Color.green
                part.backgroundColor = Color.green.opacity(0.15)
            case .deleted:
                part.foregroundColor = Color.red
                part.strikethroughStyle = Text.LineStyle(pattern: .solid, color: .red)
                part.backgroundColor = Color.red.opacity(0.12)
            }
            result += part
        }
        return result
    }
}
