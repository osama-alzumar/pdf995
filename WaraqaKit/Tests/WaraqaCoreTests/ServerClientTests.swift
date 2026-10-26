import XCTest
@testable import WaraqaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ServerClientTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("waraqa-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    final class FakeTransport: HTTPTransport, @unchecked Sendable {
        var response: HTTPResponse
        var error: Error?
        var lastRequest: URLRequest?
        var lastBody: Data?
        init(_ response: HTTPResponse) { self.response = response }
        func send(_ request: URLRequest, bodyFile: URL?, progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse {
            lastRequest = request
            if let bodyFile { lastBody = try Data(contentsOf: bodyFile) }
            if let error { throw error }
            return response
        }
    }

    func input(_ name: String, _ content: String) throws -> MultipartBody.FilePart {
        let url = dir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return MultipartBody.FilePart(fileName: name, contentType: "application/pdf", url: url)
    }

    func testNoUploadWithoutConsent() async throws {
        let fake = FakeTransport(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let client = ServerClient(baseURL: URL(string: "https://example.invalid")!, transport: fake, workDirectory: dir, consent: { false })
        do {
            _ = try await client.run(tool: .pdfToWord, files: [try input("a.pdf", "x")])
            XCTFail("must refuse")
        } catch {
            XCTAssertEqual(error as? WaraqaError, .serverConsentRequired)
        }
        XCTAssertNil(fake.lastRequest, "nothing may be sent without consent")
    }

    func testNotConfigured() async throws {
        let client = ServerClient(baseURL: nil, transport: FakeTransport(HTTPResponse(statusCode: 200, headers: [:], body: Data())),
                                  workDirectory: dir, consent: { true })
        XCTAssertFalse(client.isConfigured)
        do {
            _ = try await client.status()
            XCTFail()
        } catch {
            XCTAssertEqual(error as? WaraqaError, .serverNotConfigured)
        }
    }

    func testMultipartAndResultFile() async throws {
        let fake = FakeTransport(HTTPResponse(statusCode: 200, headers: [
            "content-disposition": "attachment; filename=\"result.docx\"; filename*=UTF-8''%D8%B9%D9%82%D8%AF.docx",
            "content-type": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ], body: Data("DOCX".utf8)))
        let client = ServerClient(baseURL: URL(string: "https://api.example.com")!, transport: fake, workDirectory: dir, consent: { true })
        let result = try await client.run(tool: .pdfToWord, files: [try input("عقد.pdf", "%PDF-1.7 body")], options: ["lang": "ar"])

        XCTAssertEqual(fake.lastRequest?.url?.absoluteString, "https://api.example.com/v1/tools/pdfToWord")
        XCTAssertEqual(fake.lastRequest?.httpMethod, "POST")
        let body = String(decoding: fake.lastBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"lang\"\r\n\r\nar\r\n"))
        XCTAssertTrue(body.contains("filename=\"عقد.pdf\""))
        XCTAssertTrue(body.contains("%PDF-1.7 body"))
        XCTAssertEqual(result.fileName, "عقد.docx")
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "DOCX")
        // The temporary multipart body is removed after upload.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".multipart") }
        XCTAssertEqual(leftovers, [])
    }

    func testErrorMapping() async throws {
        let body = Data(#"{"error":"wrong_password","message_ar":"خطأ"}"#.utf8)
        let fake = FakeTransport(HTTPResponse(statusCode: 400, headers: [:], body: body))
        let client = ServerClient(baseURL: URL(string: "https://api.example.com")!, transport: fake, workDirectory: dir, consent: { true })
        do {
            _ = try await client.run(tool: .repair, files: [try input("a.pdf", "x")])
            XCTFail()
        } catch {
            XCTAssertEqual(error as? WaraqaError, .wrongPassword)
        }
        XCTAssertEqual(ServerClient.map(status: 413, body: Data()), .fileTooLarge(limitBytes: Limits.maxUploadBytes))
        XCTAssertEqual(ServerClient.map(status: 503, body: Data()), .serverUnavailable)
        XCTAssertEqual(ServerClient.map(status: 422, body: Data(#"{"error":"x","message_ar":"رسالة"}"#.utf8)), .serverRejected(message: "رسالة"))
        XCTAssertEqual(ServerClient.map(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ServerClient.map(URLError(.timedOut)), .timeout)

        fake.error = URLError(.notConnectedToInternet)
        do {
            _ = try await client.status()
            XCTFail()
        } catch {
            XCTAssertEqual(error as? WaraqaError, .offline)
        }
    }

    func testContentDisposition() {
        XCTAssertEqual(ServerClient.fileName(fromContentDisposition: "attachment; filename=\"a.pdf\""), "a.pdf")
        XCTAssertEqual(ServerClient.fileName(fromContentDisposition: "attachment; filename*=UTF-8''%D9%88.pdf"), "و.pdf")
        XCTAssertNil(ServerClient.fileName(fromContentDisposition: nil))
    }

    func testStatusDecoding() async throws {
        let json = #"{"status":"ok","tools":["wordToPDF","ocr"],"ai":false,"retention_minutes":10,"max_upload_mb":100}"#
        let fake = FakeTransport(HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8)))
        let client = ServerClient(baseURL: URL(string: "https://api.example.com")!, transport: fake, workDirectory: dir, consent: { false })
        let status = try await client.status() // health check needs no consent: no file is sent
        XCTAssertTrue(status.supports(.wordToPDF))
        XCTAssertFalse(status.supports(.pdfToExcel))
        XCTAssertEqual(status.retentionMinutes, 10)
    }

    func testUploadSizeLimit() async throws {
        let fake = FakeTransport(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let client = ServerClient(baseURL: URL(string: "https://api.example.com")!, transport: fake, workDirectory: dir, consent: { true })
        let big = dir.appendingPathComponent("big.pdf")
        _ = FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(Limits.maxUploadBytes + 1))
        try h.close()
        do {
            _ = try await client.run(tool: .ocr, files: [MultipartBody.FilePart(fileName: "big.pdf", contentType: "application/pdf", url: big)])
            XCTFail()
        } catch {
            XCTAssertEqual(error as? WaraqaError, .fileTooLarge(limitBytes: Limits.maxUploadBytes))
        }
        XCTAssertNil(fake.lastRequest)
    }
}
