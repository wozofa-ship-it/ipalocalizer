import Foundation

/// v4 从零重写：二进制补丁核心（防弹版）。
///
/// 字符串替换规则：
/// 1. 中文 UTF-8 字节数必须 <= 原英文长度，否则跳过
/// 2. 长度不够用空格 0x20 填充，不用 NUL
///
/// isASCII 标志修复（Swift 5.7+ codegen）：
/// Swift 字符串字面量构造 (_countAndFlags, _object)，其中
/// movk xE, #0xd000, lsl #48 表示 _countAndFlags = (0xd000<<48)|长度，
/// 0xd000 = isASCII(0x8000) | isNFC(0x4000) | isTailAllocated(0x1000)。
/// 中文非 ASCII，必须改为 0x1000（仅保留 isTailAllocated），否则乱码。
///
/// 安全策略（用户硬性要求）：
/// - 每次数组访问前都做边界检查
/// - 所有循环都有硬上限（防病态二进制导致无限循环/卡死）
/// - 找不到 movk 标志位则跳过该字符串（保留英文），绝不产生乱码
/// - 绝不崩溃：任何异常都跳过
enum BinaryPatcher {

    struct PatchOutcome {
        var patched: [(offset: Int, en: String, zh: String)] = []
        var skipped: [(offset: Int, en: String, zh: String, reason: String)] = []
        var flagsPatched: Int = 0
    }

    // 硬上限（防病态二进制）
    private static let maxLoadCmds = 256
    private static let maxSections = 128
    private static let maxPatches = 20000

    // MARK: - 安全读写

    /// 安全读 4 字节小端，越界返回 nil。
    private static func read32(_ bytes: [UInt8], _ off: Int) -> UInt32? {
        guard off >= 0, off + 4 <= bytes.count else { return nil }
        return UInt32(bytes[off])
            | (UInt32(bytes[off + 1]) << 8)
            | (UInt32(bytes[off + 2]) << 16)
            | (UInt32(bytes[off + 3]) << 24)
    }

    /// 安全读 8 字节小端，越界返回 nil。
    private static func read64(_ bytes: [UInt8], _ off: Int) -> UInt64? {
        guard let lo = read32(bytes, off), let hi = read32(bytes, off + 4)
        else { return nil }
        return UInt64(lo) | (UInt64(hi) << 32)
    }

    /// 安全写 4 字节小端，越界时静默跳过（不崩溃）。
    private static func write32(_ bytes: inout [UInt8], _ off: Int, _ val: UInt32) {
        guard off >= 0, off + 4 <= bytes.count else { return }
        bytes[off] = UInt8(val & 0xFF)
        bytes[off + 1] = UInt8((val >> 8) & 0xFF)
        bytes[off + 2] = UInt8((val >> 16) & 0xFF)
        bytes[off + 3] = UInt8((val >> 24) & 0xFF)
    }

    /// 安全读字节，越界返回 nil。
    private static func byteAt(_ bytes: [UInt8], _ i: Int) -> UInt8? {
        guard i >= 0, i < bytes.count else { return nil }
        return bytes[i]
    }

    // MARK: - Mach-O 解析（arm64，最小实现，防弹版）

    private struct MachOSections {
        let textFileOff: Int
        let textSize: Int
        let textVMAddr: UInt64
        let cstringFileOff: Int
        let cstringSize: Int
        let cstringVMAddr: UInt64
    }

