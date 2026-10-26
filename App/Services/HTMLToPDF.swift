import UIKit
import WebKit
import WaraqaCore

/// Web page / HTML file → paginated A4 PDF on the device, through WebKit's print renderer, so
/// text stays selectable and pages break like a printout.
@MainActor
enum HTMLToPDF {
    enum Source {
        case web(URL)
        case file(URL)
    }

    static func render(_ source: Source, to output: URL, timeout: TimeInterval = 45) async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 820, height: 1160))
        let loader = Loader()
        webView.navigationDelegate = loader
        switch source {
        case .web(let url):
            webView.load(URLRequest(url: url, timeoutInterval: timeout))
        case .file(let url):
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        try await loader.wait(timeout: timeout)
        // Give late layout (fonts, lazy images) a moment to settle.
        try await Task.sleep(nanoseconds: 600_000_000)
        try Task.checkCancellation()

        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let paper = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: 28, dy: 36)), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        let bounds = UIGraphicsGetPDFContextBounds()
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: bounds)
        }
        UIGraphicsEndPDFContext()
        guard renderer.numberOfPages > 0 else { throw WaraqaError.conversionFailed }
        do {
            try (data as Data).write(to: output, options: [.atomic, .completeFileProtection])
        } catch {
            throw WaraqaError.notEnoughStorage
        }
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false

        func wait(timeout: TimeInterval) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(WaraqaError.timeout)
                }
            }
        }

        private func finish(_ error: Error?) {
            guard !finished, let continuation else { return }
            finished = true
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(Self.map(error))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(Self.map(error))
        }

        static func map(_ error: Error) -> WaraqaError {
            let code = (error as? URLError)?.code
            switch code {
            case .notConnectedToInternet?, .networkConnectionLost?: return .offline
            case .timedOut?: return .timeout
            default: return .conversionFailed
            }
        }
    }
}
