import SwiftUI
import UniformTypeIdentifiers

/// 系统文件选择器（只选 .ipa）
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(
        context: Context
    ) -> UIDocumentPickerViewController {
        let ipaType = UTType(filenameExtension: "ipa") ?? .data
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [ipaType], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
