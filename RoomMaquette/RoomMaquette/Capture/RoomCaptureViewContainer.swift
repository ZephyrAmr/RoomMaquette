import SwiftUI
import RoomPlan

@available(iOS 16.0, *)
public struct RoomCaptureViewContainer: UIViewRepresentable {
    @ObservedObject var captureManager: RoomCaptureManager
    
    public init(captureManager: RoomCaptureManager) {
        self.captureManager = captureManager
    }
    
    public func makeUIView(context: Context) -> RoomCaptureView {
        let view = captureManager.roomCaptureView ?? RoomCaptureView()
        view.delegate = context.coordinator
        return view
    }
    
    public func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        // Dynamic state updates if needed
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    public class Coordinator: NSObject, RoomCaptureViewDelegate {
        var parent: RoomCaptureViewContainer
        
        init(parent: RoomCaptureViewContainer) {
            self.parent = parent
        }
        
        public func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
            // Return true to present Apple's default post-processing view
            return true
        }
        
        public func captureView(didPresent processingRoom: CapturedRoom, error: (any Error)?) {
            if let error = error {
                DispatchQueue.main.async {
                    self.parent.captureManager.errorMessage = error.localizedDescription
                }
                return
            }
            
            // Convert to MaquetteRoom
            let scannedMaquette = MaquetteRoom(from: processingRoom)
            DispatchQueue.main.async {
                self.parent.captureManager.completedRoom = scannedMaquette
                self.parent.captureManager.isDone = true
                self.parent.captureManager.updateLiveStats(
                    walls: scannedMaquette.walls.count,
                    doors: scannedMaquette.doors.count,
                    windows: scannedMaquette.windows.count,
                    objects: scannedMaquette.objects.count
                )
            }
        }
    }
}
