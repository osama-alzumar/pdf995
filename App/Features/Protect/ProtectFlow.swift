import SwiftUI
import PDFEngine
import WaraqaCore

/// State of one "protect a document" run: pick → customize → (hide data) → result.
@MainActor
final class ProtectFlow: ObservableObject {
    enum Step: Int { case pick, edit, hide, result }

    @Published var step: Step = .pick
    @Published private(set) var source: PickedFile?
    @Published private(set) var originals: [PickedFile] = []
    @Published private(set) var isImageInput = false
    @Published private(set) var pageCount = 0
    @Published var spec = ProtectionSpec()
    @Published var previewPage = 0
    @Published private(set) var preview: UIImage?
    @Published private(set) var previewing = false
    @Published private(set) var analysis: DocumentAnalysis?
    @Published private(set) var analyzing = false
    @Published var areas: [SensitiveArea] = []
    @Published var manualAreas: [Int: [PageRect]] = [:]
    @Published var exportImages = false
    @Published var error: WaraqaError?
    @Published private(set) var working = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var outputs: [URL] = []
    @Published var needsPurchase: ProtectionQuota.Denial?
    @Published private(set) var savedToVault = false
    @Published private(set) var paidWith: ProtectionQuota.Source?

    private var previewTask: Task<Void, Never>?
    private var work: URL?

    var output: URL? { outputs.first }
    var displayName: String { originals.first.map { FileNaming.stem(of: $0.name) } ?? "Waraqa" }

    var redactMap: [Int: [PageRect]] {
        var map = manualAreas
        for a in areas where a.hidden { map[a.pageIndex, default: []].append(a.rect) }
        return map
    }

    var hiddenCount: Int { areas.filter(\.hidden).count + manualAreas.values.reduce(0) { $0 + $1.count } }

    init(language: AppLanguage, files: [PickedFile] = []) {
        spec.language = language
        if !files.isEmpty { Task { await load(files) } }
    }

    // MARK: Loading

