import Foundation
import ARKit
import Combine
import SwiftUI
import CoreVideo
import simd

public class ARIndoorPositionTracker: NSObject, ObservableObject, ARSessionDelegate {
    @Published public var currentPosition: SIMD3<Float>? = nil
    @Published public var currentHeading: Float? = nil // radians on 2D canvas (0 = +X, pi/2 = +Z)
    @Published public var isTracking: Bool = false
    @Published public var trackingStatusText: String = "Scanning room to locate..."
    @Published public var isCalibrated: Bool = false
    @Published public var isAutoLocalized: Bool = false
    @Published public var localizedTargetName: String? = nil
    @Published public var targetDistanceMeters: Float? = nil
    @Published public var localizationConfidence: Float = 0.0
    
    public var session: ARSession
    public var room: MaquetteRoom?
    
    // Rigid SE(2) Transformation parameters from AR coordinate space to Room coordinate space:
    // roomPos.x = rawPos.x * cos(alignmentAngle) - rawPos.z * sin(alignmentAngle) + alignmentOffset.x
    // roomPos.z = rawPos.x * sin(alignmentAngle) + rawPos.z * cos(alignmentAngle) + alignmentOffset.z
    private var alignmentAngle: Float = 0.0
    private var alignmentOffset: SIMD3<Float> = .zero
    
    // Auto-localization temporal hypothesis tracking
    private var candidateStreak: Int = 0
    private var lastCandidateWallId: UUID? = nil
    private var frameCount: Int = 0
    
    public override init() {
        self.session = ARSession()
        super.init()
        self.session.delegate = self
    }
    
    public func start(with room: MaquetteRoom? = nil) {
        self.room = room
        
        guard ARWorldTrackingConfiguration.isSupported else {
            trackingStatusText = "AR Tracking not supported on this device"
            return
        }
        
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        
        if #available(iOS 13.0, *), ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if #available(iOS 14.0, *), ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        config.planeDetection = [.horizontal, .vertical]
        
        // Reset transformation state
        if let r = room {
            let bounds = r.boundingBox
            let center = (bounds.min + bounds.max) / 2.0
            self.alignmentOffset = SIMD3<Float>(center.x, 0, center.z)
        } else {
            self.alignmentOffset = .zero
        }
        self.alignmentAngle = 0.0
        self.isCalibrated = false
        self.isAutoLocalized = false
        self.candidateStreak = 0
        self.localizationConfidence = 0.0
        self.lastCandidateWallId = nil
        self.targetDistanceMeters = nil
        
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isTracking = true
        trackingStatusText = "Point camera at room walls to localize..."
    }
    
    public func stop() {
        session.pause()
        isTracking = false
        currentPosition = nil
        currentHeading = nil
        targetDistanceMeters = nil
    }
    
    /// Trigger re-localization to re-acquire room position from scratch
    public func relocalize() {
        self.isAutoLocalized = false
        self.isCalibrated = false
        self.candidateStreak = 0
        self.localizationConfidence = 0.0
        self.lastCandidateWallId = nil
        self.trackingStatusText = "Relocalizing... Point at walls in front of you"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    // MARK: - ARSessionDelegate
    
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        let camTransform = frame.camera.transform
        
        // 1. Raw camera position in AR tracking coordinates
        let rawPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
        
        // 2. Camera looking direction in AR space
        // In ARKit camera local coordinates: -columns.2 is the forward direction into the real world
        let lookX = -camTransform.columns.2.x
        let lookZ = -camTransform.columns.2.z
        let forwardLen = sqrt(lookX * lookX + lookZ * lookZ)
        let normARForward = (forwardLen > 0.001) ? SIMD2<Float>(lookX / forwardLen, lookZ / forwardLen) : SIMD2<Float>(0, 1)
        
        // 3. Measure physical obstacle distance directly in front of camera
        let measuredFront = measureSurfaceInFront(frame: frame, camPos: rawPos)
        
        // 4. Perform Automatic Visual Localization every 4 frames until firmly locked
        if let room = self.room, !room.walls.isEmpty, (frameCount % 4 == 0) {
            evaluateAutoLocalization(room: room, rawPos: rawPos, arForward: normARForward, measured: measuredFront)
        }
        
        // 5. Apply Rigid SE(2) Transformation to Room Frame
        let cosA = cos(alignmentAngle)
        let sinA = sin(alignmentAngle)
        
        // Rotate raw position into room frame
        let rotX = rawPos.x * cosA - rawPos.z * sinA
        let rotZ = rawPos.x * sinA + rawPos.z * cosA
        let roomPos = SIMD3<Float>(rotX + alignmentOffset.x, rawPos.y, rotZ + alignmentOffset.z)
        
        // Rotate camera forward vector into room frame
        let roomLookX = normARForward.x * cosA - normARForward.y * sinA
        let roomLookZ = normARForward.x * sinA + normARForward.y * cosA
        
        // Heading on 2D Canvas: +X is right, +Z is down.
        // Screen heading angle is strictly atan2(roomLookZ, roomLookX)
        let screenHeading = atan2(roomLookZ, roomLookX)
        
        let dist = measuredFront?.distance
        
        DispatchQueue.main.async {
            self.currentPosition = roomPos
            self.currentHeading = screenHeading
            self.targetDistanceMeters = dist
        }
    }
    
