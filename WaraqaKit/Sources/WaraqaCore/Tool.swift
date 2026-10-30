import Foundation

/// Every tool Waraqa offers. The raw value is stable: it is stored in favorites and recents and
/// used as the server endpoint name for server-side tools.
public enum ToolID: String, CaseIterable, Codable, Sendable, Identifiable {
    // Organize
    case merge, split, removePages, extractPages, organize, scanToPDF
    // Optimize
    case compress, repair, ocr
    // Convert to PDF
    case imagesToPDF, wordToPDF, powerPointToPDF, excelToPDF, htmlToPDF
    // Convert from PDF
    case pdfToImages, pdfToWord, pdfToPowerPoint, pdfToExcel, pdfToPDFA, pdfToMarkdown
    // Edit
    case rotate, pageNumbers, watermark, crop, edit, forms
    // Security
    case unlock, protect, sign, redact, compare
    // AI
    case summarize, translate, intelligence
    // Images
    case convertImages, shrinkImages
    // Protection
    case removeWatermark

    public var id: String { rawValue }
}

public enum ToolCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case organize, optimize, convertToPDF, convertFromPDF, edit, images, security, ai

    public var id: String { rawValue }

    public var title: LocalizedText {
        switch self {
        case .organize: LocalizedText("تنظيم PDF", "Organize PDF")
        case .optimize: LocalizedText("تحسين وإصلاح", "Optimize & repair")
        case .convertToPDF: LocalizedText("التحويل إلى PDF", "Convert to PDF")
        case .convertFromPDF: LocalizedText("التحويل من PDF", "Convert from PDF")
        case .edit: LocalizedText("تعديل PDF", "Edit PDF")
        case .images: LocalizedText("أدوات الصور", "Image tools")
        case .security: LocalizedText("الحماية والتوقيع", "Security & signing")
        case .ai: LocalizedText("الذكاء الاصطناعي", "AI")
        }
    }

    public var symbol: String {
        switch self {
        case .organize: "square.grid.2x2"
        case .optimize: "wand.and.stars"
        case .convertToPDF: "arrow.down.doc"
        case .convertFromPDF: "arrow.up.doc"
        case .edit: "pencil.and.outline"
        case .images: "photo"
        case .security: "lock.shield"
        case .ai: "sparkles"
        }
    }
}

/// Where a tool does its work. This is shown to the user before anything leaves the device.
public enum Execution: String, Codable, Sendable {
    /// Entirely on the iPhone; works offline; files never leave the device.
    case onDevice
    /// Needs the Waraqa server. The file is uploaded only after explicit consent.
    case server
    /// On the device, with an optional server fallback the user can choose (e.g. OCR languages
    /// the device cannot read, or a damaged file the device cannot open).
    case onDeviceWithServerFallback
}

/// What a tool accepts as input.
public enum InputKind: String, Codable, Sendable {
    case singlePDF
    case multiplePDFs
    case twoPDFs
    case images
    case camera
    case word
    case powerPoint
    case excel
    case webPage
}

public struct ToolInfo: Sendable, Identifiable, Hashable {
    public let id: ToolID
    public let category: ToolCategory
    public let title: LocalizedText
    public let subtitle: LocalizedText
    public let symbol: String
    public let input: InputKind
    public let execution: Execution
    /// Extra words matched by search (synonyms in both languages).
    public let keywords: [String]
}

public enum ToolCatalog {
    public static let quickTools: [ToolID] = [.merge, .compress, .pdfToWord, .imagesToPDF]

    /// The file tools shown first in the "PDF tools" tab, in the order of the product brief.
    public static let featured: [ToolID] = [
        .imagesToPDF, .pdfToImages, .merge, .split, .compress, .organize, .rotate, .removePages, .extractPages,
        .wordToPDF, .pdfToWord, .sign, .pageNumbers, .crop, .convertImages, .shrinkImages, .watermark, .removeWatermark,
    ]

    public static func info(_ id: ToolID) -> ToolInfo {
        all.first { $0.id == id }!
    }

