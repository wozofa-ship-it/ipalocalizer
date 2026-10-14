import Foundation

/// 候选字符串：二进制中的文件偏移 + ASCII 文本。
struct CandidateString: Sendable {
    let offset: Int
    let text: String
}

/// v4 从零重写：防弹式 C 字符串扫描器。
///
/// 设计原则（用户硬性要求：绝不闪退）：
/// 1. 每次下标访问前都做边界检查，绝不依赖"前面 guard 过了所以这里安全"的推理
/// 2. 不用 NSRegularExpression（历史上有回溯卡死嫌疑），只用简单字符判断
/// 3. 不用 try! / 强制解包，全部安全处理
/// 4. 硬上限：单字符串最大长度、候选总数上限，防止病态二进制耗尽内存
/// 5. 任何异常情况都跳过（skip），绝不崩溃
enum StringExtractor {

    private static let minLen = 3
    private static let maxLen = 200
    private static let maxCandidates = 30000
    // 单次可打印 runs 扫描上限（防病态超长 runs）
    private static let maxRunScan = 512

    private static func isPrintable(_ b: UInt8) -> Bool {
        return (b >= 0x20 && b <= 0x7E) || b == 0x09
    }

    /// 安全读一个字节，越界返回 nil（调用方跳过）。
    private static func byteAt(_ bytes: [UInt8], _ i: Int) -> UInt8? {
        guard i >= 0, i < bytes.count else { return nil }
        return bytes[i]
    }

    /// 扫描二进制，返回候选 (offset, string)，按 offset 升序。
    /// 绝不崩溃：任何越界/异常都跳过。
    static func extract(from bytes: [UInt8]) -> [CandidateString] {
        var out: [CandidateString] = []
        out.reserveCapacity(4096)

        let n = bytes.count
        // 空文件或过小：直接返回空
        guard n > minLen else { return out }

        var i = 0
        while i < n {
            // 硬上限：候选够多了就停（防内存爆炸）
            if out.count >= maxCandidates { break }
            // i 只增不减，理论上恒 >= 0；仍做检查，防未来改动引入 bug
            if i < 0 { break }

            guard let b = byteAt(bytes, i) else { break }
            if isPrintable(b) {
                let start = i
                // 向前扫描可打印 runs，带上限
                var scanned = 0
                while scanned < maxRunScan {
                    guard let c = byteAt(bytes, i) else { break }
                    if !isPrintable(c) { break }
                    i += 1
                    scanned += 1
                }
                let len = i - start
                // 必须：长度合法 + 紧跟 NUL（且 NUL 下标安全）
                if len >= minLen, len <= maxLen,
                   let nul = byteAt(bytes, i), nul == 0x00 {
                    // 切片边界二次确认
                    if start >= 0, len > 0, start + len <= n {
                        let slice = bytes[start..<(start + len)]
                        // String(bytes:encoding:) 返回 nil 时跳过，不崩溃
                        if let s = String(bytes: slice, encoding: .ascii),
                           shouldKeep(s) {
                            out.append(CandidateString(offset: start, text: s))
                        }
                    }
                    // 跳过 NUL，继续
                    i += 1
                }
                // 注意：若 len 不合法或无 NUL，i 已停在第一个不可打印字符处，
                // 外层循环的 else 分支会推进。不需要额外处理。
                // 但若内层循环因 maxRunScan 截断而停（i 仍在可打印区），
                // 外层会把当前位置当作新字符串起点重新扫描——会推进，不会死循环。
                // 极端保护：如果 i 没有推进，强制 +1（防死循环）
                if i == start {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return out
    }

    /// 启发式过滤：明显不用翻的字符串返回 false。
    /// 纯字符判断，无正则，无崩溃点。
    private static func shouldKeep(_ s: String) -> Bool {
        // 去首尾空白；空字符串直接丢
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.count < minLen { return false }

        // 必须含至少一个 ASCII 字母（过滤纯数字/符号/乱码）
        var hasLetter = false
        for scalar in t.unicodeScalars {
            let v = scalar.value
            if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) {
                hasLetter = true
                break
            }
        }
        if !hasLetter { return false }

        // 前缀黑名单
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return false }
        if t.hasPrefix("ftp://") { return false }
        if t.hasPrefix("/") || t.hasPrefix("~") { return false }
        if t.hasPrefix("_") || t.hasPrefix("$") { return false }
        // NS/UI + 大写：系统类名前缀（如 NSUserDefaults），用安全索引
        if t.hasPrefix("NS") || t.hasPrefix("UI") {
            if t.count > 2 {
                // count > 2 已保证 offsetBy:2 安全，仍用 limitedBy 双保险
                if let safeIdx = t.index(t.startIndex, offsetBy: 2,
                                         limitedBy: t.endIndex),
                   safeIdx < t.endIndex {
                    let ch = t[safeIdx]
                    if ch.isUppercase { return false }
                } else {
                    // 索引越界（理论上不可能）：保守跳过
                    return false
                }
            }
        }

        // 子串黑名单
        if t.contains(".framework/") { return false }
        if t.contains("@2x") || t.contains("@3x") { return false }

        // 文件后缀黑名单（大小写不敏感）
        let lower = t.lowercased()
        let badSuffixes = [".png", ".jpg", ".jpeg", ".gif", ".plist",
                           ".strings", ".nib", ".car", ".bundle",
                           ".dylib", ".framework", ".ttf", ".otf"]
        for suf in badSuffixes {
            if lower.hasSuffix(suf) { return false }
        }

        // 纯符号（含空格）：无字母无数字
        var hasAlphaNum = false
        for scalar in t.unicodeScalars {
            let v = scalar.value
            let isAlphaNum = (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
                || (v >= 48 && v <= 57)
            if isAlphaNum { hasAlphaNum = true; break }
        }
        if !hasAlphaNum { return false }

        return true
    }
}
