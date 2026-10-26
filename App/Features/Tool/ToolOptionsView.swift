import SwiftUI
import PhotosUI
import PDFEngine
import WaraqaCore

/// Only the options a tool really needs, with sensible defaults so most users just press Run.
struct ToolOptionsView: View {
    @Environment(\.appLanguage) private var lang
    let tool: ToolID
    @Binding var options: ToolOptions
    let file: PickedFile?
    @State private var watermarkPhoto: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch tool {
            case .split: split
            case .removePages, .extractPages: pagesField(tool == .removePages
                ? lang.t("الصفحات المراد حذفها", "Pages to remove") : lang.t("الصفحات المراد استخراجها", "Pages to extract"))
            case .rotate: rotate
            case .compress: compress
            case .ocr, .scanToPDF: ocr
            case .imagesToPDF: images
            case .pdfToImages: pdfToImages
            case .pageNumbers: pageNumbers
            case .watermark: watermark
            case .crop: crop
            case .protect: protect
            case .redact: redact
            case .summarize: summary
            case .translate: translate
            default: EmptyView()
            }
        }
    }

    // MARK: Organize

    private var split: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(lang.t("طريقة التقسيم", "Split by"), selection: $options.splitMode) {
                Text(lang.t("كل صفحة", "Every page")).tag(ToolOptions.SplitChoice.everyPage)
                Text(lang.t("كل عدد", "Every N")).tag(ToolOptions.SplitChoice.everyN)
                Text(lang.t("نطاقات", "Ranges")).tag(ToolOptions.SplitChoice.ranges)
            }
            .pickerStyle(.segmented)
            if options.splitMode == .everyN {
                Stepper(value: $options.splitEvery, in: 1...500) {
                    Text(lang.t("كل \(options.splitEvery) صفحات في ملف", "\(options.splitEvery) pages per file"))
                }
            }
            if options.splitMode == .ranges {
                pagesField(lang.t("النطاقات (كل نطاق ملف)", "Ranges (one file each)"), placeholder: "1-3, 4-10")
            }
        }
    }

    private func pagesField(_ title: String, placeholder: String = "1-3, 5, 8") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            TextField(placeholder, text: $options.pageText)
                .keyboardType(.numbersAndPunctuation)
                .environment(\.layoutDirection, .leftToRight)
                .padding(12)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            if !options.selectedPages.isEmpty {
                Text(lang.t("محدد من المعاينة: ", "Selected in preview: ") + PageSelection.describe(Array(options.selectedPages)))
                    .font(.footnote).foregroundStyle(Theme.accent)
            } else {
                T("اكتب الأرقام، أو اضغط على الصفحات في المعاينة لتحديدها.", "Type numbers, or tap pages in the preview to select them.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var rotate: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(lang.t("الاتجاه", "Direction"), selection: $options.rotation) {
                Label(lang.t("يمين ٩٠°", "Right 90°"), systemImage: "rotate.right").tag(90)
                Label(lang.t("١٨٠°", "180°"), systemImage: "arrow.2.squarepath").tag(180)
                Label(lang.t("يسار ٩٠°", "Left 90°"), systemImage: "rotate.left").tag(270)
            }
            .pickerStyle(.segmented)
            Toggle(lang.t("كل الصفحات", "All pages"), isOn: $options.rotateAll)
            if !options.rotateAll { pagesField(lang.t("الصفحات", "Pages")) }
        }
    }

    // MARK: Optimize

    private var compress: some View {
        VStack(spacing: 8) {
            ForEach(CompressionLevel.allCases) { level in
                Button { options.compression = level } label: {
                    HStack {
                        Image(systemName: options.compression == level ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lang.t(level.title)).font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text(lang.t(level.detail)).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(options.compression == level ? .isSelected : [])
            }
        }
    }

    private var ocr: some View {
        VStack(alignment: .leading, spacing: 10) {
            if tool == .scanToPDF {
                Toggle(lang.t("اجعل النص قابلاً للبحث والنسخ", "Make text searchable and copyable"), isOn: $options.makeSearchable)
            }
            if tool == .ocr || options.makeSearchable {
                T("لغة المستند", "Document language").font(.subheadline.weight(.semibold))
                Toggle(lang.t("العربية", "Arabic"), isOn: $options.ocrArabic)
                Toggle(lang.t("الإنجليزية", "English"), isOn: $options.ocrEnglish)
                if options.ocrArabic && !OCREngine.supportsArabic() {
                    if ServerService.shared.isConfigured && tool == .ocr {
                        Toggle(lang.t("استخدم خادم المعالجة للعربية", "Use the processing server for Arabic"), isOn: $options.useServer)
                        NoteBox(systemImage: "info.circle", text: lang.t(
                            "التعرف على العربية غير متاح محلياً في إصدار iOS هذا. يمكن إرسال الملف إلى الخادم بعد موافقتك.",
                            "Arabic recognition isn't available on this iOS version. The file can be sent to the server with your consent."))
                    } else {
                        NoteBox(systemImage: "exclamationmark.triangle", text: lang.t(
                            "التعرف على العربية غير متاح على هذا الجهاز؛ سيُقرأ النص الإنجليزي فقط.",
                            "Arabic recognition isn't available on this device; only English text will be read."), tint: .orange)
                    }
                }
            }
        }
    }

    // MARK: Convert

    private var images: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(lang.t("حجم الصفحة", "Page size"), selection: $options.pageSize) {
                ForEach(PageSizeOption.allCases) { Text(lang.t($0.title)).tag($0) }
            }
            .pickerStyle(.segmented)
            if options.pageSize != .fit {
                Toggle(lang.t("هوامش بيضاء", "White margins"), isOn: Binding(
                    get: { options.imageMargin > 0 }, set: { options.imageMargin = $0 ? 24 : 0 }))
            }
        }
    }

    private var pdfToImages: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(lang.t("الصيغة", "Format"), selection: $options.imageFormat) {
                Text("JPG").tag(ImageExportFormat.jpeg)
                Text("PNG").tag(ImageExportFormat.png)
            }
            .pickerStyle(.segmented)
            Picker(lang.t("الجودة", "Quality"), selection: $options.imageDPI) {
                Text(lang.t("عادية", "Normal")).tag(150.0)
                Text(lang.t("عالية", "High")).tag(220.0)
                Text(lang.t("طباعة", "Print")).tag(300.0)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Edit

    private var pageNumbers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(lang.t("الموضع", "Position"), selection: $options.pageNumbers.position) {
                ForEach([PagePosition.bottomCenter, .bottomLeft, .bottomRight, .topCenter, .topLeft, .topRight]) {
                    Text(lang.t($0.title)).tag($0)
                }
            }
            Picker(lang.t("الشكل", "Style"), selection: $options.pageNumbers.style) {
                Text("1").tag(PageNumberOptions.Style.number)
                Text("1 / 10").tag(PageNumberOptions.Style.numberOfTotal)
                Text(lang.t("صفحة 1 من 10", "Page 1 of 10")).tag(PageNumberOptions.Style.wordy)
            }
            .pickerStyle(.segmented)
            Toggle(lang.t("أرقام عربية (١، ٢، ٣)", "Arabic-Indic digits (١، ٢، ٣)"), isOn: $options.pageNumbers.arabicDigits)
            Toggle(lang.t("تخطَّ الصفحة الأولى", "Skip the first page"), isOn: $options.pageNumbers.skipFirstPage)
            Stepper(value: $options.pageNumbers.startAt, in: 1...9999) {
                Text(lang.t("ابدأ من \(options.pageNumbers.startAt)", "Start at \(options.pageNumbers.startAt)"))
            }
        }
    }

    private var watermark: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(lang.t("نص العلامة، مثل: سري", "Watermark text, e.g. CONFIDENTIAL"), text: $options.watermark.text)
                .padding(12)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            PhotosPicker(selection: $watermarkPhoto, matching: .images) {
                Label(options.watermark.imageData == nil ? lang.t("أو استخدم صورة/شعاراً", "Or use an image/logo")
                                                         : lang.t("تم اختيار صورة — تغيير", "Image chosen — change"),
                      systemImage: "photo")
            }
            .onChange(of: watermarkPhoto) { _, item in
                Task { options.watermark.imageData = try? await item?.loadTransferable(type: Data.self) }
            }
            if options.watermark.imageData != nil {
                Button(lang.t("إزالة الصورة", "Remove image"), role: .destructive) { options.watermark.imageData = nil; watermarkPhoto = nil }
            }
            Picker(lang.t("التوزيع", "Layout"), selection: $options.watermark.layout) {
                Text(lang.t("مرة واحدة", "Once")).tag(WatermarkOptions.Layout.single)
                Text(lang.t("متكرر", "Tiled")).tag(WatermarkOptions.Layout.tiled)
            }
            .pickerStyle(.segmented)
            HStack {
                T("الشفافية", "Opacity")
                Slider(value: $options.watermark.opacity, in: 0.05...0.9)
                    .accessibilityValue("\(Int(options.watermark.opacity * 100))%")
            }
            HStack {
                T("الميلان", "Angle")
                Picker("", selection: $options.watermark.rotationDegrees) {
                    Text("0°").tag(0.0); Text("30°").tag(30.0); Text("45°").tag(45.0); Text("90°").tag(90.0)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var crop: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([(lang.t("أعلى", "Top"), \CropMargins.top), (lang.t("أسفل", "Bottom"), \CropMargins.bottom),
                     (lang.t("يمين", "Right"), \CropMargins.right), (lang.t("يسار", "Left"), \CropMargins.left)], id: \.0) { item in
                HStack {
                    Text(item.0).frame(width: 60, alignment: .leading)
                    Slider(value: Binding(get: { options.crop[keyPath: item.1] }, set: { options.crop[keyPath: item.1] = $0 }), in: 0...200, step: 2)
                    Text("\(Int(options.crop[keyPath: item.1]))").monospacedDigit().frame(width: 36)
                }
            }
            if let file {
                Button {
                    if let margins = try? PDFEngine.detectContentMargins(PDFInput(url: file.url, password: file.password), page: 0) {
                        options.crop = margins
                    }
                } label: { Label(lang.t("قص تلقائي للهوامش البيضاء", "Auto-trim white margins"), systemImage: "wand.and.rays") }
            }
            NoteBox(systemImage: "info.circle", text: lang.t(
                "القص يُخفي ما خارج الإطار في كل البرامج، لكنه لا يحذفه من الملف. لحذف معلومات حساسة استخدم أداة التنقيح.",
                "Cropping hides what's outside the frame in every viewer but doesn't delete it. To remove sensitive content, use Redact."))
        }
    }

    // MARK: Security

    private var protect: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(lang.t("كلمة المرور", "Password"), text: $options.newPassword)
                .textContentType(.newPassword)
                .padding(12).background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            SecureField(lang.t("تأكيد كلمة المرور", "Confirm password"), text: $options.confirmPassword)
                .textContentType(.newPassword)
                .padding(12).background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            if !options.confirmPassword.isEmpty && options.newPassword != options.confirmPassword {
                T("كلمتا المرور غير متطابقتين.", "The passwords don't match.").font(.footnote).foregroundStyle(Theme.danger)
            } else if !options.newPassword.isEmpty && options.newPassword.count < 6 {
                T("يُنصح بست خانات على الأقل.", "At least six characters are recommended.").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var redact: some View {
        VStack(alignment: .leading, spacing: 8) {
            T("نصوص تريد حذفها (سطر لكل نص)", "Text to remove (one per line)").font(.subheadline.weight(.semibold))
            TextEditor(text: $options.redactTerms)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            if !options.redactAreas.isEmpty {
                Text(lang.t("مناطق محددة يدوياً: \(options.redactAreas.values.map(\.count).reduce(0, +))",
                            "Areas marked by hand: \(options.redactAreas.values.map(\.count).reduce(0, +))"))
                    .font(.footnote).foregroundStyle(Theme.accent)
            }
            NoteBox(systemImage: "checkmark.shield", text: lang.t(
                "التنقيح هنا حذف حقيقي: الصفحات المنقحة تُعاد رسمها كصور بلا النص المخفي، ثم يُفحص الملف للتأكد من عدم بقاء النص.",
                "This is real redaction: affected pages are re-drawn as images without the hidden text, then the file is checked to confirm it's gone."),
                tint: .green)
        }
    }

    // MARK: AI

    private var summary: some View {
        Picker(lang.t("طول الملخص", "Summary length"), selection: $options.summaryLength) {
            ForEach(SummaryLength.allCases) { Text(lang.t($0.title)).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var translate: some View {
        Picker(lang.t("الترجمة إلى", "Translate to"), selection: $options.targetLanguage) {
            ForEach(TranslationLanguage.supported) { Text(lang.t($0.name)).tag($0.code) }
        }
    }
}
