import SwiftUI

/// 系统分享框（存到"文件"、隔空投送等）
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(
            activityItems: [url], applicationActivities: nil)
        return vc
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