    private static func parseMachO(_ bytes: [UInt8]) -> MachOSections? {
        guard bytes.count >= 32 else { return nil }
        guard read32(bytes, 0) == 0xfeedfacf else { return nil } // 64-bit magic
        guard let ncmdsRaw = read32(bytes, 16) else { return nil }
        // ncmds 必须是个合理的小数字，防垃圾值导致超长循环
        guard ncmdsRaw <= UInt32(maxLoadCmds) else { return nil }
        let ncmds = Int(ncmdsRaw)

        var off = 32
        var textFileOff: Int?
        var textSize: Int?
        var textVMAddr: UInt64?
        var cstringFileOff: Int?
        var cstringSize: Int?
        var cstringVMAddr: UInt64?

        for _ in 0..<ncmds {
            guard let cmd = read32(bytes, off),
                  let cmdsizeRaw = read32(bytes, off + 4) else { return nil }
            let cmdsize = Int(cmdsizeRaw)
            guard cmdsize >= 8, off >= 0, off + cmdsize <= bytes.count else { return nil }
            if cmd == 0x19 { // LC_SEGMENT_64
                guard let nsectsRaw = read32(bytes, off + 64) else { break }
                guard nsectsRaw <= UInt32(maxSections) else { break }
                let nsects = Int(nsectsRaw)
                var so = off + 72
                for _ in 0..<nsects {
                    guard so >= 0, so + 80 <= off + cmdsize else { break }
                    guard so + 16 <= bytes.count else { break }
                    var nameBytes = Array(bytes[so..<(so + 16)])
                    if let z = nameBytes.firstIndex(of: 0) {
                        nameBytes = Array(nameBytes[..<z])
                    }
                    let sectName = String(bytes: nameBytes, encoding: .ascii) ?? ""
                    if sectName == "__text" {
                        guard let v = read64(bytes, so + 32),
                              let s = read64(bytes, so + 40),
                              let f = read32(bytes, so + 48) else { break }
                        textVMAddr = v
                        textSize = Int(s)
                        textFileOff = Int(f)
                    } else if sectName == "__cstring" {
                        guard let v = read64(bytes, so + 32),
                              let s = read64(bytes, so + 40),
                              let f = read32(bytes, so + 48) else { break }
                        cstringVMAddr = v
                        cstringSize = Int(s)
                        cstringFileOff = Int(f)
                    }
                    so += 80
                }
            }
            off += cmdsize
        }

        guard let tfo = textFileOff, let ts = textSize, let tva = textVMAddr,
              let cfo = cstringFileOff, let cs = cstringSize, let cva = cstringVMAddr,
              tfo >= 0, ts >= 0, cfo >= 0, cs >= 0,
              tfo + ts <= bytes.count, cfo + cs <= bytes.count
        else { return nil }
        return MachOSections(
            textFileOff: tfo, textSize: ts, textVMAddr: tva,
            cstringFileOff: cfo, cstringSize: cs, cstringVMAddr: cva)
    }

    // MARK: - 标志位查找

