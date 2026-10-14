import SwiftUI

/// 翻译设置：二选一（内置免费 / 自定义 Key）+ 总开关。
/// v2.0 重写：无 NavigationView，全屏设计。
struct SettingsView: View {
    @AppStorage("ai_enabled_v2") private var aiEnabled = false
    @AppStorage("ai_mode") private var aiModeRaw = TranslateMode.builtin.rawValue
    @AppStorage("ai_key") private var aiKey = ""
    @AppStorage("ai_base") private var aiBase = "https://api.openai.com/v1"
    @AppStorage("ai_model") private var aiModel = "gpt-4o-mini"
    @Environment(\.dismiss) private var dismiss

    private var mode: TranslateMode {
        get { TranslateMode(rawValue: aiModeRaw) ?? .builtin }
        nonmutating set { aiModeRaw = newValue.rawValue }
    }

    private var appVersion: String {
        return "v2.0 (1)"
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea(.all)

            VStack(spacing: 0) {
                // 顶栏
                HStack {
                    Spacer()
                    Text("设置")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .overlay(alignment: .trailing) {
                    Button("完成") { dismiss() }
                        .padding(.trailing, 16)
                }
                .padding(.vertical, 12)
                .background(Color(.systemBackground))

                Form {
                    Section(
                        header: Text("AI 翻译"),
                        footer: Text("词典里没有的英文，交给 AI 翻译。关闭后只用词典。")
                    ) {
                        Toggle("启用 AI 翻译", isOn: $aiEnabled)
                    }

                    Section(header: Text("翻译方式")) {
                        Picker("翻译方式", selection: Binding(
                            get: { self.mode },
                            set: { self.mode = $0 }
                        )) {
                            Text("内置翻译").tag(TranslateMode.builtin)
                            Text("自定义 Key").tag(TranslateMode.custom)
                        }
                        .pickerStyle(.segmented)

                        if mode == .builtin {
                            Label(
                                "开箱即用，无需填写任何东西",
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundColor(.secondary)
                            .font(.footnote)
                        }
                    }

                    if mode == .custom {
                        Section(header: Text("自定义接口（OpenAI 兼容）")) {
                            SecureField("API Key", text: $aiKey)
                            TextField("接口地址", text: $aiBase)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            TextField("模型", text: $aiModel)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                    }

                    Section(header: Text("说明")) {
                        Text("内置翻译走免费接口，逐句翻译，失败自动跳过，不影响整体流程。")
                        if mode == .custom {
                            Text("自定义接口兼容 OpenAI 格式，可填写第三方中转地址。")
                            Text("API Key 仅保存在本机，不会上传到你填写地址之外的任何服务器。")
                        }
                        Text("不启用 AI 也能用：词典命中的照常翻译。")
                    }

                    Section {
                        Button("恢复默认") {
                            aiEnabled = false
                            aiModeRaw = TranslateMode.builtin.rawValue
                            aiKey = ""
                            aiBase = "https://api.openai.com/v1"
                            aiModel = "gpt-4o-mini"
                        }
                        .foregroundColor(.red)
                    }

                    Section(header: Text("关于")) {
                        HStack {
                            Text("版本号")
                            Spacer()
                            Text(appVersion)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
}
