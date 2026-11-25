import SwiftUI
import RoomPlan
import ARKit
import simd

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
        private var updateCounter: Int = 0
        
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
            updateCounter += 1
            var frameSamples: [(UUID, SurfaceColor)] = []
            
            if updateCounter % 3 == 0, #available(iOS 17.0, *) {
                let arFrame = session.arSession.currentFrame
                if let frame = arFrame {
                    for wall in room.walls {
                        let c = SIMD3<Float>(wall.transform.columns.3.x, wall.transform.columns.3.y, wall.transform.columns.3.z)
                        if let col = CameraColorSampler.sampleColor(in: frame, atWorldPoint: c) {
                            frameSamples.append((wall.identifier, col))
                        }
                    }
                    for door in room.doors {
                        let c = SIMD3<Float>(door.transform.columns.3.x, door.transform.columns.3.y, door.transform.columns.3.z)
                        if let col = CameraColorSampler.sampleColor(in: frame, atWorldPoint: c) {
                            frameSamples.append((door.identifier, col))
                        }
                    }
                    for obj in room.objects {
                        let c = SIMD3<Float>(obj.transform.columns.3.x, obj.transform.columns.3.y, obj.transform.columns.3.z)
                        if let col = CameraColorSampler.sampleColor(in: frame, atWorldPoint: c) {
                            frameSamples.append((obj.identifier, col))
                        }
                    }
                }
            }
            
            DispatchQueue.main.async {
                for (id, col) in frameSamples {
                    self.parent.captureManager.recordColorSample(id: id, color: col)
                }
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
