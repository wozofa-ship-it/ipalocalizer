import SwiftUI

/// 使用说明页
/// v2.0 重写：无 NavigationView，全屏设计。
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea(.all)

            VStack(spacing: 0) {
                // 顶栏
                HStack {
                    Spacer()
                    Text("使用说明")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .overlay(alignment: .trailing) {
                    Button("知道了") { dismiss() }
                        .padding(.trailing, 16)
                }
                .padding(.vertical, 12)
                .background(Color(.systemBackground))

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        helpSection(
                            "1. 选择 IPA",
                            "点「选择 IPA 文件」，从「文件」App 里挑一个 .ipa。")
                        helpSection(
                            "2. 开始汉化",
                            "确认文件名和大小无误后，点「开始汉化」。App 会自动：解包 → 提取英文 → 词典翻译 → AI 翻译（可选）→ 打二进制补丁 → 重新打包 → 验证。")
                        helpSection(
                            "3. 分享安装",
                            "完成后点「分享 IPA」，存到「文件」或隔空投送到电脑。输出包未签名，安装前请自行签名（如用 SideStore、TrollStore 或自签工具）。")
                        helpSection(
                            "AI 翻译",
                            "右上角齿轮 → 设置，可开启 AI 翻译并填写自己的 Key（兼容 OpenAI 接口）。词典里没有的英文会交给 AI 翻；不填 Key 也能用词典。")
                        helpSection(
                            "注意",
                            "• 部分字符串（如 SwiftUI 运行时动态生成的）在二进制里不存在，翻不了。\n• 译文太长的会自动跳过，避免破坏二进制。\n• 汉化只改显示文字，不改 App 功能。")
                    }
                    .padding()
                }
            }
        }
    }

    private func helpSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body)
                .font(.body)
                .foregroundColor(.secondary)
        }
    }
}
