import Foundation
import UIKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

@objc(IVLAppleTranslationBridge)
public final class IVLAppleTranslationBridge: NSObject {

    @objc public static func isAppleTranslationAvailable() -> Bool {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            return true
        }
        #endif
        return false
    }

    @objc public static func isAppleIntelligenceAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return true
            case .unavailable(.deviceNotEligible):
                return false
            case .unavailable(.appleIntelligenceNotEnabled),
                 .unavailable(.modelNotReady):
                return true
            @unknown default:
                return true
            }
        }
        #endif
        return false
    }

    @objc public static func appleIntelligenceStatus() -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "ready"
            case .unavailable(.deviceNotEligible):
                return "ineligible"
            case .unavailable(.appleIntelligenceNotEnabled):
                return "disabled"
            case .unavailable(.modelNotReady):
                return "not_ready"
            @unknown default:
                return "not_ready"
            }
        }
        #endif
        return "ineligible"
    }

    // MARK: - Apple Translation Framework (iOS 18+)

    @objc(translateWithAppleTranslationWithLines:sourceLang:targetLang:completion:)
    public static func translateWithAppleTranslation(
        lines: [String],
        sourceLang: String?,
        targetLang: String,
        completion: @escaping ([String]?) -> Void
    ) {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            guard !lines.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            Task { @MainActor in
                IVLAppleTranslationRunner.shared.enqueue(
                    lines: lines,
                    sourceLang: sourceLang,
                    targetLang: targetLang,
                    completion: completion
                )
            }
            return
        }
        #endif
        DispatchQueue.main.async { completion(nil) }
    }

    // MARK: - Apple Foundation Models Framework (Apple Intelligence On-Device LLM, iOS 26+)

    @objc(translateWithAppleIntelligenceWithLines:targetLang:completion:)
    public static func translateWithAppleIntelligence(
        lines: [String],
        targetLang: String,
        completion: @escaping ([String]?) -> Void
    ) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard !lines.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let model = SystemLanguageModel.default
            if case .unavailable(.deviceNotEligible) = model.availability {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let targetName = Locale.current.localizedString(forIdentifier: targetLang)
                ?? Locale(identifier: "en").localizedString(forIdentifier: targetLang)
                ?? targetLang

            Task.detached(priority: .userInitiated) {
                let result = await runFoundationModelsTranslation(lines: lines, targetLanguageName: targetName)
                await MainActor.run {
                    completion(result)
                }
            }
            return
        }
        #endif
        DispatchQueue.main.async { completion(nil) }
    }
}

// MARK: - Apple Translation SwiftUI Host Runner

#if canImport(Translation)
@available(iOS 18.0, *)
@MainActor
private final class IVLAppleTranslationRunner {
    static let shared = IVLAppleTranslationRunner()

    private struct Job {
        let lines: [String]
        let sourceLang: String?
        let targetLang: String
        let completion: ([String]?) -> Void
    }

    private var queue: [Job] = []
    private var activeHost: UIHostingController<IVLHiddenTranslationHostView>?
    private var isRunning = false

    func enqueue(lines: [String], sourceLang: String?, targetLang: String, completion: @escaping ([String]?) -> Void) {
        queue.append(Job(lines: lines, sourceLang: sourceLang, targetLang: targetLang, completion: completion))
        if !isRunning {
            runNext()
        }
    }

    private func activeWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let key = ws.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let first = ws.windows.first { return first }
        }
        return nil
    }

    private func runNext() {
        guard !queue.isEmpty else {
            isRunning = false
            return
        }
        let job = queue.removeFirst()
        guard let window = activeWindow() else {
            job.completion(nil)
            runNext()
            return
        }

        isRunning = true
        var finished = false

        let finish: @MainActor ([String]?) -> Void = { [weak self] result in
            guard !finished else { return }
            finished = true
            self?.activeHost?.view.removeFromSuperview()
            self?.activeHost = nil
            job.completion(result)
            self?.runNext()
        }

        let target = Locale.Language(identifier: job.targetLang)
        let source: Locale.Language? = {
            if let s = job.sourceLang, !s.isEmpty {
                return Locale.Language(identifier: s)
            }
            return nil
        }()
        let config = TranslationSession.Configuration(source: source, target: target)

        let hostView = IVLHiddenTranslationHostView(
            configuration: config,
            lines: job.lines,
            onFinish: { result in
                Task { @MainActor in
                    finish(result)
                }
            }
        )
        let hc = UIHostingController(rootView: hostView)
        hc.view.backgroundColor = .clear
        hc.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        hc.view.alpha = 0.01
        hc.view.isUserInteractionEnabled = false
        window.addSubview(hc.view)
        activeHost = hc

        // Safety timeout in case the system sheet is dismissed without throwing
        DispatchQueue.main.asyncAfter(deadline: .now() + 25.0) {
            finish(nil)
        }
    }
}

@available(iOS 18.0, *)
private struct IVLHiddenTranslationHostView: View {
    let configuration: TranslationSession.Configuration
    let lines: [String]
    let onFinish: @Sendable ([String]?) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()
                    let requests = lines.enumerated().map { idx, text in
                        TranslationSession.Request(sourceText: text, clientIdentifier: String(idx))
                    }
                    let responses = try await session.translations(from: requests)
                    var out = Array(repeating: "", count: lines.count)
                    for resp in responses {
                        if let cid = resp.clientIdentifier, let idx = Int(cid), idx >= 0, idx < out.count {
                            out[idx] = resp.targetText
                        }
                    }
                    onFinish(out)
                } catch {
                    onFinish(nil)
                }
            }
    }
}
#endif

// MARK: - Apple Foundation Models Chunked Lyric Translator

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private func runFoundationModelsTranslation(lines: [String], targetLanguageName: String) async -> [String]? {
    let chunkSize = 10
    var output: [String] = []
    output.reserveCapacity(lines.count)

    let instructions = """
    You are a song lyric translator. Translate each numbered lyric line naturally into \(targetLanguageName), preserving tone and rhythm.
    Rules:
    - Output ONLY the translated lines using the exact same numbering format (1: ..., 2: ...).
    - Keep the exact same number of lines as the input.
    - Do not add explanations, notes, romanization, or extra blank lines.
    - If a line is already in \(targetLanguageName), repeat it as-is.
    """

    var start = 0
    while start < lines.count {
        let end = min(start + chunkSize, lines.count)
        let chunk = Array(lines[start..<end])
        let prompt = chunk.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")

        do {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let response = try await session.respond(to: prompt)
            let parsed = parseNumberedTranslation(response.content, expectedCount: chunk.count)
            if let parsed = parsed {
                output.append(contentsOf: parsed)
            } else {
                return nil
            }
        } catch {
            return nil
        }
        start = end
    }
    return output.count == lines.count ? output : nil
}

private func parseNumberedTranslation(_ raw: String, expectedCount: Int) -> [String]? {
    let rawLines = raw
        .replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    var mapped: [Int: String] = [:]
    for line in rawLines {
        if let range = line.range(of: #"^\s*(\d+)\s*[:.\)]\s*"#, options: .regularExpression) {
            let numPart = line[range].filter { $0.isNumber }
            if let idx = Int(numPart), idx >= 1, idx <= expectedCount {
                let text = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                mapped[idx] = text
            }
        }
    }

    if mapped.count == expectedCount {
        return (1...expectedCount).map { mapped[$0] ?? "" }
    }
    if rawLines.count == expectedCount {
        return rawLines.map { line in
            if let range = line.range(of: #"^\s*\d+\s*[:.\)]\s*"#, options: .regularExpression) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return line
        }
    }
    return nil
}
#endif
