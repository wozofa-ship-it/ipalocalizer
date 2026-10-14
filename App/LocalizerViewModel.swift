import Foundation
import SwiftUI

struct LocalizeReport {
    let appName: String
    let bundleID: String
    let candidateCount: Int
    let dictTranslated: Int
    let aiTranslated: Int
    let patchedCount: Int
    let skippedCount: Int
    let flagsPatched: Int
    let outputURL: URL
    let outputSizeText: String
}

/// v4：流程大幅简化，每一步独立 try-catch，任何一步失败都转成中文错误提示，
/// 绝不让异常/崩溃逃出 run()。
@MainActor
final class LocalizerViewModel: ObservableObject {

    @Published var hasFile = false
    @Published var inputName = ""
    @Published var inputSizeText = ""
    @Published var isWorking = false
    @Published var isDone = false
    @Published var statusText = ""
    @Published var progress: Double = 0
    @Published var logLines: [String] = []
    @Published var report: LocalizeReport?
    @Published var showError = false
    @Published var errorMessage = ""

    private var inputURL: URL?

    // MARK: - 输入

    func setInput(url: URL) {
        guard url.pathExtension.lowercased() == "ipa" else {
            errorMessage = LocalizeError.notIPAFile.errorDescription ?? ""
            showError = true
            return
        }
        inputURL = url
        inputName = url.lastPathComponent
        let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        inputSizeText = ByteCountFormatter.string(
            fromByteCount: size, countStyle: .file)
        hasFile = true
        isDone = false
        report = nil
    }

    func reset() {
        inputURL = nil
        hasFile = false
        inputName = ""
        inputSizeText = ""
        isWorking = false
        isDone = false
        statusText = ""
        progress = 0
        logLines = []
        report = nil
    }

    // MARK: - 流程

    func start() {
        guard !isWorking else { return }
        Task {
            // 最外层兜底：任何未预料的错误都转成提示，不崩溃
            do {
                try await run()
            } catch {
                fail(error)
            }
        }
    }