    public static func tools(in category: ToolCategory) -> [ToolInfo] {
        all.filter { $0.category == category }
    }

    public static let all: [ToolInfo] = [
        // MARK: Organize
        ToolInfo(id: .merge, category: .organize,
                 title: LocalizedText("دمج PDF", "Merge PDF"),
                 subtitle: LocalizedText("اجمع عدة ملفات في ملف واحد", "Combine several files into one"),
                 symbol: "square.stack.3d.down.forward", input: .multiplePDFs, execution: .onDevice,
                 keywords: ["جمع", "ضم", "combine", "join"]),
        ToolInfo(id: .split, category: .organize,
                 title: LocalizedText("تقسيم PDF", "Split PDF"),
                 subtitle: LocalizedText("افصل الصفحات إلى ملفات مستقلة", "Separate pages into files"),
                 symbol: "scissors", input: .singlePDF, execution: .onDevice,
                 keywords: ["فصل", "قسم", "separate", "divide"]),
        ToolInfo(id: .removePages, category: .organize,
                 title: LocalizedText("حذف صفحات", "Remove pages"),
                 subtitle: LocalizedText("احذف الصفحات التي لا تحتاجها", "Delete pages you don't need"),
                 symbol: "trash", input: .singlePDF, execution: .onDevice,
                 keywords: ["مسح", "ازالة", "delete"]),
        ToolInfo(id: .extractPages, category: .organize,
                 title: LocalizedText("استخراج صفحات", "Extract pages"),
                 subtitle: LocalizedText("انسخ صفحات محددة إلى ملف جديد", "Copy chosen pages to a new file"),
                 symbol: "doc.on.doc", input: .singlePDF, execution: .onDevice,
                 keywords: ["نسخ", "اختيار", "select", "pick"]),
        ToolInfo(id: .organize, category: .organize,
                 title: LocalizedText("ترتيب الصفحات", "Organize PDF"),
                 subtitle: LocalizedText("أعد الترتيب بالسحب والإفلات", "Reorder by drag and drop"),
                 symbol: "rectangle.grid.2x2", input: .singlePDF, execution: .onDevice,
                 keywords: ["ترتيب", "تنظيم", "reorder", "sort", "arrange"]),
        ToolInfo(id: .scanToPDF, category: .organize,
                 title: LocalizedText("المسح إلى PDF", "Scan to PDF"),
                 subtitle: LocalizedText("صوّر المستندات بالكاميرا", "Scan documents with the camera"),
                 symbol: "doc.viewfinder", input: .camera, execution: .onDevice,
                 keywords: ["كاميرا", "ماسح", "تصوير", "camera", "scanner"]),

        // MARK: Optimize
        ToolInfo(id: .compress, category: .optimize,
                 title: LocalizedText("ضغط PDF", "Compress PDF"),
                 subtitle: LocalizedText("قلّل حجم الملف", "Reduce file size"),
                 symbol: "arrow.down.right.and.arrow.up.left", input: .singlePDF, execution: .onDevice,
                 keywords: ["تصغير", "حجم", "shrink", "reduce", "size"]),
        ToolInfo(id: .repair, category: .optimize,
                 title: LocalizedText("إصلاح PDF", "Repair PDF"),
                 subtitle: LocalizedText("حاول استعادة ملف تالف", "Try to recover a damaged file"),
                 symbol: "bandage", input: .singlePDF, execution: .onDeviceWithServerFallback,
                 keywords: ["تالف", "معطوب", "استعادة", "fix", "broken", "corrupt"]),
        ToolInfo(id: .ocr, category: .optimize,
                 title: LocalizedText("التعرف على النص OCR", "OCR PDF"),
                 subtitle: LocalizedText("استخرج النص من المستندات المصورة", "Read text in scanned documents"),
                 symbol: "text.viewfinder", input: .singlePDF, execution: .onDeviceWithServerFallback,
                 keywords: ["نص", "قراءة", "بحث", "ممسوح", "text", "searchable", "recognize"]),

        // MARK: Convert to PDF
        ToolInfo(id: .imagesToPDF, category: .convertToPDF,
                 title: LocalizedText("الصور إلى PDF", "Images to PDF"),
                 subtitle: LocalizedText("JPG و PNG و HEIC في ملف واحد", "JPG, PNG and HEIC into one file"),
                 symbol: "photo.on.rectangle", input: .images, execution: .onDevice,
                 keywords: ["صورة", "صور", "jpg", "png", "heic", "photo", "image"]),
        ToolInfo(id: .wordToPDF, category: .convertToPDF,
                 title: LocalizedText("Word إلى PDF", "Word to PDF"),
                 subtitle: LocalizedText("حوّل مستندات DOC و DOCX", "Convert DOC and DOCX"),
                 symbol: "doc.richtext", input: .word, execution: .server,
                 keywords: ["وورد", "docx", "doc"]),
        ToolInfo(id: .powerPointToPDF, category: .convertToPDF,
                 title: LocalizedText("PowerPoint إلى PDF", "PowerPoint to PDF"),
                 subtitle: LocalizedText("حوّل العروض التقديمية", "Convert presentations"),
                 symbol: "rectangle.on.rectangle.angled", input: .powerPoint, execution: .server,
                 keywords: ["بوربوينت", "عرض", "pptx", "ppt", "slides"]),
        ToolInfo(id: .excelToPDF, category: .convertToPDF,
                 title: LocalizedText("Excel إلى PDF", "Excel to PDF"),
                 subtitle: LocalizedText("حوّل جداول البيانات", "Convert spreadsheets"),
                 symbol: "tablecells", input: .excel, execution: .server,
                 keywords: ["اكسل", "إكسل", "جدول", "xlsx", "xls", "sheet"]),
        ToolInfo(id: .htmlToPDF, category: .convertToPDF,
                 title: LocalizedText("صفحة ويب إلى PDF", "Web page to PDF"),
                 subtitle: LocalizedText("احفظ أي رابط كملف PDF", "Save any link as a PDF"),
                 symbol: "globe", input: .webPage, execution: .onDevice,
                 keywords: ["رابط", "موقع", "ويب", "html", "url", "website"]),

        // MARK: Convert from PDF
        ToolInfo(id: .pdfToImages, category: .convertFromPDF,
                 title: LocalizedText("PDF إلى صور", "PDF to images"),
                 subtitle: LocalizedText("كل صفحة كصورة JPG أو PNG", "Each page as JPG or PNG"),
                 symbol: "photo.stack", input: .singlePDF, execution: .onDevice,
                 keywords: ["صورة", "jpg", "png", "image"]),
        ToolInfo(id: .pdfToWord, category: .convertFromPDF,
                 title: LocalizedText("PDF إلى Word", "PDF to Word"),
                 subtitle: LocalizedText("مستند DOCX قابل للتعديل", "Editable DOCX document"),
                 symbol: "doc.text", input: .singlePDF, execution: .server,
                 keywords: ["وورد", "docx", "تعديل"]),
        ToolInfo(id: .pdfToPowerPoint, category: .convertFromPDF,
                 title: LocalizedText("PDF إلى PowerPoint", "PDF to PowerPoint"),
                 subtitle: LocalizedText("شرائح PPTX", "PPTX slides"),
                 symbol: "play.rectangle", input: .singlePDF, execution: .server,
                 keywords: ["بوربوينت", "عرض", "pptx", "slides"]),
        ToolInfo(id: .pdfToExcel, category: .convertFromPDF,
                 title: LocalizedText("PDF إلى Excel", "PDF to Excel"),
                 subtitle: LocalizedText("استخرج الجداول إلى XLSX", "Extract tables to XLSX"),
                 symbol: "tablecells.badge.ellipsis", input: .singlePDF, execution: .server,
                 keywords: ["اكسل", "إكسل", "جدول", "xlsx", "table"]),
        ToolInfo(id: .pdfToPDFA, category: .convertFromPDF,
                 title: LocalizedText("PDF إلى PDF/A", "PDF to PDF/A"),
                 subtitle: LocalizedText("صيغة الأرشفة طويلة الأمد", "Long-term archiving format"),
                 symbol: "archivebox", input: .singlePDF, execution: .server,
                 keywords: ["أرشفة", "ارشيف", "pdfa", "archive"]),
        ToolInfo(id: .pdfToMarkdown, category: .convertFromPDF,
                 title: LocalizedText("PDF إلى Markdown", "PDF to Markdown"),
                 subtitle: LocalizedText("نص منظم بالعناوين والقوائم", "Structured text with headings"),
                 symbol: "number", input: .singlePDF, execution: .onDevice,
                 keywords: ["ماركداون", "نص", "md", "markdown", "text"]),

        // MARK: Edit
        ToolInfo(id: .rotate, category: .edit,
                 title: LocalizedText("تدوير PDF", "Rotate PDF"),
                 subtitle: LocalizedText("دوّر صفحة أو كل الصفحات", "Rotate one or all pages"),
                 symbol: "rotate.right", input: .singlePDF, execution: .onDevice,
                 keywords: ["تدوير", "اتجاه", "turn"]),
        ToolInfo(id: .pageNumbers, category: .edit,
                 title: LocalizedText("أرقام الصفحات", "Page numbers"),
                 subtitle: LocalizedText("رقّم الصفحات تلقائياً", "Number pages automatically"),
                 symbol: "textformat.123", input: .singlePDF, execution: .onDevice,
                 keywords: ["ترقيم", "رقم", "numbering"]),
        ToolInfo(id: .watermark, category: .edit,
                 title: LocalizedText("علامة مائية", "Watermark"),
                 subtitle: LocalizedText("نص أو صورة فوق الصفحات", "Text or image over pages"),
                 symbol: "drop", input: .singlePDF, execution: .onDevice,
                 keywords: ["ختم", "شعار", "مائية", "stamp", "logo"]),
        ToolInfo(id: .crop, category: .edit,
                 title: LocalizedText("قص PDF", "Crop PDF"),
                 subtitle: LocalizedText("أزل الهوامش الزائدة", "Trim extra margins"),
                 symbol: "crop", input: .singlePDF, execution: .onDevice,
                 keywords: ["هوامش", "قص", "margins", "trim"]),
        ToolInfo(id: .edit, category: .edit,
                 title: LocalizedText("تعديل PDF", "Edit PDF"),
                 subtitle: LocalizedText("نصوص وصور وأشكال وتظليل", "Text, images, shapes, highlights"),
                 symbol: "pencil.tip.crop.circle", input: .singlePDF, execution: .onDevice,
                 keywords: ["كتابة", "تعليق", "تظليل", "رسم", "annotate", "highlight", "draw", "text"]),
        ToolInfo(id: .forms, category: .edit,
                 title: LocalizedText("نماذج PDF", "PDF forms"),
                 subtitle: LocalizedText("املأ الحقول أو أضف حقولاً جديدة", "Fill or add form fields"),
                 symbol: "list.bullet.rectangle", input: .singlePDF, execution: .onDevice,
                 keywords: ["نموذج", "تعبئة", "حقول", "form", "fill", "fields"]),

        // MARK: Security
        ToolInfo(id: .unlock, category: .security,
                 title: LocalizedText("فتح الحماية", "Unlock PDF"),
                 subtitle: LocalizedText("أزل كلمة المرور التي تعرفها", "Remove a password you know"),
                 symbol: "lock.open", input: .singlePDF, execution: .onDevice,
                 keywords: ["كلمة مرور", "فك", "password", "decrypt"]),
        ToolInfo(id: .protect, category: .security,
                 title: LocalizedText("حماية PDF", "Protect PDF"),
                 subtitle: LocalizedText("أضف كلمة مرور للملف", "Add a password"),
                 symbol: "lock", input: .singlePDF, execution: .onDevice,
                 keywords: ["كلمة مرور", "تشفير", "قفل", "password", "encrypt"]),
        ToolInfo(id: .sign, category: .security,
                 title: LocalizedText("توقيع PDF", "Sign PDF"),
                 subtitle: LocalizedText("ارسم توقيعك أو اكتبه", "Draw or type your signature"),
                 symbol: "signature", input: .singlePDF, execution: .onDevice,
                 keywords: ["توقيع", "امضاء", "إمضاء", "signature"]),
        ToolInfo(id: .redact, category: .security,
                 title: LocalizedText("تنقيح PDF", "Redact PDF"),
                 subtitle: LocalizedText("احذف المعلومات الحساسة نهائياً", "Permanently remove sensitive info"),
                 symbol: "eye.slash", input: .singlePDF, execution: .onDevice,
                 keywords: ["اخفاء", "إخفاء", "حجب", "سري", "hide", "censor", "black out"]),
        ToolInfo(id: .compare, category: .security,
                 title: LocalizedText("مقارنة PDF", "Compare PDF"),
                 subtitle: LocalizedText("اعرض الفروق بين نسختين", "Show differences between versions"),
                 symbol: "rectangle.split.2x1", input: .twoPDFs, execution: .onDevice,
                 keywords: ["فرق", "اختلاف", "نسخة", "diff", "difference"]),

        // MARK: AI
        ToolInfo(id: .summarize, category: .ai,
                 title: LocalizedText("تلخيص PDF", "Summarize PDF"),
                 subtitle: LocalizedText("ملخص قصير أو مفصل", "Short or detailed summary"),
                 symbol: "text.append", input: .singlePDF, execution: .server,
                 keywords: ["ملخص", "خلاصة", "summary", "ai"]),
        ToolInfo(id: .translate, category: .ai,
                 title: LocalizedText("ترجمة PDF", "Translate PDF"),
                 subtitle: LocalizedText("بين العربية والإنجليزية ولغات أخرى", "Arabic, English and more"),
                 symbol: "character.book.closed", input: .singlePDF, execution: .server,
                 keywords: ["ترجمة", "لغة", "translate", "language"]),
        ToolInfo(id: .intelligence, category: .ai,
                 title: LocalizedText("اسأل ملفك", "Ask your PDF"),
                 subtitle: LocalizedText("أسئلة وإجابات من نص الملف", "Answers grounded in the file"),
                 symbol: "bubble.left.and.text.bubble.right", input: .singlePDF, execution: .server,
                 keywords: ["سؤال", "تحليل", "استخراج", "ذكاء", "question", "ask", "analyze", "chat"]),

        // MARK: Images
        ToolInfo(id: .convertImages, category: .images,
                 title: LocalizedText("تحويل صيغ الصور", "Convert images"),
                 subtitle: LocalizedText("بين JPG و PNG و HEIC", "Between JPG, PNG and HEIC"),
                 symbol: "arrow.left.arrow.right.square", input: .images, execution: .onDevice,
                 keywords: ["صيغة", "jpg", "png", "heic", "تحويل", "format", "convert"]),
        ToolInfo(id: .shrinkImages, category: .images,
                 title: LocalizedText("تقليل حجم الصور", "Shrink images"),
                 subtitle: LocalizedText("صور أخف للإرسال", "Lighter images for sending"),
                 symbol: "photo.badge.arrow.down", input: .images, execution: .onDevice,
                 keywords: ["حجم", "تصغير", "ضغط", "resize", "smaller", "compress"]),

        // MARK: Protection
        ToolInfo(id: .removeWatermark, category: .security,
                 title: LocalizedText("إزالة علامة ورقة", "Remove Waraqa mark"),
                 subtitle: LocalizedText("استرجع النسخة الأصلية المحفوظة", "Get back the saved original"),
                 symbol: "drop.halffull", input: .singlePDF, execution: .onDevice,
                 keywords: ["إزالة", "علامة", "أصل", "remove", "original", "watermark"]),
    ]
}
