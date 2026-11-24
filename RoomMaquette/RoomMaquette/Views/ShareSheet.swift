import SwiftUI
import UIKit

public struct ShareSheet: UIViewControllerRepresentable {
    public var items: [Any]
    public var activities: [UIActivity]? = nil
    
    public init(items: [Any], activities: [UIActivity]? = nil) {
        self.items = items
        self.activities = activities
    }
    
    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: activities)
        return controller
    }
    
    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