    /// 主流程：每一步独立 do-catch，失败即抛中文错误，由 start() 统一展示。
    private func run() async throws {
        guard let inputURL else { throw LocalizeError.noFileSelected }
        isWorking = true
        isDone = false
        progress = 0
        logLines = []
        report = nil

        let ai = AIConfig.load()
        var workDir: URL? = nil
        defer {
            if let w = workDir { IPAUtils.cleanup(workDir: w) }
        }

        // ---- 步骤 1：解包 ----
        setPhase("正在解包 IPA…", 0.05)
        let up: UnpackedIPA
        do {
            up = try await runDetached {
                try IPAUtils.prepare(inputURL: inputURL)
            }
        } catch {
            throw asLocalizeError(error, fallback: .unzipFailed)
        }
        workDir = up.workDir
        log("应用：\(up.appName)（\(up.bundleID)）")

        // ---- 步骤 2：读二进制 ----
        setPhase("正在读取主程序…", 0.15)
        let bytes: [UInt8]
        do {
            bytes = try await runDetached {
                guard let d = try? Data(contentsOf: up.binaryURL),
                      !d.isEmpty else {
                    throw LocalizeError.binaryReadFailed
                }
                return [UInt8](d)
            }
        } catch {
            throw asLocalizeError(error, fallback: .binaryReadFailed)
        }
        log("二进制大小：\(ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file))")

        // ---- 步骤 3：提取字符串（防弹扫描器，不抛错不崩溃） ----
        setPhase("正在提取字符串…", 0.25)
        let candidates: [CandidateString] = await runDetached {
            StringExtractor.extract(from: bytes)
        }
        log("候选字符串：\(candidates.count) 条")

        // ---- 步骤 4：词典翻译 ----
        setPhase("正在词典翻译…", 0.40)
        var patches: [(offset: Int, en: String, zh: String)] = []
        var missingOrder: [String] = []
        var missingOffsets: [String: [Int]] = [:]
        for c in candidates {
            // 防御：空文本跳过
            if c.text.isEmpty { continue }
            if c.offset < 0 { continue }
            if let zh = Translator.lookup(c.text) {
                patches.append((c.offset, c.text, zh))
            } else {
                if missingOffsets[c.text] == nil {
                    missingOrder.append(c.text)
                    missingOffsets[c.text] = []
                }
                missingOffsets[c.text, default: []].append(c.offset)
            }
        }
        let dictCount = patches.count
        log("词典命中：\(dictCount) 处")

        // ---- 步骤 5：AI 翻译（默认关闭；开启后失败只跳过，不中断） ----
        var aiCount = 0
        if !missingOrder.isEmpty, ai.isReady {
            do {
                aiCount = try await runAITranslation(
                    missingOrder: missingOrder,
                    missingOffsets: missingOffsets,
                    patches: &patches,
                    ai: ai)
            } catch {
                // AI 失败不中断整体流程，只记录
                log("AI 翻译失败，已跳过：\(error.localizedDescription)")
            }
        } else if !missingOrder.isEmpty {
            log("词典未命中 \(missingOrder.count) 条（AI 未开启，已跳过）")
        }

        guard !patches.isEmpty else {
            throw LocalizeError.nothingToTranslate
        }

        // ---- 步骤 6：打补丁 ----
        setPhase("正在打二进制补丁…", 0.70)
        let outcome: BinaryPatcher.PatchOutcome
        do {
            outcome = try await runDetached {
                var mutable = bytes
                let o = BinaryPatcher.apply(to: &mutable, patches: patches)
                do {
                    try Data(mutable).write(to: up.binaryURL, options: .atomic)
                } catch {
                    throw LocalizeError.repackFailed
                }
                return o
            }
        } catch {
            throw asLocalizeError(error, fallback: .repackFailed)
        }
        log("补丁成功 \(outcome.patched.count) 条，跳过 \(outcome.skipped.count) 条")
        for s in outcome.skipped.prefix(10) {
            log("  跳过「\(s.en)」：\(s.reason)")
        }
        if outcome.skipped.count > 10 {
            log("  …还有 \(outcome.skipped.count - 10) 条跳过")
        }
        log("isASCII 标志修复 \(outcome.flagsPatched) 处")

        // ---- 步骤 7：打包 ----
        setPhase("正在重新打包…", 0.85)
        let baseName = inputURL.deletingPathExtension().lastPathComponent
        // 文件名安全化：去掉路径分隔符
        let safeBase = baseName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let outputURL = up.workDir
            .appendingPathComponent(safeBase + "-汉化.ipa")
        do {
            try await runDetached {
                try IPAUtils.repack(workDir: up.workDir, outputURL: outputURL)
            }
        } catch {
            throw asLocalizeError(error, fallback: .repackFailed)
        }

        // ---- 步骤 8：验证 ----
        setPhase("正在验证输出…", 0.95)
        do {
            try await runDetached {
                try IPAUtils.verify(ipaURL: outputURL)
            }
        } catch {
            throw asLocalizeError(error, fallback: .verifyFailed("验证异常"))
        }
        let outSize = (try? FileManager.default
            .attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        log("输出验证通过")

        // 移出工作目录（defer 会删除 workDir）
        let fm = FileManager.default
        let finalURL = fm.temporaryDirectory
            .appendingPathComponent(outputURL.lastPathComponent)
        if fm.fileExists(atPath: finalURL.path) {
            try? fm.removeItem(at: finalURL)
        }
        do {
            try fm.copyItem(at: outputURL, to: finalURL)
        } catch {
            throw LocalizeError.repackFailed
        }

        progress = 1.0
        statusText = "完成"
        report = LocalizeReport(
            appName: up.appName,
            bundleID: up.bundleID,
            candidateCount: candidates.count,
            dictTranslated: dictCount,
            aiTranslated: aiCount,
            patchedCount: outcome.patched.count,
            skippedCount: outcome.skipped.count,
            flagsPatched: outcome.flagsPatched,
            outputURL: finalURL,
            outputSizeText: ByteCountFormatter.string(
                fromByteCount: outSize, countStyle: .file)
        )
        isWorking = false
        isDone = true
    }

    // MARK: - AI 翻译（独立方法，失败抛错由调用方捕获跳过）

    private func runAITranslation(
        missingOrder: [String],
        missingOffsets: [String: [Int]],
        patches: inout [(offset: Int, en: String, zh: String)],
        ai: AIConfig
    ) async throws -> Int {
        var aiCount = 0
        if ai.mode == .builtin {
            let maxBuiltin = 80
            let toTranslate = Array(missingOrder.prefix(maxBuiltin))
            if missingOrder.count > maxBuiltin {
                log("内置翻译限流：仅翻译前 \(maxBuiltin) 条，剩余 \(missingOrder.count - maxBuiltin) 条跳过")
            }
            setPhase("正在内置翻译（\(toTranslate.count) 条）…", 0.50)
            var rateLimited = false
            for (idx, text) in toTranslate.enumerated() {
                if rateLimited { break }
                // 单句失败不抛，只跳过
                let (zhOpt, limited) = await AITranslator.translateBuiltin(text)
                if limited {
                    rateLimited = true
                    log("内置翻译触发限流，已停止（已翻 \(aiCount) 条）")
                    break
                }
                if let zh = zhOpt {
                    let clean = zh.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty, clean != text {
                        for off in missingOffsets[text] ?? [] {
                            patches.append((off, text, clean))
                        }
                        aiCount += 1
                    }
                }
                if idx < toTranslate.count - 1 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                progress = 0.50 + 0.15 * Double(idx + 1) / Double(max(1, toTranslate.count))
            }
            log("内置翻译成功：\(aiCount) 条")
        } else {
            setPhase("正在 AI 翻译（\(missingOrder.count) 条）…", 0.50)
            let batches = missingOrder.chunked(15)
            for (bi, batch) in batches.enumerated() {
                do {
                    let results = try await AITranslator.translateBatch(batch, config: ai)
                    // 长度不一致则整批跳过（防越界）
                    guard results.count == batch.count else {
                        log("AI 翻译第 \(bi + 1)/\(batches.count) 批结果数量不符，已跳过")
                        continue
                    }
                    for (j, rawZh) in results.enumerated() {
                        guard j < batch.count else { continue }
                        let zh = rawZh.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !zh.isEmpty, zh != batch[j] else { continue }
                        for off in missingOffsets[batch[j]] ?? [] {
                            patches.append((off, batch[j], zh))
                        }
                        aiCount += 1
                    }
                } catch {
                    log("AI 翻译第 \(bi + 1)/\(batches.count) 批失败，已跳过")
                }
                progress = 0.50 + 0.15 * Double(bi + 1) / Double(max(1, batches.count))
            }
            log("AI 翻译成功：\(aiCount) 条")
        }
        return aiCount
    }

    // MARK: - 内部工具

    /// 把任意 Error 规范成 LocalizeError（非 LocalizeError 的用 fallback）。
    private func asLocalizeError(_ error: Error, fallback: LocalizeError) -> LocalizeError {
        if let le = error as? LocalizeError { return le }
        return fallback
    }

    private func setPhase(_ text: String, _ p: Double) {
        statusText = text
        progress = p
        log(text)
    }

    private func log(_ s: String) {
        logLines.append(s)
        if logLines.count > 300 {
            logLines.removeFirst(100)
        }
    }

    private func fail(_ error: Error) {
        isWorking = false
        if let le = error as? LocalizedError,
           let desc = le.errorDescription {
            errorMessage = desc
        } else {
            errorMessage = error.localizedDescription
        }
        log("失败：" + errorMessage)
        showError = true
    }

    /// 后台执行（可抛错版）。
    private func runDetached<T: Sendable>(
        _ work: @Sendable @escaping () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// 后台执行（不抛错版）。
    private func runDetached<T: Sendable>(
        _ work: @Sendable @escaping () -> T
    ) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        var out: [[Element]] = []
        var i = 0
        while i < count {
            let end = Swift.min(i + size, count)
            // end > i 恒成立（size > 0），双保险
            guard end > i, i >= 0, end <= count else { break }
            out.append(Array(self[i..<end]))
            i = end
        }
        return out
    }
}
