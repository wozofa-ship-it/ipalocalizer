import Foundation

/// 词典翻译：精确匹配（去首尾空格后查词典）
enum Translator {
    static func lookup(_ text: String) -> String? {
        let key = text.trimmingCharacters(in: .whitespaces)
        return BuiltinDictionary.entries[key]
    }
}