    /// 为指定字符串查找所有需要修改的 movk 指令位置（文件偏移）。
    /// 策略：xref 找 adrp+add 引用点 → 引用点附近找 movz/movk 对（count 必须匹配）。
    /// 全部安全访问，找不到返回空数组（调用方跳过该字符串）。
    private static func findFlagOffsets(
        stringFileOff: Int,
        enByteLen: Int,
        bytes: [UInt8],
        macho: MachOSections
    ) -> [Int] {
        guard stringFileOff >= macho.cstringFileOff,
              stringFileOff < macho.cstringFileOff + macho.cstringSize
        else { return [] }

        let strVMAddr = UInt64(stringFileOff - macho.cstringFileOff) + macho.cstringVMAddr
        let targetPage = strVMAddr & ~0xFFF
        let targetOff12 = Int(strVMAddr & 0xFFF)

        let textStart = macho.textFileOff
        let textEnd = textStart + macho.textSize
        guard textStart >= 0, textEnd <= bytes.count, textStart < textEnd else { return [] }

        // 1. 找 adrp+add 引用点
        var refs: [Int] = []
        var i = textStart
        while i + 8 <= textEnd {
            guard let w = read32(bytes, i) else { break }
            if (w & 0x9F000000) == 0x90000000 { // adrp
                let rd = Int(w & 0x1F)
                var imm = (Int((w >> 5) & 0x7FFFF) << 2) | Int((w >> 29) & 0x3)
                if imm & 0x100000 != 0 { imm -= 0x200000 }
                let pc = macho.textVMAddr + UInt64(i - textStart)
                let page: UInt64
                if imm >= 0 {
                    page = (pc & ~0xFFF) + UInt64(imm * 0x1000)
                } else {
                    page = (pc & ~0xFFF) - UInt64((-imm) * 0x1000)
                }
                if page == targetPage {
                    guard let w2 = read32(bytes, i + 4) else { break }
                    if (w2 & 0xFF000000) == 0x91000000 { // add (immediate)
                        let rd2 = Int(w2 & 0x1F)
                        let rn2 = Int((w2 >> 5) & 0x1F)
                        let imm12 = Int((w2 >> 10) & 0xFFF)
                        if rd2 == rd && rn2 == rd && imm12 == targetOff12 {
                            refs.append(i)
                            if refs.count > 64 { break } // 防病态
                        }
                    }
                }
            }
            i += 4
        }
        if refs.isEmpty { return [] }

        // 2. 每个引用点附近找 movz/movk 对
        var movkOffs = Set<Int>()
        for r in refs {
            var j = r
            let searchEnd = min(r + 400, textEnd - 8)
            while j < searchEnd {
                guard let w = read32(bytes, j) else { break }
                if (w & 0xFF800000) == 0xD2800000 && ((w >> 21) & 0x3) == 0 {
                    let rd = Int(w & 0x1F)
                    let cnt = Int((w >> 5) & 0xFFFF)
                    if cnt == enByteLen {
                        var k = j + 4
                        let mkEnd = min(k + 16, textEnd - 4)
                        while k < mkEnd {
                            guard let w2 = read32(bytes, k) else { break }
                            if (w2 & 0xFF800000) == 0xF2800000
                                && ((w2 >> 21) & 0x3) == 3
                                && ((w2 >> 5) & 0xFFFF) == 0xD000
                                && Int(w2 & 0x1F) == rd {
                                if verifyMovkOwner(
                                    movkOff: k, strVMAddr: strVMAddr,
                                    bytes: bytes, macho: macho) {
                                    movkOffs.insert(k)
                                }
                                break
                            }
                            k += 4
                        }
                    }
                }
                j += 4
            }
            if movkOffs.count > 64 { break }
        }
        return movkOffs.sorted()
    }

    /// 验证 movk 位置确实属于指定字符串。
    private static func verifyMovkOwner(
        movkOff: Int,
        strVMAddr: UInt64,
        bytes: [UInt8],
        macho: MachOSections
    ) -> Bool {
        let textStart = macho.textFileOff
        var j = movkOff - 4
        let searchStart = max(movkOff - 400, textStart)
        while j >= searchStart {
            guard let w = read32(bytes, j) else { return false }
            if (w & 0x9F000000) == 0x90000000 { // adrp
                let rd = Int(w & 0x1F)
                var imm = (Int((w >> 5) & 0x7FFFF) << 2) | Int((w >> 29) & 0x3)
                if imm & 0x100000 != 0 { imm -= 0x200000 }
                let pc = macho.textVMAddr + UInt64(j - textStart)
                let page: UInt64
                if imm >= 0 {
                    page = (pc & ~0xFFF) + UInt64(imm * 0x1000)
                } else {
                    page = (pc & ~0xFFF) - UInt64((-imm) * 0x1000)
                }
                let csPageStart = macho.cstringVMAddr & ~0xFFF
                if page >= csPageStart && page < csPageStart + 0x2000 {
                    guard let w2 = read32(bytes, j + 4) else { return false }
                    if (w2 & 0xFF000000) == 0x91000000 {
                        let rd2 = Int(w2 & 0x1F)
                        let rn2 = Int((w2 >> 5) & 0x1F)
                        let imm12 = Int((w2 >> 10) & 0xFFF)
                        if rd2 == rd && rn2 == rd {
                            let target = page + UInt64(imm12)
                            return target == strVMAddr
                        }
                    }
                }
            }
            j -= 4
        }
        return false
    }

