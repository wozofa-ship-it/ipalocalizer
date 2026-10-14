import Foundation
import ZIPFoundation

/// 解包后的 IPA 信息。
struct UnpackedIPA {
    let workDir: URL
    let appDir: URL
    let binaryURL: URL
    let bundleID: String
    let appName: String
}

/// v4 防弹版：所有文件操作都做存在性/类型检查，失败抛中文错误（不崩溃）。
enum IPAUtils {

    /// 解压 IPA，定位主二进制。返回工作目录等信息。
    /// 调用方负责在完成后删除 workDir（ViewModel 的 defer 已处理）。
    static func prepare(inputURL: URL) throws -> UnpackedIPA {
        let fm = FileManager.default

        // 输入文件必须存在且是文件
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inputURL.path, isDirectory: &isDir),
              !isDir.boolValue else {
            throw LocalizeError.invalidStructure("输入文件不存在")
        }
        // 文件不能太小（至少 10KB 才像个 IPA）
        if let attrs = try? fm.attributesOfItem(atPath: inputURL.path),
           let size = attrs[.size] as? Int64, size < 10 * 1024 {
            throw LocalizeError.invalidStructure("输入文件过小，不像 IPA")
        }

        let workDir = fm.temporaryDirectory
            .appendingPathComponent("ipaloc_" + UUID().uuidString)
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            throw LocalizeError.invalidStructure("无法创建工作目录")
        }

        let localIPA = workDir.appendingPathComponent("input.ipa")
        if localIPA.path != inputURL.path {
            do {
                // 先删目标（防残留），再拷贝
                if fm.fileExists(atPath: localIPA.path) {
                    try fm.removeItem(at: localIPA)
                }
                try fm.copyItem(at: inputURL, to: localIPA)
            } catch {
                cleanup(workDir: workDir)
                throw LocalizeError.invalidStructure("无法读取输入文件")
            }
        }

        do {
            try fm.unzipItem(at: localIPA, to: workDir)
        } catch {
            cleanup(workDir: workDir)
            throw LocalizeError.unzipFailed
        }
        // 解压后删除 ipa 拷贝（失败也不影响）
        try? fm.removeItem(at: localIPA)

        let payload = workDir.appendingPathComponent("Payload")
        var payloadIsDir: ObjCBool = false
        guard fm.fileExists(atPath: payload.path, isDirectory: &payloadIsDir),
              payloadIsDir.boolValue else {
            cleanup(workDir: workDir)
            throw LocalizeError.invalidStructure("缺少 Payload 目录")
        }

        let apps: [URL]
        do {
            apps = try fm.contentsOfDirectory(
                at: payload,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            cleanup(workDir: workDir)
            throw LocalizeError.invalidStructure("无法读取 Payload 目录")
        }

        var appDir: URL?
        for url in apps {
            // 必须以 .app 结尾且是目录
            guard url.pathExtension.lowercased() == "app" else { continue }
            var d: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &d), d.boolValue {
                appDir = url
                break
            }
        }
        guard let appDir else {
            cleanup(workDir: workDir)
            throw LocalizeError.invalidStructure("Payload 里找不到 .app")
        }

        // 读 Info.plist（两层保护：Data 读取 + plist 解析）
        let infoURL = appDir.appendingPathComponent("Info.plist")
        guard fm.fileExists(atPath: infoURL.path) else {
            cleanup(workDir: workDir)
            throw LocalizeError.invalidStructure("Info.plist 读取失败")
        }
        guard let infoData = try? Data(contentsOf: infoURL),
              !infoData.isEmpty else {
            cleanup(workDir: workDir)
            throw LocalizeError.invalidStructure("Info.plist 读取失败")
        }
        guard let plist = try? PropertyListSerialization.propertyList(
                from: infoData, format: nil),
              let info = plist as? [String: Any] else {
            cleanup(workDir: workDir)
            throw LocalizeError.invalidStructure("Info.plist 读取失败")
        }
        guard let exeName = info["CFBundleExecutable"] as? String,
              !exeName.isEmpty,
              !exeName.contains("/"), !exeName.contains("..") else {
            cleanup(workDir: workDir)
            throw LocalizeError.invalidStructure("Info.plist 缺少主程序名")
        }

        let binaryURL = appDir.appendingPathComponent(exeName)
        var binIsDir: ObjCBool = false
        guard fm.fileExists(atPath: binaryURL.path, isDirectory: &binIsDir),
              !binIsDir.boolValue else {
            cleanup(workDir: workDir)
            throw LocalizeError.invalidStructure("找不到主程序文件")
        }
        // 主程序不能太小
        if let attrs = try? fm.attributesOfItem(atPath: binaryURL.path),
           let size = attrs[.size] as? Int64, size < 1024 {
            cleanup(workDir: workDir)
            throw LocalizeError.invalidStructure("主程序文件异常")
        }

        let bundleID = info["CFBundleIdentifier"] as? String ?? ""
        let appName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? exeName

        return UnpackedIPA(
            workDir: workDir, appDir: appDir, binaryURL: binaryURL,
            bundleID: bundleID, appName: appName)
    }

    /// 重新打包成 IPA（Payload 顶层目录结构）。
    static func repack(workDir: URL, outputURL: URL) throws {
        let fm = FileManager.default
        let payload = workDir.appendingPathComponent("Payload")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: payload.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw LocalizeError.invalidStructure("打包时找不到 Payload")
        }
        if fm.fileExists(atPath: outputURL.path) {
            try? fm.removeItem(at: outputURL)
        }
        do {
            try fm.zipItem(at: payload, to: outputURL, shouldKeepParent: true)
        } catch {
            throw LocalizeError.repackFailed
        }
    }

    /// 验证输出 IPA：能打开、含 Payload 条目、非空。
    static func verify(ipaURL: URL) throws {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: ipaURL.path),
              let size = attrs[.size] as? Int64, size > 1024 else {
            throw LocalizeError.verifyFailed("输出文件为空或过小")
        }
        guard let archive = Archive(url: ipaURL, accessMode: .read) else {
            throw LocalizeError.verifyFailed("无法打开输出文件")
        }
        var hasPayload = false
        for entry in archive {
            if entry.path.hasPrefix("Payload/") {
                hasPayload = true
                break
            }
        }
        guard hasPayload else {
            throw LocalizeError.verifyFailed("输出包缺少 Payload")
        }
    }

    /// 删除工作目录（失败静默，绝不抛错）。
    static func cleanup(workDir: URL) {
        try? FileManager.default.removeItem(at: workDir)
    }
}
