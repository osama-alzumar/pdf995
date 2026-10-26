import SwiftUI
import PDFKit
import PDFEngine
import WaraqaCore

/// Fill a PDF form in place (PDFKit's own field editing) or add new fillable fields.
/// Saving writes a new copy; the original stays as it was.
struct FormsView: View {
    @Environment(\.appLanguage) private var lang
    let file: PickedFile

    @State private var document: PDFDocument?
    @State private var fieldCount = 0
    @State private var addMode: PDFEngine.NewFormField.Kind?
    @State private var result: ToolOutput?
    @State private var error: WaraqaError?
    @State private var addedCount = 0

    var body: some View {
        VStack(spacing: 0) {
            if let output = result {
                ScrollView {
                    ResultView(tool: .forms, output: output, recents: [], sourceFiles: [file]) { result = nil }
                        .padding(Theme.gutter)
                }
            } else if let document {
                FormCanvas(document: document, addMode: $addMode) { added in
                    addedCount += 1
                    fieldCount += added
                }
                bottomBar
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationTitle(lang.t("نماذج PDF", "PDF forms"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if result == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button(lang.t("حفظ نسخة", "Save copy")) { save() }.fontWeight(.semibold)
                }
            }
        }
        .alert(lang.t("تنبيه", "Notice"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(lang.t("حسناً", "OK"), role: .cancel) {}
        } message: { Text(error.map { lang.t($0.message) } ?? "") }
        .task {
            let doc = PDFDocument(url: file.url)
            if let password = file.password { _ = doc?.unlock(withPassword: password) }
            document = doc
            fieldCount = (try? PDFEngine.formFields(PDFInput(url: file.url, password: file.password)).count) ?? 0
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Text(fieldCount == 0
                 ? lang.t("لا توجد حقول قابلة للتعبئة. أضف حقولاً ثم اضغط عليها لتعبئتها.", "No fillable fields. Add fields, then tap them to fill.")
                 : lang.t("اضغط على أي حقل لتعبئته (\(fieldCount) حقل).", "Tap any field to fill it (\(fieldCount) fields)."))
                .font(.footnote).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 10) {
                Button { addMode = addMode == .text ? nil : .text } label: {
                    Label(lang.t("حقل نصي", "Text field"), systemImage: "character.cursor.ibeam")
                }
                .buttonStyle(.bordered).tint(addMode == .text ? Theme.accent : .secondary)
                Button { addMode = addMode == .checkbox ? nil : .checkbox } label: {
                    Label(lang.t("مربع اختيار", "Checkbox"), systemImage: "checkmark.square")
                }
                .buttonStyle(.bordered).tint(addMode == .checkbox ? Theme.accent : .secondary)
            }
            if addMode != nil {
                T("اضغط على الصفحة حيث تريد الحقل.", "Tap the page where the field should go.").font(.footnote).foregroundStyle(Theme.accent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func save() {
        guard let document else { return }
        do {
            let folder = try FileStore.shared.newOutputFolder()
            let url = folder.appendingPathComponent(FileNaming.output(for: file.name, suffix: lang.t("معبأ", "filled"), extension: "pdf"))
            guard document.write(to: url) else { throw WaraqaError.writeFailed }
            try PDFEngine.validate(url, expectedPages: document.pageCount)
            let recent = FileStore.shared.record(url, tool: .forms)
            result = ToolOutput(files: [url], extra: nil)
            _ = recent
        } catch let e as WaraqaError {
            error = e
        } catch {
            self.error = .writeFailed
        }
    }
}

private struct FormCanvas: UIViewRepresentable {
    let document: PDFDocument
    @Binding var addMode: PDFEngine.NewFormField.Kind?
    let added: (Int) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .secondarySystemBackground
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) { context.coordinator.parent = self }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: FormCanvas
        weak var view: PDFView?
        private var counter = 0
        init(parent: FormCanvas) { self.parent = parent }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { parent.addMode != nil }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let kind = parent.addMode, let view, let page = view.page(for: g.location(in: view), nearest: true) else { return }
            let p = view.convert(g.location(in: view), to: page)
            counter += 1
            let size = kind == .text ? CGSize(width: 180, height: 24) : CGSize(width: 18, height: 18)
            let widget = PDFAnnotation(bounds: CGRect(x: p.x, y: p.y - size.height / 2, width: size.width, height: size.height),
                                       forType: .widget, withProperties: nil)
            widget.fieldName = "field_\(Int(Date().timeIntervalSince1970))_\(counter)"
            if kind == .text {
                widget.widgetFieldType = .text
                widget.font = .systemFont(ofSize: 12)
                widget.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
            } else {
                widget.widgetFieldType = .button
                widget.widgetControlType = .checkBoxControl
            }
            widget.border = PDFBorder()
            widget.border?.lineWidth = 1
            page.addAnnotation(widget)
            parent.addMode = nil
            parent.added(1)
        }
    }
}