    // MARK: - 主入口

    /// 对二进制打字符串补丁 + isASCII 标志补丁。直接修改传入的 bytes。
    /// 严格模式：找不到 movk 标志位则跳过该字符串（保留英文），绝不产生乱码。
    /// 绝不崩溃：任何异常都跳过。
    static func apply(
        to bytes: inout [UInt8],
        patches: [(offset: Int, en: String, zh: String)]
    ) -> PatchOutcome {
        var out = PatchOutcome()

        let macho = parseMachO(bytes)
        let n = bytes.count

        for p in patches {
            // 硬上限：补丁太多就停
            if out.patched.count + out.skipped.count >= maxPatches { break }

            guard let enData = p.en.data(using: .ascii) else {
                out.skipped.append((p.offset, p.en, p.zh, "原文非 ASCII"))
                continue
            }
            let enBytes = [UInt8](enData)
            if enBytes.isEmpty {
                out.skipped.append((p.offset, p.en, p.zh, "原文为空"))
                continue
            }
            let zhBytes = [UInt8](p.zh.utf8)

            if zhBytes.count > enBytes.count {
                out.skipped.append(
                    (p.offset, p.en, p.zh,
                     "译文超长(\(zhBytes.count)>\(enBytes.count))"))
                continue
            }

            // 严格模式：先找 isASCII 标志位，找不到则跳过
            var flagOffs: [Int] = []
            if let m = macho {
                flagOffs = findFlagOffsets(
                    stringFileOff: p.offset,
                    enByteLen: enBytes.count,
                    bytes: bytes,
                    macho: m)
            }
            if flagOffs.isEmpty {
                out.skipped.append((p.offset, p.en, p.zh, "skip_no_ascii_fix"))
                continue
            }

            // 校验原位置内容（含结尾 NUL）
            let total = enBytes.count + 1
            guard p.offset >= 0, p.offset + total <= n else {
                out.skipped.append((p.offset, p.en, p.zh, "越界"))
                continue
            }
            // 逐字节比对（安全访问）
            var matches = true
            for idx in 0..<enBytes.count {
                guard let cur = byteAt(bytes, p.offset + idx),
                      cur == enBytes[idx] else {
                    matches = false
                    break
                }
            }
            if matches {
                if let nul = byteAt(bytes, p.offset + enBytes.count),
                   nul == 0x00 {
                    // 内容匹配，继续
                } else {
                    matches = false
                }
            }
            if !matches {
                out.skipped.append((p.offset, p.en, p.zh, "内容不匹配"))
                continue
            }

            // 中文 + 空格填充 + NUL（安全写）
            var replacement = zhBytes
            replacement += [UInt8](repeating: 0x20,
                                   count: enBytes.count - zhBytes.count)
            replacement += [0x00]
            guard replacement.count == total else {
                out.skipped.append((p.offset, p.en, p.zh, "替换长度异常"))
                continue
            }
            for idx in 0..<total {
                let dst = p.offset + idx
                guard dst >= 0, dst < n, idx < replacement.count else {
                    matches = false
                    break
                }
                bytes[dst] = replacement[idx]
            }
            if !matches {
                out.skipped.append((p.offset, p.en, p.zh, "写入越界"))
                continue
            }

            // 修复标志位：movk #0xd000 -> #0x1000
            for fo in flagOffs {
                guard let w = read32(bytes, fo) else { continue }
                // 二次确认：仍是 movk xD, #0xd000, lsl #48
                if (w & 0xFFFFFFE0) == 0xF2FA0000 {
                    let newW = (w & 0x1F) | 0xF2E20000
                    write32(&bytes, fo, newW)
                    out.flagsPatched += 1
                }
            }

            out.patched.append((p.offset, p.en, p.zh))
        }

        return out
    }
}