    func load(_ files: [PickedFile]) async {
        guard !files.isEmpty else { return }
        originals = files
        error = nil
        working = true
        defer { working = false }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Protect-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            work = folder
            let images = files.allSatisfy { !$0.isPDF }
            isImageInput = images
            exportImages = images
            if images {
                let pdf = folder.appendingPathComponent("images.pdf")
                let urls = files.map(\.url)
                try await ToolJobs.background { try PDFEngine.imagesToPDF(urls.map { .file($0) }, pageSize: .fit, to: pdf) }
                source = PickedFile(url: pdf, name: (files.first?.name ?? "Waraqa") + ".pdf")
            } else {
                guard let first = files.first(where: \.isPDF) else { throw WaraqaError.unsupportedFile(fileName: files[0].name) }
                source = first
            }
            pageCount = (try? PDFEngine.pageCount(source!.url, password: source!.password)) ?? 1
            previewPage = 0
            step = .edit
            schedulePreview(immediate: true)
            if UserDefaults.standard.object(forKey: "smartSuggestion") as? Bool ?? true { analyze() }
        } catch {
            self.error = ToolRunner.map(error)
        }
    }

    // MARK: Live preview (rendered by the engine from a real protected page)

    /// Renders at most one preview at a time: changes made while one is rendering (e.g. dragging
    /// a slider) are collected and only the latest settings are rendered next. Rendering in
    /// parallel used enough memory on photo documents for iOS to close the app.
    func schedulePreview(immediate: Bool = false) {
        guard source != nil else { return }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 220_000_000) }
            guard !Task.isCancelled, let self else { return }
            self.previewWanted = true
            await self.renderPreviews()
        }
    }

    private var previewWanted = false
    private var previewRunning = false

    private func renderPreviews() async {
        guard !previewRunning else { return }
        previewRunning = true
        previewing = true
        defer { previewRunning = false; previewing = false }
        while previewWanted, let source {
            previewWanted = false
            let spec = self.spec, page = previewPage, areas = redactMap
            // Not cancelled with the debounce task, so one render always finishes and frees its memory.
            let box = try? await Task.detached(priority: .userInitiated) {
                try autoreleasepool {
                    ImageBox(image: try PDFEngine.protectionPreview(PDFInput(url: source.url, password: source.password), spec: spec,
                                                                    redactAreas: areas, page: page, maxPixels: 1000))
                }
            }.value
            if let box { preview = UIImage(cgImage: box.image) }
        }
    }

    // MARK: Smart suggestion + sensitive data (on the device)

    func analyze() {
        guard let source, !analyzing else { return }
        analyzing = true
        Task {
            let result = try? await ToolJobs.background {
                try PDFEngine.analyze(PDFInput(url: source.url, password: source.password), maxPages: 6)
            }
            analysis = result
            areas = result?.areas ?? []
            analyzing = false
            schedulePreview()
        }
    }

    func applySuggestion() {
        guard let kind = analysis?.kind, kind != .other else { return }
        spec.purpose = kind.suggestedPurpose
        spec.style = kind.suggestedStyle
        schedulePreview()
    }

    // MARK: Protect

    func protect(entitlement: Entitlement) async {
        guard let source else { return }
        let check = QuotaStore.shared.quota.check(entitlement: entitlement, pages: pageCount)
        let paid: ProtectionQuota.Source
        switch check {
        case .failure(let denial):
            needsPurchase = denial
            return
        case .success(let s):
            paid = s
        }
        working = true
        progress = 0
        error = nil
        defer { working = false }
        do {
            let folder = try FileStore.shared.newOutputFolder()
            let lang = spec.language
            let name = FileNaming.output(for: displayName, suffix: lang.t("محمي", "protected"), extension: "pdf")
            let pdf = folder.appendingPathComponent(name)
            let spec = self.spec, map = redactMap, isImages = isImageInput && exportImages
            let report: @Sendable (Double) -> Void = { value in Task { @MainActor [weak self] in self?.progress = value } }
            let input = PDFInput(url: source.url, password: source.password)
            let base = displayName
            let files: [URL] = try await ToolJobs.background {
                try PDFEngine.protect(input, spec: spec, redactAreas: map, to: pdf, progress: { report($0 * (isImages ? 0.8 : 1)) })
                guard isImages else { return [pdf] }
                let images = try PDFEngine.pdfToImages(PDFInput(url: pdf), format: .jpeg, dpi: 200, into: folder,
                                                       baseName: base + "-" + lang.t("محمي", "protected") + ".jpg",
                                                       progress: { report(0.8 + $0 * 0.2) })
                return [pdf] + images
            }
            QuotaStore.shared.update { $0.consume(paid) }
            paidWith = paid
            outputs = files
            for file in files { FileStore.shared.record(file, tool: .watermark) }
            step = .result
        } catch {
            self.error = ToolRunner.map(error)
        }
    }

    /// Stores the protected copy (and, if wanted, the original) encrypted in "My documents".
    func saveToVault(folder: String, keepOriginal: Bool) {
        guard let pdf = output else { return }
        do {
            var originalID: UUID?
            if keepOriginal, let original = originals.first {
                let originalFile = isImageInput ? (source?.url ?? original.url) : original.url
                originalID = try VaultStore.shared.add(file: originalFile, title: displayName + " — " + spec.language.t("الأصل", "original"),
                                                       folder: folder, kind: .original, pages: pageCount).id
            }
            try VaultStore.shared.add(file: pdf, title: FileNaming.stem(of: pdf.lastPathComponent), folder: folder, kind: .protected,
                                      originalID: originalID, spec: spec, pages: pageCount)
            savedToVault = true
        } catch {
            self.error = ToolRunner.map(error)
        }
    }

    func reset() {
        previewTask?.cancel()
        if let work { try? FileManager.default.removeItem(at: work) }
    }
}

/// Carries a CGImage out of a background task.
struct ImageBox: @unchecked Sendable {
    let image: CGImage
}
