import XCTest
@testable import WaraqaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// End-to-end against a real Waraqa server, using the same URLSession transport as the app.
/// Runs only when WARAQA_LIVE_SERVER is set, e.g. WARAQA_LIVE_SERVER=http://127.0.0.1:8765
/// and WARAQA_FIXTURES=/path/to/backend/tests/fixtures.
final class LiveServerTests: XCTestCase {
    var base: URL!
    var fixtures: URL!
    var work: URL!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["WARAQA_LIVE_SERVER"], let fixturesPath = env["WARAQA_FIXTURES"] else {
            throw XCTSkip("set WARAQA_LIVE_SERVER and WARAQA_FIXTURES to run live server tests")
        }
        base = URL(string: server)!
        fixtures = URL(fileURLWithPath: fixturesPath)
        work = FileManager.default.temporaryDirectory.appendingPathComponent("waraqa-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    func client(consent: Bool = true) -> ServerClient {
        ServerClient(baseURL: base, workDirectory: work, consent: { consent })
    }

    func part(_ name: String, as uploadName: String? = nil, type: String = "application/pdf") -> MultipartBody.FilePart {
        MultipartBody.FilePart(fileName: uploadName ?? name, contentType: type, url: fixtures.appendingPathComponent(name))
    }

    func testHealth() async throws {
        let status = try await client(consent: false).status()
        XCTAssertEqual(status.status, "ok")
        XCTAssertTrue(status.supports(.pdfToWord))
        XCTAssertGreaterThan(status.retentionMinutes, 0)
    }

    func testWordToPDFWithArabicName() async throws {
        let result = try await client().run(tool: .wordToPDF,
                                            files: [part("arabic.docx", as: "عقد الإيجار.docx",
                                                         type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")])
        XCTAssertEqual(result.fileName, "عقد الإيجار.pdf")
        let data = try Data(contentsOf: result.fileURL)
        XCTAssertTrue(data.starts(with: Data("%PDF-".utf8)))
        XCTAssertGreaterThan(data.count, 10_000)
    }

    func testPDFToWordReturnsDocx() async throws {
        let result = try await client().run(tool: .pdfToWord, files: [part("english.pdf")])
        XCTAssertEqual(result.fileName, "english.docx")
        let data = try Data(contentsOf: result.fileURL)
        XCTAssertTrue(data.starts(with: [0x50, 0x4B]), "DOCX is a ZIP container")
    }

    func testServerErrorsMapToUserMessages() async throws {
        do {
            _ = try await client().run(tool: .pdfToWord, files: [part("protected.pdf")])
            XCTFail("must ask for the password")
        } catch {
            XCTAssertEqual(error as? WaraqaError, .passwordRequired)
        }
        do {
            _ = try await client().run(tool: .pdfToWord, files: [part("protected.pdf")], options: ["password": "bad"])
            XCTFail()
        } catch {
            XCTAssertEqual(error as? WaraqaError, .wrongPassword)
        }
        let ok = try await client().run(tool: .pdfToWord, files: [part("protected.pdf")], options: ["password": "1234"])
        XCTAssertTrue(try Data(contentsOf: ok.fileURL).starts(with: [0x50, 0x4B]))
        do {
            _ = try await client().run(tool: .repair, files: [part("corrupt_garbage.pdf")])
            XCTFail()
        } catch {
            XCTAssertEqual(error as? WaraqaError, .cannotOpen(fileName: ""))
        }
    }

    func testAIWithoutKeyIsReportedNotFaked() async throws {
        let request = SummarizeRequest(pages: [AIPage(page: 1, text: "نص تجريبي للتلخيص")], length: .short, language: "ar")
        do {
            _ = try await client().postJSON("v1/ai/summarize", body: request, as: SummarizeResponse.self)
            XCTFail("no API key on the test server: must fail")
        } catch {
            XCTAssertEqual(error as? WaraqaError, .aiNotConfigured)
        }
    }

    func testUnreachableServerIsUnavailable() async throws {
        let dead = ServerClient(baseURL: URL(string: "http://127.0.0.1:9")!, workDirectory: work, consent: { true })
        do {
            _ = try await dead.status()
            XCTFail()
        } catch {
            let e = error as? WaraqaError
            XCTAssertTrue(e == .serverUnavailable || e == .offline, "\(error)")
        }
    }
}
