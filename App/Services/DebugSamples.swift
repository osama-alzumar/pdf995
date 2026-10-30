#if DEBUG
import UIKit
import PDFEngine
import WaraqaCore

/// DEBUG `-WaraqaSampleFiles`: generated input files (fictional content) so UI tests can run each
/// tool end to end through the real screen, runner and engine.
enum DebugSamples {
    static let unlockPassword = "1234"

    static func files(for tool: ToolInfo) -> [PickedFile] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("samples-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch tool.input {
        case .images, .camera:
            return (1...2).compactMap { image(number: $0, in: folder) }
        case .multiplePDFs, .twoPDFs:
            return [pdf("ملف أول", body: "الفقرة الأولى من الملف.", in: folder),
                    pdf("ملف ثان", body: "الفقرة الأولى من الملف بعد التعديل.", in: folder)].compactMap { $0 }
        case .webPage:
            let url = folder.appendingPathComponent("صفحة.html")
            try? "<html dir=rtl><body><h1>صفحة تجريبية</h1><p>نص عربي للتجربة.</p></body></html>"
                .write(to: url, atomically: true, encoding: .utf8)
            return [PickedFile(url: url, name: url.lastPathComponent)]
        default:
            guard var file = pdf("مستند تجريبي", body: "رقم الهوية 1000000001\n\nنص للتجربة فقط.", in: folder) else { return [] }
            if tool.id == .unlock {
                let locked = folder.appendingPathComponent("مستند محمي.pdf")
                try? PDFEngine.protect(PDFInput(url: file.url), userPassword: unlockPassword, to: locked)
                file = PickedFile(url: locked, name: locked.lastPathComponent, password: unlockPassword)
            }
            return [file]
        }
    }

    private static func pdf(_ name: String, body: String, in folder: URL) -> PickedFile? {
        let url = folder.appendingPathComponent("\(name).pdf")
        let pages = (1...3).map { "\(name) — صفحة \($0)\n\n\(body)" }
        guard (try? PDFEngine.textToPDF(pages: pages, title: name, rightToLeft: true, to: url)) != nil else { return nil }
        return PickedFile(url: url, name: url.lastPathComponent)
    }

    private static func image(number: Int, in folder: URL) -> PickedFile? {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1).setFill()
            context.fill(CGRect(x: 100, y: 100, width: 1000, height: 300))
            ("صورة تجريبية \(number)" as NSString).draw(at: CGPoint(x: 120, y: 500),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 80), .foregroundColor: UIColor.black])
        }
        let url = folder.appendingPathComponent("صورة \(number).jpg")
        guard let data = image.jpegData(compressionQuality: 0.9), (try? data.write(to: url)) != nil else { return nil }
        return PickedFile(url: url, name: url.lastPathComponent)
    }
}
#endif
