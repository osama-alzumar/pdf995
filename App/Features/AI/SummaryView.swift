import SwiftUI
import PDFEngine
import WaraqaCore

/// AI summary with the page and quote behind every point, plus questions about the file.
/// Only points whose quote was found in the file (checked on the server and again here) appear.
struct SummaryView: View {
    @Environment(\.appLanguage) private var lang
    let summary: SummarizeResponse
    let file: PickedFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Label(lang.t("الملخص", "Summary"), systemImage: "text.append").font(.headline)
                Text(summary.overview).font(.body).textSelection(.enabled)
                ForEach(summary.points) { point in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6).padding(.top, 8)
                            Text(point.text).textSelection(.enabled)
                        }
                        ForEach(point.citations) { CitationRow(citation: $0) }
                    }
                }
                Button {
                    UIPasteboard.general.string = ([summary.overview] + summary.points.map { "• " + $0.text }).joined(separator: "\n")
                } label: { Label(lang.t("نسخ الملخص", "Copy summary"), systemImage: "doc.on.doc") }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .card()
            if let file { AskView(file: file) }
        }
    }
}

struct CitationRow: View {
    @Environment(\.appLanguage) private var lang
    let citation: Citation

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "quote.opening").font(.caption2).foregroundStyle(Theme.secondaryText)
            Text("«\(citation.quote)» — ") + Text(lang.t("ص \(citation.page)", "p. \(citation.page)")).bold()
        }
        .font(.caption)
        .foregroundStyle(Theme.secondaryText)
        .padding(.leading, 14)
        .accessibilityElement(children: .combine)
    }
}

/// Questions about the document. Answers show their supporting quotes; when the file doesn't
/// contain the answer, that is said plainly.
struct AskView: View {
    @Environment(\.appLanguage) private var lang
    let file: PickedFile

    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: AskResponse?
        var error: WaraqaError?
    }

    @State private var question = ""
    @State private var exchanges: [Exchange] = []
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(lang.t("اسأل عن الملف", "Ask about the file"), systemImage: "bubble.left.and.text.bubble.right").font(.headline)
            T("يُرسل نص الملف مع كل سؤال إلى خادم المعالجة، ولا يُحفظ هناك.", "The file's text is sent with each question to the processing server and isn't kept there.")
                .font(.caption).foregroundStyle(Theme.secondaryText)
            ForEach(exchanges) { exchange in
                VStack(alignment: .leading, spacing: 6) {
                    Text(exchange.question).font(.subheadline.weight(.semibold))
                    if let answer = exchange.answer {
                        if answer.found {
                            Text(answer.answer).textSelection(.enabled)
                            ForEach(answer.citations) { CitationRow(citation: $0) }
                        } else {
                            Label(lang.t("لم أجد إجابة لهذا السؤال في الملف.", "I couldn't find an answer to this in the file."),
                                  systemImage: "questionmark.circle")
                                .foregroundStyle(.orange)
                        }
                    } else if let error = exchange.error {
                        Text(lang.t(error.message)).foregroundStyle(Theme.danger).font(.footnote)
                    } else {
                        ProgressView()
                    }
                }
                .padding(12)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
            HStack {
                TextField(lang.t("مثال: ما مدة العقد؟", "e.g. How long is the contract?"), text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(10)
                    .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                Button { ask() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(busy || question.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(lang.t("إرسال السؤال", "Send question"))
            }
        }
        .padding(16)
        .card()
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        question = ""
        busy = true
        exchanges.append(Exchange(question: q))
        let index = exchanges.count - 1
        let language = lang.rawValue
        Task {
            do {
                let texts = try await ToolJobs.background { try PDFEngine.pageTexts(PDFInput(url: file.url, password: file.password)) }
                let pages = AIPage.budgeted(texts.enumerated().map { AIPage(page: $0.offset + 1, text: $0.element) }).pages
                guard !pages.isEmpty else { throw WaraqaError.noTextFound }
                var response = try await ServerService.shared.withApprovedUpload { client in
                    try await client.postJSON("v1/ai/ask", body: AskRequest(pages: pages, question: q, language: language), as: AskResponse.self)
                }
                response.citations = QuoteVerifier.check(response.citations, in: pages).filter(\.verified)
                if response.citations.isEmpty {
                    response = AskResponse(found: false, answer: response.answer, citations: [])
                }
                exchanges[index].answer = response
            } catch {
                exchanges[index].error = ToolRunner.map(error)
            }
            busy = false
        }
    }
}
