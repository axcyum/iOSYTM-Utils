import Foundation
import UIKit
import SwiftUI
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

@objc(IVLAppleTranslationBridge)
public final class IVLAppleTranslationBridge: NSObject {

    // MARK: - Thread-safe Translation Log Ring Buffer

    private static let logLock = NSLock()
    private static var logLines: [String] = []
    private static let maxLogLines = 200
    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    @objc(appendLog:)
    public static func appendLog(_ message: String) {
        let stamp = timeFormatter.string(from: Date())
        let entry = "[\(stamp)] \(message)"
        logLock.lock()
        logLines.append(entry)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
        logLock.unlock()
    }

    @objc public static func allLogs() -> String {
        logLock.lock()
        let joined = logLines.joined(separator: "\n")
        logLock.unlock()
        return joined
    }

    @objc public static func clearLogs() {
        logLock.lock()
        logLines.removeAll()
        logLock.unlock()
    }

    // MARK: - Availability

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

    // MARK: - Deterministic Script + Constrained Language Detection (Apple Translation Supported Set)

    @objc(detectSupportedSourceLanguageForLines:)
    public static func detectSupportedSourceLanguage(for lines: [String]) -> String {
        let text = lines.joined(separator: "\n")
        if text.isEmpty { return "en" }

        var kanaCount = 0
        var hangulCount = 0
        var hanCount = 0
        var cyrillicCount = 0
        var thaiCount = 0
        var arabicCount = 0
        var devanagariCount = 0
        var nonASCIILatinCount = 0
        var asciiAlphaCount = 0

        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) {
                kanaCount += 1
            } else if (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) {
                hangulCount += 1
            } else if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                hanCount += 1
            } else if (0x0400...0x04FF).contains(v) {
                cyrillicCount += 1
            } else if (0x0E00...0x0E7F).contains(v) {
                thaiCount += 1
            } else if (0x0600...0x06FF).contains(v) {
                arabicCount += 1
            } else if (0x0900...0x097F).contains(v) {
                devanagariCount += 1
            } else if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) {
                asciiAlphaCount += 1
            } else if (0x00C0...0x024F).contains(v) || (0x1E00...0x1EFF).contains(v) {
                nonASCIILatinCount += 1
            }
        }

        if kanaCount >= 2 { return "ja" }
        if hangulCount >= 2 { return "ko" }
        if hanCount >= 2 {
            let rec = NLLanguageRecognizer()
            rec.languageConstraints = [.simplifiedChinese, .traditionalChinese, .japanese]
            rec.processString(String(text.prefix(3000)))
            if rec.dominantLanguage == .traditionalChinese { return "zh-Hant" }
            return "zh-Hans"
        }
        if cyrillicCount >= 2 {
            let rec = NLLanguageRecognizer()
            rec.languageConstraints = [.russian, .ukrainian]
            rec.processString(String(text.prefix(3000)))
            return rec.dominantLanguage == .ukrainian ? "uk" : "ru"
        }
        if thaiCount >= 2 { return "th" }
        if arabicCount >= 2 { return "ar" }
        if devanagariCount >= 2 { return "hi" }

        // Latin script: strictly constrain NLLanguageRecognizer to languages supported by Apple Translation
        // so short/slang pop lyrics can NEVER be misclassified as Czech (cs), Slovak (sk), Latin (la), etc.
        let rec = NLLanguageRecognizer()
        rec.languageConstraints = [
            .english, .spanish, .french, .german, .italian,
            .portuguese, .dutch, .polish, .indonesian, .turkish, .vietnamese
        ]
        rec.processString(String(text.prefix(3000)))
        let hyps = rec.languageHypotheses(withMaximum: 3)
        if let top = rec.dominantLanguage, top != .undetermined {
            let conf = hyps[top] ?? 0.0
            // Pure ASCII lyrics without European diacritics are overwhelmingly English unless high confidence otherwise
            if nonASCIILatinCount == 0 && asciiAlphaCount > 0 && top != .english && conf < 0.82 {
                return "en"
            }
            return top.rawValue
        }
        return "en"
    }

    // MARK: - Native iOS Translation Model Download UI (iOS 18+)

    @objc(presentModelDownloadFrom:targetLang:)
    public static func presentModelDownload(from presenter: UIViewController, targetLang: String) {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            Task { @MainActor in
                let view = IVLTranslationModelSheetView(targetLang: targetLang) {
                    presenter.dismiss(animated: true)
                }
                let hc = UIHostingController(rootView: view)
                hc.overrideUserInterfaceStyle = .dark
                hc.modalPresentationStyle = .pageSheet
                if let sheet = hc.sheetPresentationController {
                    sheet.detents = [.large(), .medium()]
                    sheet.prefersGrabberVisible = true
                }
                presenter.present(hc, animated: true)
            }
            return
        }
        #endif
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
            let detected = detectSupportedSourceLanguage(for: lines)
            let normalizedTarget = normalizeAppleTranslationCode(targetLang)
            if detected.lowercased().hasPrefix(normalizedTarget.lowercased()) || normalizedTarget.lowercased().hasPrefix(detected.lowercased()) {
                appendLog("Apple Translation: skipped (source=\(detected) matches target=\(normalizedTarget))")
                DispatchQueue.main.async { completion(lines) }
                return
            }
            Task { @MainActor in
                IVLAppleTranslationRunner.shared.enqueue(
                    lines: lines,
                    sourceLang: detected,
                    targetLang: normalizedTarget,
                    completion: completion
                )
            }
            return
        }
        #endif
        appendLog("Apple Translation: unavailable on this OS")
        DispatchQueue.main.async { completion(nil) }
    }

    private static func normalizeAppleTranslationCode(_ code: String) -> String {
        let low = code.lowercased()
        if low == "zh-cn" || low == "zh-sg" || low == "zh" { return "zh-Hans" }
        if low == "zh-tw" || low == "zh-hk" { return "zh-Hant" }
        return code
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
            switch model.availability {
            case .available:
                break
            case .unavailable(.appleIntelligenceNotEnabled):
                appendLog("Apple Intelligence: disabled in iOS Settings -> using Apple Translation")
                DispatchQueue.main.async { completion(nil) }
                return
            case .unavailable(.modelNotReady):
                appendLog("Apple Intelligence: model not ready (downloading / Focus / LiveContainer sandbox) -> using Apple Translation")
                DispatchQueue.main.async { completion(nil) }
                return
            case .unavailable(.deviceNotEligible):
                appendLog("Apple Intelligence: device not eligible")
                DispatchQueue.main.async { completion(nil) }
                return
            @unknown default:
                appendLog("Apple Intelligence: unavailable -> using Apple Translation")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let targetName = Locale.current.localizedString(forIdentifier: targetLang)
                ?? Locale(identifier: "en").localizedString(forIdentifier: targetLang)
                ?? targetLang
            appendLog("Apple Intelligence: start (target=\(targetLang), \(lines.count) lines)")

            Task.detached(priority: .userInitiated) {
                let result = await runFoundationModelsTranslation(lines: lines, targetLanguageName: targetName)
                await MainActor.run {
                    completion(result)
                }
            }
            return
        }
        #endif
        appendLog("Apple Intelligence: unavailable on this OS")
        DispatchQueue.main.async { completion(nil) }
    }
}

