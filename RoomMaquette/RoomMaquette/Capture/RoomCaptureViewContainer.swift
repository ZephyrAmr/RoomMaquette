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
        view.captureSession.delegate = context.coordinator
        return view
    }
    
    public func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        // Dynamic state updates if needed
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    @objc(RoomCaptureViewContainerCoordinator)
    public class Coordinator: NSObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
        var parent: RoomCaptureViewContainer
        
        init(parent: RoomCaptureViewContainer) {
            self.parent = parent
            super.init()
        }
        
        required public init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        public func encode(with coder: NSCoder) {
            // No custom encoding needed for coordinator
        }
        
        // MARK: - RoomCaptureSessionDelegate Live Streaming
        
        public func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
            DispatchQueue.main.async {
                self.parent.captureManager.latestCapturedRoom = room
                self.parent.captureManager.updateLiveStats(
                    walls: room.walls.count,
                    doors: room.doors.count,
                    windows: room.windows.count,
                    objects: room.objects.count
                )
            }
        }
        
        public func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
            if let error = error {
                DispatchQueue.main.async {
                    self.parent.captureManager.errorMessage = error.localizedDescription
                }
            }
            
            // Reconstruct finalized beautified room model from captured session data using RoomBuilder
            Task {
                do {
                    let builder = RoomBuilder(options: [.beautifyObjects])
                    let finalized = try await builder.capturedRoom(from: data)
                    DispatchQueue.main.async {
                        self.parent.captureManager.handleFinalizedRoom(finalized)
                    }
                } catch {
                    DispatchQueue.main.async {
                        // Fallback to live streaming capture data
                        self.parent.captureManager.handleFinalizedRoom(nil)
                    }
                }
            }
        }
        
        // MARK: - RoomCaptureViewDelegate
        
        public func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
            // Return false to let the app's seamless HUD handle the reconstruction without modal interruption
            return false
        }
        
        public func captureView(didPresent processingRoom: CapturedRoom, error: (any Error)?) {
            if let error = error {
                DispatchQueue.main.async {
                    self.parent.captureManager.errorMessage = error.localizedDescription
                }
            }
            DispatchQueue.main.async {
                self.parent.captureManager.handleFinalizedRoom(processingRoom)
            }
        }
    }
}
