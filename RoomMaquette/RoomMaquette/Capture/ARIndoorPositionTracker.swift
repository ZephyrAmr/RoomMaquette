import Foundation
import ARKit
import Combine
import SwiftUI

public class ARIndoorPositionTracker: NSObject, ObservableObject, ARSessionDelegate {
    @Published public var currentPosition: SIMD3<Float>? = nil
    @Published public var currentHeading: Float? = nil // radians, 0 = facing +Z
    @Published public var isTracking: Bool = false
    @Published public var trackingStatusText: String = "Initializing AR..."
    @Published public var isCalibrated: Bool = false
    
    public var session: ARSession
    
    // Calibration offsets
    private var positionOffset: SIMD3<Float> = .zero
    private var headingOffset: Float = 0.0
    private var rawPosition: SIMD3<Float> = .zero
    private var rawHeading: Float = 0.0
    
    public override init() {
        self.session = ARSession()
        super.init()
        self.session.delegate = self
    }
    
    public func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            trackingStatusText = "AR Tracking not supported"
            return
        }
        
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        if #available(iOS 13.0, *), ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        config.planeDetection = [.horizontal, .vertical]
        
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isTracking = true
        trackingStatusText = "Looking for room surfaces..."
    }
    
    public func stop() {
        session.pause()
        isTracking = false
        currentPosition = nil
        currentHeading = nil
    }
    
    /// Calibrate current physical position to a known point on the 2D floor plan
    public func calibrateCurrentPosition(to roomPoint: SIMD3<Float>) {
        self.positionOffset = roomPoint - rawPosition
        self.isCalibrated = true
        self.currentPosition = roomPoint
    }
    
    /// Reset position offset to raw session coordinates
    public func resetCalibration() {
        self.positionOffset = .zero
        self.headingOffset = 0.0
        self.isCalibrated = false
    }
    
    // MARK: - ARSessionDelegate
    
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let transform = frame.camera.transform
        
        // Extract raw world camera position (columns.3 is translation)
        let rawPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        self.rawPosition = rawPos
        
        // Extract camera forward direction vector in XZ plane (-columns.2 is camera facing direction in ARKit)
        let forward = -SIMD3<Float>(transform.columns.2.x, 0, transform.columns.2.z)
        let rawHead = atan2(forward.x, forward.z)
        self.rawHeading = rawHead
        
        // Apply calibration offset
        let calibratedPos = rawPos + positionOffset
        let calibratedHead = rawHead + headingOffset
        
        DispatchQueue.main.async {
            self.currentPosition = calibratedPos
            self.currentHeading = calibratedHead
        }
    }
    
    public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        DispatchQueue.main.async {
            switch camera.trackingState {
            case .normal:
                self.trackingStatusText = "LiDAR Tracking Active"
            case .notAvailable:
                self.trackingStatusText = "Tracking Unavailable"
            case .limited(let reason):
                switch reason {
                case .initializing:
                    self.trackingStatusText = "Scanning Room..."
                case .excessiveMotion:
                    self.trackingStatusText = "Slow Down Device Motion"
                case .insufficientFeatures:
                    self.trackingStatusText = "Point at Walls or Floor"
                case .relocalizing:
                    self.trackingStatusText = "Relocalizing Position..."
                @unknown default:
                    self.trackingStatusText = "Tracking Limited"
                }
            }
        }
    }
    
    public func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.trackingStatusText = "AR Session Error: \(error.localizedDescription)"
        }
    }
}
