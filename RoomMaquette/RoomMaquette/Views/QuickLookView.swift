import SwiftUI
import QuickLook

public struct QuickLookView: UIViewControllerRepresentable {
    public var previewItemURL: URL
    
    public init(previewItemURL: URL) {
        self.previewItemURL = previewItemURL
    }
    
    public func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        let nav = UINavigationController(rootViewController: controller)
        return nav
    }
    
    public func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    public class Coordinator: NSObject, QLPreviewControllerDataSource {
        var parent: QuickLookView
        
        init(parent: QuickLookView) {
            self.parent = parent
        }
        
        public func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            return 1
        }
        
        public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return parent.previewItemURL as NSURL
        }
    }
}
