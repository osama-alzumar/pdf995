import SwiftUI
import PDFKit
import PhotosUI
import PDFEngine
import WaraqaCore

/// Visual editor used by Edit PDF, Sign PDF and (to mark areas) Redact PDF. The original file
/// is never changed: items are handed back and drawn into a new copy.
struct PDFEditorView: View {
    enum Mode { case edit, sign, redact }

    @Environment(\.appLanguage) private var lang
    let file: PickedFile
    let mode: Mode
    let done: (_ items: [EditItem], _ redactAreas: [Int: [PageRect]]) -> Void

    @StateObject private var model: EditorModel
    @State private var document: PDFDocument?
    @State private var showSignature = false
    @State private var pendingPlacement: (page: Int, point: PagePoint)?
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var confirmDiscard = false

    init(file: PickedFile, mode: Mode, initialItems: [EditItem] = [],
         done: @escaping (_ items: [EditItem], _ redactAreas: [Int: [PageRect]]) -> Void) {
        self.file = file
        self.mode = mode
        self.done = done
        _model = StateObject(wrappedValue: EditorModel(items: initialItems))
    }

    private var tools: [EditorModel.Tool] {
        switch mode {
        case .edit: [.select, .text, .note, .image, .highlight, .ink, .rectangle, .ellipse, .arrow]
        case .sign: [.select, .signature, .text]
        case .redact: [.select, .redact]
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let document {
                    PDFCanvas(document: document, model: model) { page, point in
                        pendingPlacement = (page, point)
                        if model.tool == .signature { showSignature = true } else { showPhotoPicker = true }
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView().frame(maxHeight: .infinity)
                }
                if model.selected != nil { propertiesBar }
                toolBar
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang.t("إلغاء", "Cancel")) {
                        if model.items.isEmpty { done([], [:]) } else { confirmDiscard = true }
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!model.canUndo).accessibilityLabel(lang.t("تراجع", "Undo"))
                    Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!model.canRedo).accessibilityLabel(lang.t("إعادة", "Redo"))
                    Button(lang.t("تم", "Done")) { finish() }
                        .fontWeight(.semibold)
                        .disabled(model.items.isEmpty)
                }
            }
            .confirmationDialog(lang.t("تجاهل التعديلات؟", "Discard your changes?"), isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button(lang.t("تجاهل", "Discard"), role: .destructive) { done([], [:]) }
            }
            .alert(model.textPrompt?.isNote == true ? lang.t("ملاحظة", "Note") : lang.t("نص", "Text"),
                   isPresented: Binding(get: { model.textPrompt != nil }, set: { if !$0 { model.textPrompt = nil } })) {
                TextField(lang.t("اكتب هنا", "Type here"), text: Binding(
                    get: { model.textPrompt?.text ?? "" }, set: { model.textPrompt?.text = $0 }))
                Button(lang.t("تم", "Done")) {
                    if let prompt = model.textPrompt { model.commitText(prompt) }
                    model.textPrompt = nil
                }
                Button(lang.t("إلغاء", "Cancel"), role: .cancel) { model.textPrompt = nil }
            }
            .sheet(isPresented: $showSignature) {
                SignatureSheet { data in
                    showSignature = false
                    if let data, let spot = pendingPlacement {
                        model.addImage(data, pageIndex: spot.page, center: spot.point, isSignature: true)
                    }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let spot = pendingPlacement {
                        model.addImage(data, pageIndex: spot.page, center: spot.point, isSignature: false)
                    }
                    photoItem = nil
                }
            }
        }
        .task {
            let doc = PDFDocument(url: file.url)
            if let password = file.password { _ = doc?.unlock(withPassword: password) }
            document = doc
            if mode == .sign { model.tool = .signature }
            if mode == .redact { model.tool = .redact }
        }
    }

    private var title: String {
        switch mode {
        case .edit: lang.t("تعديل PDF", "Edit PDF")
        case .sign: lang.t("اضغط حيث تريد التوقيع", "Tap where to sign")
        case .redact: lang.t("اسحب فوق ما تريد حذفه", "Drag over what to remove")
        }
    }

    private var toolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tools) { tool in
                    Button { model.tool = tool; if tool != .select { model.selectedID = nil } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tool.symbol).font(.app(.title3))
                            Text(lang.t(tool.title)).font(.app(.caption2))
                        }
                        .frame(minWidth: 58, minHeight: 50)
                        .foregroundStyle(model.tool == tool ? Color.white : Color.primary)
                        .background(model.tool == tool ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var propertiesBar: some View {
        HStack(spacing: 10) {
            if mode != .redact && model.selectedTakesColor {
                ForEach(EditorModel.palette, id: \.self) { hex in
                    Button { model.applyColor(hex) } label: {
                        Circle().fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(model.selected?.colorHex == hex ? Theme.accent : Color.secondary.opacity(0.3),
                                                     lineWidth: model.selected?.colorHex == hex ? 3 : 1))
                    }
                    .accessibilityLabel(hex)
                    .accessibilityIdentifier("palette.\(hex)")
                }
            }
            if mode != .redact {
                if let range = sizeRange {
                    Slider(value: Binding(get: { currentSize }, set: { model.applySize($0) }), in: range)
                        .frame(minWidth: 80)
                        .accessibilityLabel(lang.t("الحجم", "Size"))
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash") }
                .accessibilityLabel(lang.t("حذف", "Delete"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var sizeRange: ClosedRange<Double>? {
        switch model.selected?.kind {
        case .text?: 8...72
        case .rectangle?, .ellipse?, .line?, .ink?: 1...12
        default: nil
        }
    }

    private var currentSize: Double {
        switch model.selected?.kind {
        case .text(_, let size, _)?: size
        case .rectangle(_, let w)?, .ellipse(_, let w)?, .line(let w, _)?, .ink(_, let w)?: w
        default: 1
        }
    }

    private func finish() {
        if mode == .redact {
            var areas: [Int: [PageRect]] = [:]
            for item in model.items { areas[item.pageIndex, default: []].append(standardized(item.rect)) }
            done([], areas)
        } else {
            done(model.items, [:])
        }
    }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
