import SwiftUI
import WaraqaCore

/// State machine behind every tool screen: idle → running(progress) → finished | failed.
/// The work runs off the main thread; the UI stays responsive and can cancel at any time.
@MainActor
final class ToolRunner: ObservableObject {
    enum Phase {
        case idle
        case running(progress: Double)
        case finished(ToolOutput, recents: [RecentItem])
        case failed(WaraqaError)
    }

    @Published private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func run(_ tool: ToolID, files: [PickedFile], options: ToolOptions, language: AppLanguage) {
        guard !isRunning else { return }
        phase = .running(progress: 0)
        task = Task { [weak self] in
            let store = FileStore.shared
            let folder: URL
            do {
                folder = try store.newOutputFolder()
            } catch {
                self?.phase = .failed(.notEnoughStorage)
                return
            }
            let context = ToolJobs.Context(outputFolder: folder, language: language, progress: { value in
                Task { @MainActor [weak self] in
                    guard let self, case .running(let current) = self.phase, value > current else { return }
                    self.phase = .running(progress: min(value, 1))
                }
            })
            do {
                let output = try await ToolJobs.run(tool, files: files, options: options, context: context)
                try Task.checkCancellation()
                // Results already inside the results folder are recorded in "My files".
                let recents = output.files
                    .filter { $0.path.hasPrefix(store.results.path) }
                    .map { store.record($0, tool: tool) }
                self?.phase = .finished(output, recents: recents)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                self?.phase = .failed(Self.map(error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .failed(.cancelled)
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    static func map(_ error: Error) -> WaraqaError {
        if let error = error as? WaraqaError { return error }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            return urlError.code == .notConnectedToInternet ? .offline : .serverUnavailable
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return .notEnoughStorage }
        return .conversionFailed
    }
}
