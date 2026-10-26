import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the server says about itself (GET /v1/health).
public struct ServerStatus: Codable, Equatable, Sendable {
    public let status: String
    public let tools: [String]
    public let ai: Bool
    public let retentionMinutes: Int
    public let maxUploadMB: Int

    enum CodingKeys: String, CodingKey {
        case status, tools, ai
        case retentionMinutes = "retention_minutes"
        case maxUploadMB = "max_upload_mb"
    }

    public func supports(_ tool: ToolID) -> Bool { tools.contains(tool.rawValue) }
}

/// Error body returned by the server for every failure.
public struct ServerErrorBody: Codable, Sendable {
    public let error: String
    public let messageAr: String?
    public let messageEn: String?

    enum CodingKeys: String, CodingKey {
        case error
        case messageAr = "message_ar"
        case messageEn = "message_en"
    }
}

/// A file returned by a server tool.
public struct ServerFileResult: Sendable {
    public let fileURL: URL
    public let fileName: String
    public let contentType: String
    public let headers: [String: String]
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
}

/// The network boundary, so the client can be tested with a fake.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, bodyFile: URL?, progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse
}

/// Builds multipart/form-data bodies on disk so large uploads are streamed, not held in memory.
public struct MultipartBody {
    public let boundary: String
    public let fileURL: URL

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public struct FilePart {
        public let fieldName: String
        public let fileName: String
        public let contentType: String
        public let url: URL
        public init(fieldName: String = "files", fileName: String, contentType: String, url: URL) {
            self.fieldName = fieldName
            self.fileName = fileName
            self.contentType = contentType
            self.url = url
        }
    }

    public static func write(fields: [String: String], files: [FilePart], to directory: URL) throws -> MultipartBody {
        let boundary = "waraqa-" + UUID().uuidString
        let url = directory.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        func put(_ s: String) { handle.write(Data(s.utf8)) }

        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            put("--\(boundary)\r\n")
            put("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            put("\(value)\r\n")
        }
        for file in files {
            put("--\(boundary)\r\n")
            // RFC 7578: non-ASCII file names are sent as UTF-8; quotes are escaped.
            let safeName = file.fileName.replacingOccurrences(of: "\"", with: "'")
            put("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(safeName)\"\r\n")
            put("Content-Type: \(file.contentType)\r\n\r\n")
            let input = try FileHandle(forReadingFrom: file.url)
            while true {
                let chunk = input.readData(ofLength: 1 << 20)
                if chunk.isEmpty { break }
                handle.write(chunk)
            }
            try? input.close()
            put("\r\n")
        }
        put("--\(boundary)--\r\n")
        return MultipartBody(boundary: boundary, fileURL: url)
    }
}

/// Client for the Waraqa processing server. Nothing is sent unless `consent()` returns true:
/// the app sets it only after the user explicitly agrees to upload.
public final class ServerClient: @unchecked Sendable {
    public let baseURL: URL?
    private let transport: HTTPTransport
    private let consent: @Sendable () -> Bool
    private let workDirectory: URL
    public var timeout: TimeInterval = 300

    public init(baseURL: URL?, transport: HTTPTransport = URLSessionTransport(), workDirectory: URL,
                consent: @escaping @Sendable () -> Bool) {
        self.baseURL = baseURL
        self.transport = transport
        self.workDirectory = workDirectory
        self.consent = consent
    }

    public var isConfigured: Bool { baseURL != nil }

    public func status() async throws -> ServerStatus {
        let base = try requireBase()
        var request = URLRequest(url: base.appendingPathComponent("v1/health"))
        request.timeoutInterval = 15
        let response = try await perform(request, bodyFile: nil, progress: nil)
        return try decode(ServerStatus.self, response)
    }

