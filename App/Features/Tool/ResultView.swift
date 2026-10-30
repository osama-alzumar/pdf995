import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import WaraqaCore

/// Success screen: what was produced, how big it is, and Save / Share / Open. PDF results can be
/// passed straight to another tool (merge → compress → sign → save).
struct ResultView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.appLanguage) private var lang
    let tool: ToolID
    let output: ToolOutput
    let recents: [RecentItem]
    let sourceFiles: [PickedFile]
    let startOver: () -> Void

    @State private var exporting = false
    @State private var previewURL: URL?
    @State private var showNextTool = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !output.files.isEmpty {
                successHeader
                fileList
                actions
            }
            if let extra = output.extra {
                ExtraView(extra: extra, sourceFile: sourceFiles.first)
            }
            Button(lang.t("ابدأ من جديد", "Start over"), action: startOver)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .fileExporter(isPresented: $exporting, items: output.files.map { ExportedFile(url: $0) }, contentTypes: [.data]) { result in
            if case .success = result { saved = true }
        }
        .quickLookPreview($previewURL, in: output.files)
        .sheet(isPresented: $showNextTool) {
            NextToolSheet { next in
                showNextTool = false
                if let url = output.files.first {
                    app.open(next, with: [PickedFile(url: url, name: url.lastPathComponent)])
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var successHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.success)
                .symbolEffect(.bounce, value: output.files.count)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                T("تم بنجاح", "Done").font(.app(.title3, .bold))
                Text(output.files.count == 1 ? lang.t("ملف واحد جاهز", "1 file ready") : lang.t("\(output.files.count) ملفات جاهزة", "\(output.files.count) files ready"))
                    .font(.app(.subheadline)).foregroundStyle(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var fileList: some View {
        VStack(spacing: 8) {
            ForEach(output.files.prefix(30), id: \.self) { url in
                Button { previewURL = url } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: url)).font(.app(.title2)).foregroundStyle(Theme.accent).frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.app(.subheadline, .medium)).foregroundStyle(.primary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Text(ByteSize.format(size(of: url), language: lang)).font(.app(.caption)).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "eye").foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                }
                .buttonStyle(.plain)
                .accessibilityHint(lang.t("فتح الملف", "Open the file"))
            }
            if output.files.count > 30 {
                Text(lang.t("و\(output.files.count - 30) ملفات أخرى", "and \(output.files.count - 30) more"))
                    .font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            PrimaryButton(title: saved ? lang.t("تم الحفظ ✓ — احفظ مرة أخرى", "Saved ✓ — save again") : lang.t("حفظ في الملفات", "Save to Files"),
                          systemImage: "square.and.arrow.down") { exporting = true }
            HStack(spacing: 10) {
                ShareLink(items: output.files) {
                    Label(lang.t("مشاركة", "Share"), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: Theme.smallRadius))
                SecondaryButton(title: lang.t("فتح", "Open"), systemImage: "doc.text.magnifyingglass") { previewURL = output.files.first }
            }
            if output.files.count == 1, output.files[0].pathExtension.lowercased() == "pdf" {
                SecondaryButton(title: lang.t("تابع بأداة أخرى", "Continue with another tool"), systemImage: "arrow.forward.circle") {
                    showNextTool = true
                }
            }
            T("محفوظ أيضاً في «ملفاتي».", "Also kept in “My files”.").font(.app(.caption)).foregroundStyle(Theme.secondaryText)
        }
    }

    private func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "docx": "doc.text"
        case "pptx": "play.rectangle"
        case "xlsx": "tablecells"
        case "jpg", "png": "photo"
        case "md": "number"
        default: "doc"
        }
    }
}

/// Lets the system "Save to Files" exporter write our result files.
struct ExportedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { SentTransferredFile($0.url) }
    }
}

/// Tools that accept a single PDF, offered after a PDF result (chained actions).
struct NextToolSheet: View {
    @Environment(\.appLanguage) private var lang
    let choose: (ToolID) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(ToolCategory.allCases) { category in
                    let tools = ToolCatalog.tools(in: category).filter { $0.input == .singlePDF }
                    if !tools.isEmpty {
                        Section(lang.t(category.title)) {
                            ForEach(tools) { tool in
                                Button { choose(tool.id) } label: { ToolRow(tool: tool) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle(lang.t("الخطوة التالية", "Next step"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Extra results: savings, recognized text, comparison, AI output…
struct ExtraView: View {
    @Environment(\.appLanguage) private var lang
    let extra: ToolExtra
    let sourceFile: PickedFile?

    var body: some View {
        switch extra {
        case .compression(let report):
            CompressionSummary(report: report)
        case .text(let text, let title):
            TextResult(title: lang.t(title), text: text)
        case .comparison(let comparison):
            ComparisonView(comparison: comparison)
        case .summary(let summary):
            SummaryView(summary: summary, file: sourceFile)
        case .translation(let pages):
            TextResult(title: lang.t("الترجمة", "Translation"),
                       text: pages.map { lang.t("— صفحة \($0.page) —", "— Page \($0.page) —") + "\n" + $0.text }.joined(separator: "\n\n"))
        case .redaction(let report):
            NoteBox(systemImage: "checkmark.shield.fill", text: lang.t(
                "تم حذف \(report.redactedAreas) منطقة من \(report.redactedPages.count) صفحة حذفاً نهائياً، وتم التحقق من عدم إمكانية استخراج النص المحذوف من الملف الناتج. الصفحات المنقحة أصبحت صوراً.",
                "\(report.redactedAreas) area(s) on \(report.redactedPages.count) page(s) were permanently removed, and the result was checked: the removed text can't be extracted. Redacted pages are now images."),
                    tint: .green)
        case .info(let text):
            NoteBox(systemImage: "info.circle", text: lang.t(text))
        }
    }
}

struct CompressionSummary: View {
    @Environment(\.appLanguage) private var lang
    let report: CompressionReport

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                stat(lang.t("قبل", "Before"), ByteSize.format(report.originalBytes, language: lang))
                Image(systemName: lang.isRightToLeft ? "arrow.left" : "arrow.right").foregroundStyle(.secondary)
                stat(lang.t("بعد", "After"), ByteSize.format(report.compressedBytes, language: lang))
            }
            if report.isSmaller {
                Text(lang.t("وفّرت \(report.savedPercent)٪ (\(ByteSize.format(report.savedBytes, language: lang)))",
                            "Saved \(report.savedPercent)% (\(ByteSize.format(report.savedBytes)))"))
                    .font(.app(.headline, .bold)).foregroundStyle(Theme.success)
            } else {
                Text(lang.t("الملف مضغوط مسبقاً؛ لم يكن ممكناً تصغيره بهذا المستوى، فاحتفظنا بالنسخة الأصلية.",
                            "The file is already compact; it couldn't be made smaller at this level, so the original was kept."))
                    .font(.app(.subheadline)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .card()
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.app(.caption)).foregroundStyle(Theme.secondaryText)
            Text(value).font(.app(.title3, .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }
}

struct TextResult: View {
    @Environment(\.appLanguage) private var lang
    let title: String
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.app(.headline, .bold))
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? lang.t("تم النسخ", "Copied") : lang.t("نسخ النص", "Copy text"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            ScrollView {
                Text(text.isEmpty ? lang.t("لا يوجد نص.", "No text.") : text)
                    .font(.app(.body))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .card()
    }
}
