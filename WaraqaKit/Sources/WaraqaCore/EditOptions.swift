import Foundation

/// A rectangle in PDF page space (origin bottom-left, points). Kept free of CoreGraphics so the
/// layout rules can be tested on Linux.
public struct PageRect: Equatable, Sendable, Codable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

public enum PagePosition: String, CaseIterable, Codable, Sendable, Identifiable {
    case topLeft, topCenter, topRight, center, bottomLeft, bottomCenter, bottomRight
    public var id: String { rawValue }

    public var title: LocalizedText {
        switch self {
        case .topLeft: LocalizedText("أعلى اليسار", "Top left")
        case .topCenter: LocalizedText("أعلى الوسط", "Top center")
        case .topRight: LocalizedText("أعلى اليمين", "Top right")
        case .center: LocalizedText("الوسط", "Center")
        case .bottomLeft: LocalizedText("أسفل اليسار", "Bottom left")
        case .bottomCenter: LocalizedText("أسفل الوسط", "Bottom center")
        case .bottomRight: LocalizedText("أسفل اليمين", "Bottom right")
        }
    }

    /// Where a box of `size` goes inside `page`, `margin` points from the edges.
    public func place(width: Double, height: Double, in page: PageRect, margin: Double) -> PageRect {
        let x: Double
        switch self {
        case .topLeft, .bottomLeft: x = page.minX + margin
        case .topRight, .bottomRight: x = page.maxX - margin - width
        case .topCenter, .center, .bottomCenter: x = page.midX - width / 2
        }
        let y: Double
        switch self {
        case .topLeft, .topCenter, .topRight: y = page.maxY - margin - height
        case .center: y = page.midY - height / 2
        case .bottomLeft, .bottomCenter, .bottomRight: y = page.minY + margin
        }
        return PageRect(x: x, y: y, width: width, height: height)
    }
}

public struct PageNumberOptions: Equatable, Sendable {
    public enum Style: String, CaseIterable, Sendable, Identifiable {
        case number          // 3
        case numberOfTotal   // 3 / 10
        case wordy           // صفحة 3 من 10 | Page 3 of 10
        public var id: String { rawValue }
    }

    public var position: PagePosition = .bottomCenter
    public var style: Style = .number
    public var startAt: Int = 1
    public var skipFirstPage = false
    public var arabicDigits = false
    public var fontSize: Double = 11
    public var language: AppLanguage = .arabic

    public init() {}

    /// The label for page `index` (0-based) of `count`, or nil if the page is skipped.
    public func label(index: Int, count: Int) -> String? {
        if skipFirstPage && index == 0 { return nil }
        let offset = skipFirstPage ? 1 : 0
        let number = startAt + index - offset
        let total = startAt + count - 1 - offset
        let text: String
        switch style {
        case .number: text = "\(number)"
        case .numberOfTotal: text = "\(number) / \(total)"
        case .wordy: text = language == .arabic ? "صفحة \(number) من \(total)" : "Page \(number) of \(total)"
        }
        return arabicDigits ? Self.toArabicDigits(text) : text
    }

    public static func toArabicDigits(_ text: String) -> String {
        String(text.map { ch -> Character in
            guard let d = ch.wholeNumberValue, ch.isASCII else { return ch }
            return Character(UnicodeScalar(0x0660 + d)!)
        })
    }
}

public struct WatermarkOptions: Equatable, Sendable {
    public enum Layout: String, CaseIterable, Sendable, Identifiable {
        case single, tiled
        public var id: String { rawValue }
    }

    public var text: String = ""
    public var imageData: Data?
    public var opacity: Double = 0.25
    public var rotationDegrees: Double = 45
    public var fontSize: Double = 48
    public var colorHex: String = "#1F5FAD"
    public var layout: Layout = .single
    public var position: PagePosition = .center
    /// When nil every page gets the watermark.
    public var pages: [Int]?

    public init() {}

    public var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || imageData != nil
    }
}

/// Margins to trim, in points, applied to each page's crop box.
public struct CropMargins: Equatable, Sendable {
    public var top: Double, bottom: Double, left: Double, right: Double
    public init(top: Double = 0, bottom: Double = 0, left: Double = 0, right: Double = 0) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }

    /// The new crop box, or nil if the margins would leave less than 36pt on either axis.
    public func apply(to box: PageRect) -> PageRect? {
        let w = box.width - left - right
        let h = box.height - top - bottom
        guard w >= 36, h >= 36, left >= 0, right >= 0, top >= 0, bottom >= 0 else { return nil }
        return PageRect(x: box.x + left, y: box.y + bottom, width: w, height: h)
    }
}

public enum ImageExportFormat: String, CaseIterable, Sendable, Identifiable {
    case jpeg, png
    public var id: String { rawValue }
    public var fileExtension: String { self == .jpeg ? "jpg" : "png" }
}

public enum PageSizeOption: String, CaseIterable, Sendable, Identifiable {
    /// Each page takes the size of its image.
    case fit
    case a4
    case letter
    public var id: String { rawValue }

    public var title: LocalizedText {
        switch self {
        case .fit: LocalizedText("حسب الصورة", "Fit image")
        case .a4: LocalizedText("A4", "A4")
        case .letter: LocalizedText("Letter", "Letter")
        }
    }

    /// Portrait size in points, nil for `.fit`.
    public var size: (width: Double, height: Double)? {
        switch self {
        case .fit: nil
        case .a4: (595.28, 841.89)
        case .letter: (612, 792)
        }
    }
}

/// Places an image of `imageWidth × imageHeight` on a page, scaled to fit inside the margins and
/// centered. Landscape images get a landscape page for fixed page sizes.
public enum ImagePageLayout {
    public static func layout(imageWidth: Double, imageHeight: Double, pageSize: PageSizeOption,
                              margin: Double) -> (page: PageRect, image: PageRect) {
        guard let size = pageSize.size else {
            let page = PageRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
            return (page, page)
        }
        let landscape = imageWidth > imageHeight
        let pw = landscape ? size.height : size.width
        let ph = landscape ? size.width : size.height
        let page = PageRect(x: 0, y: 0, width: pw, height: ph)
        let availW = pw - 2 * margin, availH = ph - 2 * margin
        let scale = min(availW / imageWidth, availH / imageHeight)
        let w = imageWidth * scale, h = imageHeight * scale
        return (page, PageRect(x: (pw - w) / 2, y: (ph - h) / 2, width: w, height: h))
    }
}
