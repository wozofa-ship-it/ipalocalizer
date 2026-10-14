import Foundation

/// 全中文错误描述，展示给用户，不闪退。
enum LocalizeError: LocalizedError {
    case noFileSelected
    case notIPAFile
    case unzipFailed
    case invalidStructure(String)
    case binaryReadFailed
    case nothingToTranslate
    case repackFailed
    case verifyFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFileSelected:
            return "请先选择一个 IPA 文件。"
        case .notIPAFile:
            return "请选择 .ipa 文件。"
        case .unzipFailed:
            return "IPA 文件损坏，无法解压。"
        case .invalidStructure(let detail):
            return "IPA 结构异常：" + detail
        case .binaryReadFailed:
            return "无法读取主程序文件。"
        case .nothingToTranslate:
            return "没有找到可汉化的字符串（词典未命中，AI 翻译也未开启或无可用翻译）。"
        case .repackFailed:
            return "重新打包失败。"
        case .verifyFailed(let detail):
            return "输出验证失败：" + detail
        }
    }
}

enum AIError: LocalizedError {
    case notConfigured
    case network(Error)
    case badResponse(Int)
    case parseFailed
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI 未配置：请在设置里填写 API Key。"
        case .network(let e):
            return "网络错误：" + e.localizedDescription
        case .badResponse(let code):
            return "接口返回异常（HTTP \(code)），请检查 Key 和接口地址。"
        case .parseFailed:
            return "AI 返回解析失败，已跳过本批。"
        case .emptyResult:
            return "AI 返回为空，已跳过本批。"
        }
    }
}
