import Foundation
import ARKit
import RoomPlan

public struct LiDARDetector {
    
    /// Checks whether the current device supports Apple's LiDAR RoomPlan scanning
    public static var isLiDARSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 16.0, *) {
            return RoomCaptureSession.isSupported
        } else {
            return false
        }
        #endif
    }
    
    /// Returns a human-friendly description of device hardware capability
    public static var hardwareStatusMessage: String {
        if isLiDARSupported {
            return "iPhone Pro LiDAR Scanner Ready"
        } else {
            #if targetEnvironment(simulator)
            return "Running in Xcode Simulator (Interactive Demo Mode active)"
            #else
            return "LiDAR requires iPhone 12 Pro or newer, or iPad Pro. Demo maquette modes are available."
            #endif
        }
    }
}
