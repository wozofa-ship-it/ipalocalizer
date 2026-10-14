import SwiftUI

// v2.0 全新重写：全屏设计，无 NavigationView，无黑条
struct ContentView: View {
    @StateObject private var vm = LocalizerViewModel()
    @State private var showPicker = false
    @State private var showShare = false
    @State private var showSettings = false
    @State private var showHelp = false

    var body: some View {
        ZStack {
            // 全屏背景
            Color(.systemBackground)
                .ignoresSafeArea(.all)

            VStack(spacing: 0) {
                // 自定义顶栏
                topBar

                ScrollView {
                    VStack(spacing: 20) {
                        headerCard

                        if vm.isWorking {
                            workingView
                        } else if vm.isDone, let r = vm.report {
                            resultView(r)
                        } else if vm.hasFile {
                            fileView
                        } else {
                            emptyView
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                    .padding(.top, 12)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker { vm.setInput(url: $0) }
        }
        .fullScreenCover(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showHelp) { HelpView() }
        .sheet(isPresented: $showShare) {
            if let url = vm.report?.outputURL {
                ShareSheet(url: url)
            }
        }
        .alert("出错了", isPresented: $vm.showError) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(vm.errorMessage)
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack {
            Button { showHelp = true } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 22))
                    .foregroundColor(.primary)
            }

            Spacer()

            Text("IPA 汉化")
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()

            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 22))
                    .foregroundColor(.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    // MARK: - 头部卡片

    private var headerCard: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.15, green: 0.39, blue: 0.92),
                         Color(red: 0.49, green: 0.23, blue: 0.93)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white)
                Text("IPA 汉化工具")
                    .font(.title2).bold()
                    .foregroundColor(.white)
                Text("一键把 IPA 变成中文")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(.vertical, 28)
        }
        .cornerRadius(20)
        .shadow(color: .blue.opacity(0.25), radius: 12, y: 6)
    }

    // MARK: - 空状态

    private var emptyView: some View {
        VStack(spacing: 16) {
            Button {
                showPicker = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 30))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择 IPA 文件")
                            .font(.headline)
                        Text("从「文件」App 中挑选 .ipa")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
            }
            .buttonStyle(.plain)

            Text("自动提取英文 → 翻译 → 打补丁 → 输出汉化版")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - 文件已选

    private var fileView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 56, height: 56)
                    Image(systemName: "app.badge.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.blue)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.inputName)
                        .font(.headline)
                        .lineLimit(2)
                    Text(vm.inputSizeText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)

            Button {
                vm.start()
            } label: {
                Label("开始汉化", systemImage: "wand.and.stars")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .cornerRadius(14)

            Button("重新选择") { showPicker = true }
                .buttonStyle(.bordered)
                .cornerRadius(10)
        }
    }

    // MARK: - 工作中

    private var workingView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                HStack {
                    Text(vm.statusText)
                        .font(.headline)
                    Spacer()
                    Text("\(Int(vm.progress * 100))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: vm.progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(vm.logLines.indices, id: \.self) { i in
                            Text(vm.logLines[i])
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .id(i)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 280)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(12)
                .onChange(of: vm.logLines.count) { _ in
                    if let last = vm.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            Text("处理中请勿退出…")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 完成

    private func resultView(_ r: LocalizeReport) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.green)
                Text("汉化完成")
                    .font(.title2).bold()
            }
            .padding(.top, 8)

            VStack(spacing: 0) {
                statRow(icon: "app.fill", color: .blue, "应用", r.appName)
                Divider().padding(.leading, 44)
                statRow(icon: "tag.fill", color: .purple, "包名", r.bundleID)
                Divider().padding(.leading, 44)
                statRow(icon: "text.magnifyingglass", color: .orange, "候选字符串", "\(r.candidateCount) 条")
                Divider().padding(.leading, 44)
                statRow(icon: "book.fill", color: .teal, "词典翻译", "\(r.dictTranslated) 处")
                Divider().padding(.leading, 44)
                statRow(icon: "sparkles", color: .pink, "AI 翻译", "\(r.aiTranslated) 条")
                Divider().padding(.leading, 44)
                statRow(icon: "hammer.fill", color: .green, "补丁成功", "\(r.patchedCount) 条")
                Divider().padding(.leading, 44)
                statRow(icon: "forward.fill", color: .gray, "跳过", "\(r.skippedCount) 条")
                Divider().padding(.leading, 44)
                statRow(icon: "wrench.fill", color: .indigo, "isASCII 修复", "\(r.flagsPatched) 处")
                Divider().padding(.leading, 44)
                statRow(icon: "archivebox.fill", color: .brown, "输出", r.outputSizeText)
            }
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)

            Text("输出包未签名，安装前请自行签名。")
                .font(.footnote)
                .foregroundColor(.secondary)

            Button {
                showShare = true
            } label: {
                Label("分享 IPA", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .cornerRadius(14)

            Button("再汉化一个") { vm.reset() }
                .buttonStyle(.bordered)
                .cornerRadius(10)
        }
    }

    private func statRow(icon: String, color: Color, _ k: String, _ v: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(color)
            }
            Text(k)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(v)
                .font(.subheadline)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