    // MARK: - LiDAR & Raycast Surface Distance Measurement
    
    private struct SurfaceMeasurement {
        var distance: Float
        var normal: SIMD3<Float>?
    }
    
    private func measureSurfaceInFront(frame: ARFrame, camPos: SIMD3<Float>) -> SurfaceMeasurement? {
        let centerPoint = CGPoint(x: 0.5, y: 0.5)
        
        // Primary: ARKit Raycasting against estimated planes and mesh
        let query = frame.raycastQuery(from: centerPoint, allowing: .estimatedPlane, alignment: .any)
        let hits = session.raycast(query)
        if let hit = hits.first {
            let hitPos = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
            let d = simd_distance(camPos, hitPos)
            if d > 0.25 && d < 10.0 {
                let hitNorm = SIMD3<Float>(hit.worldTransform.columns.1.x, hit.worldTransform.columns.1.y, hit.worldTransform.columns.1.z)
                return SurfaceMeasurement(distance: d, normal: hitNorm)
            }
        }
        
        // Secondary / Fallback: Hardware LiDAR SceneDepth buffer
        if #available(iOS 14.0, *) {
            if let depthBuffer = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap {
                if let d = readCenterDepth(from: depthBuffer) {
                    return SurfaceMeasurement(distance: d, normal: nil)
                }
            }
        }
        