// MARK: - Native iOS Translation Model Download Sheet

#if canImport(Translation)
@available(iOS 18.0, *)
private struct IVLLangPairRow: Identifiable {
    let id: String
    let code: String
    let name: String
}

@available(iOS 18.0, *)
private struct IVLTranslationModelSheetView: View {
    let targetLang: String
    let onClose: () -> Void

    @State private var statuses: [String: LanguageAvailability.Status] = [:]
    @State private var activeConfig: TranslationSession.Configuration?
    @State private var downloadingCode: String?
    @State private var statusBanner: String?

    private var normalizedTarget: String {
        let low = targetLang.lowercased()
        if low == "zh-cn" || low == "zh" { return "zh-Hans" }
        if low == "zh-tw" || low == "zh-hk" { return "zh-Hant" }
        return targetLang
    }

    private static let commonSources: [(String, String)] = [
        ("en", "English"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("zh-Hans", "中文 (简体)"),
        ("zh-Hant", "中文 (繁體)"),
        ("es", "Español"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("it", "Italiano"),
        ("pt", "Português"),
        ("ru", "Русский"),
        ("vi", "Tiếng Việt"),
        ("th", "ไทย"),
        ("id", "Bahasa Indonesia"),
    ]

    private var rows: [IVLLangPairRow] {
        Self.commonSources
            .filter { !normalizedTarget.lowercased().hasPrefix($0.0.lowercased()) && !$0.0.lowercased().hasPrefix(normalizedTarget.lowercased()) }
            .map { IVLLangPairRow(id: $0.0, code: $0.0, name: $0.1) }
    }

    var body: some View {
        NavigationView {
            List {
                if let banner = statusBanner {
                    Section {
                        Text(banner)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                Section(
                    header: Text("→ \(Locale.current.localizedString(forIdentifier: normalizedTarget) ?? normalizedTarget)"),
                    footer: Text("言語をタップすると iPhone 内蔵の翻訳モデルダウンロード画面が開きます。")
                ) {
                    ForEach(rows) { row in
                        Button {
                            triggerDownload(sourceCode: row.code)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name)
                                        .foregroundColor(.primary)
                                    Text(row.code)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                statusBadge(for: row.code)
                            }
                        }
                        .disabled(statuses[row.code] == .unsupported)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("翻訳モデル")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") { onClose() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await refreshStatuses()
        }
        .translationTask(activeConfig) { session in
            guard let code = downloadingCode else { return }
            IVLAppleTranslationBridge.appendLog("Model download sheet: prepareTranslation(\(code) -> \(normalizedTarget))")
            do {
                try await session.prepareTranslation()
                IVLAppleTranslationBridge.appendLog("Model download: completed (\(code) -> \(normalizedTarget))")
                await refreshStatuses()
                await MainActor.run {
                    statusBanner = "\(code) → \(normalizedTarget) のモデル準備が完了しました。"
                    downloadingCode = nil
                    activeConfig = nil
                }
            } catch {
                IVLAppleTranslationBridge.appendLog("Model download error (\(code) -> \(normalizedTarget)): \(error.localizedDescription)")
                await refreshStatuses()
                await MainActor.run {
                    statusBanner = "エラー: \(error.localizedDescription)"
                    downloadingCode = nil
                    activeConfig = nil
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for code: String) -> some View {
        if downloadingCode == code {
            ProgressView()
        } else {
            switch statuses[code] {
            case .installed:
                Label("取得済み", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            case .supported:
                Label("ダウンロード", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            case .unsupported:
                Text("非対応")
                    .font(.caption)
                    .foregroundColor(.secondary)
            default:
                ProgressView()
            }
        }
    }

    private func triggerDownload(sourceCode: String) {
        downloadingCode = sourceCode
        statusBanner = nil
        let cfg = TranslationSession.Configuration(
            source: Locale.Language(identifier: sourceCode),
            target: Locale.Language(identifier: normalizedTarget)
        )
        if activeConfig != nil {
            activeConfig?.invalidate()
        }
        activeConfig = cfg
    }

    private func refreshStatuses() async {
        let avail = LanguageAvailability()
        let dst = Locale.Language(identifier: normalizedTarget)
        var next: [String: LanguageAvailability.Status] = [:]
        for row in rows {
            let src = Locale.Language(identifier: row.code)
            next[row.code] = await avail.status(from: src, to: dst)
        }
        await MainActor.run {
            statuses = next
        }
    }
}

// MARK: - Apple Translation SwiftUI Host Runner

@available(iOS 18.0, *)
@MainActor
private final class IVLAppleTranslationRunner {
    static let shared = IVLAppleTranslationRunner()

    private struct Job {
        let lines: [String]
        let sourceLang: String
        let targetLang: String
        let completion: ([String]?) -> Void
    }

    private var queue: [Job] = []
    private var activeHost: UIHostingController<IVLHiddenTranslationHostView>?
    private var isRunning = false

    func enqueue(lines: [String], sourceLang: String, targetLang: String, completion: @escaping ([String]?) -> Void) {
        queue.append(Job(lines: lines, sourceLang: sourceLang, targetLang: targetLang, completion: completion))
        if !isRunning {
            Task { await runNext() }
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

    private func runNext() async {
        guard !queue.isEmpty else {
            isRunning = false
            return
        }
        isRunning = true
        let job = queue.removeFirst()

        guard let window = activeWindow() else {
            IVLAppleTranslationBridge.appendLog("Apple Translation: no active UIWindow")
            job.completion(nil)
            await runNext()
            return
        }

        let avail = LanguageAvailability()
        let dst = Locale.Language(identifier: job.targetLang)
        var chosenSrc = Locale.Language(identifier: job.sourceLang)
        var pairStatus = await avail.status(from: chosenSrc, to: dst)

        if pairStatus == .unsupported && job.sourceLang != "en" && !job.targetLang.lowercased().hasPrefix("en") {
            chosenSrc = Locale.Language(identifier: "en")
            pairStatus = await avail.status(from: chosenSrc, to: dst)
        }

        if pairStatus == .unsupported {
            IVLAppleTranslationBridge.appendLog("Apple Translation: unsupported pair (\(job.sourceLang) -> \(job.targetLang))")
            job.completion(nil)
            await runNext()
            return
        }

        let needsPrepare = (pairStatus == .supported)
        IVLAppleTranslationBridge.appendLog("Apple Translation: start (\(chosenSrc.minimalIdentifier) -> \(job.targetLang), \(job.lines.count) lines, model=\(needsPrepare ? "download_needed" : "installed"))")

        var finished = false
        let finish: @MainActor ([String]?) -> Void = { [weak self] result in
            guard !finished else { return }
            finished = true
            self?.activeHost?.view.removeFromSuperview()
            self?.activeHost = nil
            job.completion(result)
            if let self = self {
                Task { await self.runNext() }
            }
        }

        let config = TranslationSession.Configuration(source: chosenSrc, target: dst)
        let hostView = IVLHiddenTranslationHostView(
            configuration: config,
            needsPrepare: needsPrepare,
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 25.0) {
            if !finished {
                IVLAppleTranslationBridge.appendLog("Apple Translation: timed out (25s)")
            }
            finish(nil)
        }
    }
}

@available(iOS 18.0, *)
private struct IVLHiddenTranslationHostView: View {
    let configuration: TranslationSession.Configuration
    let needsPrepare: Bool
    let lines: [String]
    let onFinish: @Sendable ([String]?) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                let t0 = CFAbsoluteTimeGetCurrent()
                do {
                    if needsPrepare {
                        try await session.prepareTranslation()
                    }
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
                    let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    IVLAppleTranslationBridge.appendLog("Apple Translation: OK (\(out.count) lines in \(ms)ms)")
                    onFinish(out)
                } catch {
                    IVLAppleTranslationBridge.appendLog("Apple Translation: error — \(error.localizedDescription)")
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
    let t0 = CFAbsoluteTimeGetCurrent()
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
                IVLAppleTranslationBridge.appendLog("Apple Intelligence: line count mismatch on chunk \(start + 1)-\(end)")
                return nil
            }
        } catch {
            IVLAppleTranslationBridge.appendLog("Apple Intelligence: error on chunk \(start + 1)-\(end) — \(error.localizedDescription)")
            return nil
        }
        start = end
    }
    let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    IVLAppleTranslationBridge.appendLog("Apple Intelligence: OK (\(output.count) lines in \(ms)ms)")
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