    /// Uploads files to a server tool and stores the returned file in `workDirectory`.
    public func run(tool: ToolID, files: [MultipartBody.FilePart], options: [String: String] = [:],
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> ServerFileResult {
        let base = try requireBase()
        guard consent() else { throw WaraqaError.serverConsentRequired }
        let total = files.reduce(Int64(0)) { sum, part in
            sum + ((try? FileManager.default.attributesOfItem(atPath: part.url.path)[.size] as? Int64) ?? 0)
        }
        guard total <= Limits.maxUploadBytes else { throw WaraqaError.fileTooLarge(limitBytes: Limits.maxUploadBytes) }

        let body = try MultipartBody.write(fields: options, files: files, to: workDirectory)
        defer { try? FileManager.default.removeItem(at: body.fileURL) }

        var request = URLRequest(url: base.appendingPathComponent("v1/tools/\(tool.rawValue)"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        let response = try await perform(request, bodyFile: body.fileURL, progress: progress)

        let name = Self.fileName(fromContentDisposition: response.headers["content-disposition"])
            ?? "result-\(tool.rawValue)"
        let out = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let fileURL = out.appendingPathComponent(FileNaming.sanitize(name))
        do {
            try response.body.write(to: fileURL, options: .atomic)
        } catch {
            throw WaraqaError.notEnoughStorage
        }
        return ServerFileResult(fileURL: fileURL, fileName: fileURL.lastPathComponent,
                                contentType: response.headers["content-type"] ?? "application/octet-stream",
                                headers: response.headers)
    }

    /// JSON request to the AI endpoints. Only extracted text is sent, never the PDF itself.
    public func postJSON<Body: Encodable, Result: Decodable>(_ path: String, body: Body, as: Result.Type) async throws -> Result {
        let base = try requireBase()
        guard consent() else { throw WaraqaError.serverConsentRequired }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let response = try await perform(request, bodyFile: nil, progress: nil)
        return try decode(Result.self, response)
    }

    // MARK: - Internals

    private func requireBase() throws -> URL {
        guard let baseURL else { throw WaraqaError.serverNotConfigured }
        return baseURL
    }

    private func perform(_ request: URLRequest, bodyFile: URL?, progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(request, bodyFile: bodyFile, progress: progress)
        } catch let error as WaraqaError {
            throw error
        } catch let error as URLError {
            throw Self.map(error)
        } catch is CancellationError {
            throw WaraqaError.cancelled
        } catch {
            throw WaraqaError.serverUnavailable
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.map(status: response.statusCode, body: response.body)
        }
        return response
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw WaraqaError.serverUnavailable
        }
    }

    static func map(_ error: URLError) -> WaraqaError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timeout
        case .cancelled:
            return .cancelled
        default:
            return .serverUnavailable
        }
    }

    static func map(status: Int, body: Data) -> WaraqaError {
        let parsed = try? JSONDecoder().decode(ServerErrorBody.self, from: body)
        switch (status, parsed?.error) {
        case (_, "password_required"): return .passwordRequired
        case (_, "wrong_password"): return .wrongPassword
        case (_, "cannot_open"): return .cannotOpen(fileName: "")
        case (_, "unsupported_file"): return .unsupportedFile(fileName: "")
        case (_, "conversion_failed"): return .conversionFailed
        case (_, "output_validation_failed"): return .outputValidationFailed
        case (_, "ai_not_configured"): return .aiNotConfigured
        case (_, "no_text"): return .noTextFound
        case (413, _): return .fileTooLarge(limitBytes: Limits.maxUploadBytes)
        case (429, _), (502, _), (503, _): return .serverUnavailable
        case (504, _): return .timeout
        default:
            if let message = parsed?.messageAr ?? parsed?.messageEn { return .serverRejected(message: message) }
            return .serverUnavailable
        }
    }

    /// Reads `filename*=UTF-8''…` (preferred, Arabic names) or `filename="…"`.
    static func fileName(fromContentDisposition header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.lowercased().hasPrefix("filename*=") {
                let value = part.dropFirst("filename*=".count)
                let encoded = value.components(separatedBy: "''").last ?? String(value)
                if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty { return decoded }
            }
        }
        for part in header.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.lowercased().hasPrefix("filename=") {
                let value = part.dropFirst("filename=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}

/// URLSession transport. Uploads stream from a file; upload progress is sampled from the task.
public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest, bodyFile: URL?, progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse {
        let session = URLSession.shared
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    var headers: [String: String] = [:]
                    for (key, value) in http.allHeaderFields {
                        headers[String(describing: key).lowercased()] = String(describing: value)
                    }
                    continuation.resume(returning: HTTPResponse(statusCode: http.statusCode, headers: headers, body: data ?? Data()))
                }
                let task: URLSessionTask
                if let bodyFile {
                    task = session.uploadTask(with: request, fromFile: bodyFile, completionHandler: completion)
                } else {
                    task = session.dataTask(with: request, completionHandler: completion)
                }
                box.task = task
                task.resume()
                if let progress {
                    Task {
                        while task.state == .running {
                            let expected = task.countOfBytesExpectedToSend
                            if expected > 0 { progress(min(1, Double(task.countOfBytesSent) / Double(expected))) }
                            try? await Task.sleep(nanoseconds: 200_000_000)
                        }
                        progress(1)
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionTask?
    }
}