        return nil
    }
    
    private func readCenterDepth(from pixelBuffer: CVPixelBuffer) -> Float? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        
        let floatBuffer = base.assumingMemoryBound(to: Float32.self)
        let centerX = width / 2
        let centerY = height / 2
        let depth = floatBuffer[centerY * width + centerX]
        
        if depth > 0.25 && depth < 10.0 && !depth.isNaN {
            return depth
        }
        return nil
    }
    
    // MARK: - Automatic Visual & Geometric Room Relocalization Engine
    
    private func evaluateAutoLocalization(
        room: MaquetteRoom,
        rawPos: SIMD3<Float>,
        arForward: SIMD2<Float>,
        measured: SurfaceMeasurement?
    ) {
        guard let measured = measured else { return }
        let measuredDist = measured.distance
        guard measuredDist >= 0.4 && measuredDist <= 7.0 else { return }
        
        let bounds = room.boundingBox
        var bestCandidateWall: WallSurface? = nil
        var bestCandidateAngle: Float = 0.0
        var bestCandidateOffset = SIMD3<Float>.zero
        var lowestError: Float = .greatestFiniteMagnitude
        
        // Evaluate every wall in the known room model
        for wall in room.walls {
            let s = wall.startPoint2D
            let e = wall.endPoint2D
            let sx = Float(s.x); let sz = Float(s.y)
            let ex = Float(e.x); let ez = Float(e.y)
            let dx = ex - sx; let dz = ez - sz
            let len = sqrt(dx*dx + dz*dz)
            guard len > 0.4 else { continue }
            
            // Wall normal pointing into the room
            let wallNormal = SIMD2<Float>(-dz / len, dx / len)
            let wallCenter = SIMD2<Float>((sx + ex) / 2.0, (sz + ez) / 2.0)
            
            // When facing the wall from inside, camera forward direction opposes wall normal
            let targetForward = -wallNormal
            
            // Rotation angle mapping arForward to targetForward in room frame
            let targetAngle = atan2(targetForward.y, targetForward.x)
            let arAngle = atan2(arForward.y, arForward.x)
            let candidateYaw = targetAngle - arAngle
            
            // Rotate camera position by candidateYaw
            let cosYaw = cos(candidateYaw)
            let sinYaw = sin(candidateYaw)
            let rotCamX = rawPos.x * cosYaw - rawPos.z * sinYaw
            let rotCamZ = rawPos.x * sinYaw + rawPos.z * cosYaw
            
            // Expected camera position in room frame at measured distance from this wall center
            let expectedCamX = wallCenter.x - measuredDist * targetForward.x
            let expectedCamZ = wallCenter.y - measuredDist * targetForward.y
            
            // Offset translation to place camera at expectedCam
            let candOffsetX = expectedCamX - rotCamX
            let candOffsetZ = expectedCamZ - rotCamZ
            let candCam = SIMD3<Float>(expectedCamX, rawPos.y, expectedCamZ)
            
            // Validation 1: Camera must be inside the room bounds (with 0.6m padding)
            let pad: Float = 0.6
            guard candCam.x >= bounds.min.x - pad && candCam.x <= bounds.max.x + pad &&
                  candCam.z >= bounds.min.z - pad && candCam.z <= bounds.max.z + pad else {
                continue
            }
            
            // Validation 2: Ray from camera along targetForward must intersect the wall segment
            let rayOrigin = SIMD2<Float>(candCam.x, candCam.z)
            if let hitDist = raySegmentIntersection(origin: rayOrigin, dir: targetForward, a: SIMD2<Float>(sx, sz), b: SIMD2<Float>(ex, ez)) {
                let distError = abs(hitDist - measuredDist)
                if distError < lowestError && distError < 0.65 {
                    lowestError = distError
                    bestCandidateWall = wall
                    bestCandidateAngle = candidateYaw
                    bestCandidateOffset = SIMD3<Float>(candOffsetX, 0, candOffsetZ)
                }
            }
        }
        
        // Process candidate match
        if let wall = bestCandidateWall, lowestError < 0.50 {
            if lastCandidateWallId == wall.id {
                candidateStreak += 1
            } else {
                lastCandidateWallId = wall.id
                candidateStreak = 1
            }
            
            let confidence = min(Float(candidateStreak) / 5.0, 1.0)
            
            // If consistent for 4+ consecutive evaluations (~0.4s), LOCK localization!
            if candidateStreak >= 4 {
                if !isAutoLocalized {
                    // Snap lock on first acquisition with haptic feedback
                    self.alignmentAngle = bestCandidateAngle
                    self.alignmentOffset = bestCandidateOffset
                    self.isCalibrated = true
                    self.isAutoLocalized = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    // Smooth subtle drift damping (EMA filter)
                    let alpha: Float = 0.20
                    self.alignmentAngle = self.alignmentAngle * (1.0 - alpha) + bestCandidateAngle * alpha
                    self.alignmentOffset = self.alignmentOffset * (1.0 - alpha) + bestCandidateOffset * alpha
                }
                
                let wallName = wall.displayName
                DispatchQueue.main.async {
                    self.localizedTargetName = wallName
                    self.localizationConfidence = confidence
                    self.trackingStatusText = "✓ Localized: Facing \(wallName) (\(String(format: "%.1fm", measuredDist)))"
                }
            } else {
                DispatchQueue.main.async {
                    self.localizationConfidence = confidence * 0.7
                    self.trackingStatusText = "Recognizing \(wall.displayName)... (\(Int(confidence * 100))%)"
                }
            }
        } else {
            // Decay candidate streak when looking away into open space
            candidateStreak = max(candidateStreak - 1, 0)
        }
    }
    
    private func raySegmentIntersection(origin: SIMD2<Float>, dir: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> Float? {
        let v1 = origin - a
        let v2 = b - a
        let v3 = SIMD2<Float>(-dir.y, dir.x)
        
        let dot = simd_dot(v2, v3)
        guard abs(dot) > 1e-6 else { return nil }
        
        let t1 = (v2.x * v1.y - v2.y * v1.x) / dot
        let t2 = simd_dot(v1, v3) / dot
        
        if t1 > 0.2 && t2 >= -0.15 && t2 <= 1.15 {
            return t1
        }
        return nil
    }
    
    // MARK: - Tracking State Handlers
    
    public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        DispatchQueue.main.async {
            switch camera.trackingState {
            case .normal:
                if !self.isAutoLocalized {
                    self.trackingStatusText = "LiDAR Active: Point at room walls to locate..."
                }
            case .notAvailable:
                self.trackingStatusText = "Tracking Unavailable"
            case .limited(let reason):
                switch reason {
                case .initializing:
                    self.trackingStatusText = "Initializing LiDAR..."
                case .excessiveMotion:
                    self.trackingStatusText = "Slow Down Device Motion"
                case .insufficientFeatures:
                    self.trackingStatusText = "Point at walls or floor"
                case .relocalizing:
                    self.trackingStatusText = "Relocalizing..."
                @unknown default:
                    self.trackingStatusText = "Tracking Limited"
                }
            }
        }
    }
    
    public func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.trackingStatusText = "AR Error: \(error.localizedDescription)"
        }
    }
}
