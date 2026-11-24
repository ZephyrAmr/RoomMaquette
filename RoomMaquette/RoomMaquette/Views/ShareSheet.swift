import SwiftUI
import UIKit

public struct ShareSheetHelper {
    public static func present(items: [Any], sourceView: UIView? = nil) {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                  let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                return
            }
            
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            
            let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
            
            if let popover = activityVC.popoverPresentationController {
                if let source = sourceView {
                    popover.sourceView = source
                    popover.sourceRect = source.bounds
                } else {
                    popover.sourceView = topVC.view
                    popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
            }
            
            topVC.present(activityVC, animated: true, completion: nil)
        }
    }
}

public struct ShareSheet: UIViewControllerRepresentable {
    public var items: [Any]
    public var activities: [UIActivity]? = nil
    
    public init(items: [Any], activities: [UIActivity]? = nil) {
        self.items = items
        self.activities = activities
    }
    
    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: activities)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: 200, y: 200, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return controller
    }
    
    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
