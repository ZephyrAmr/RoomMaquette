import Foundation
import ARKit
import Combine
import SwiftUI
import CoreVideo
import simd

public struct ReferenceWallTarget: Identifiable {
    public var id = UUID()
    public var start: SIMD2<Float>
    public var end: SIMD2<Float>
    public var normal: SIMD2<Float>
    public var displayName: String
    
    public var length: Float {
        simd_distance(start, end)
    }
    
    public var center: SIMD2<Float> {
        (start + end) / 2.0
    }
}

public struct ObservedWallSurface {
    public var normal: SIMD2<Float>      // Normal vector in AR tracking coordinates
    public var position: SIMD2<Float>    // Surface position in AR tracking coordinates
    public var distance: Float           // Measured distance from camera
    public var timestamp: TimeInterval
}

public class ARIndoorPositionTracker: NSObject, ObservableObject, ARSessionDelegate {
    @Published public var currentPosition: SIMD3<Float>? = nil
    @Published public var currentHeading: Float? = nil // radians on 2D canvas (0 = +X, pi/2 = +Z)
    @Published public var isTracking: Bool = false
    @Published public var trackingStatusText: String = "Scanning room to locate..."
    @Published public var isCalibrated: Bool = false
    @Published public var isAutoLocalized: Bool = false
    @Published public var isLocatingOnImportedPlan: Bool = false
    @Published public var localizedTargetName: String? = nil
    @Published public var targetDistanceMeters: Float? = nil
    @Published public var localizationConfidence: Float = 0.0
    
    public var session: ARSession
    public var room: MaquetteRoom?
    
    // Rigid SE(2) Transformation parameters from AR coordinate space to Room / Plan coordinate space:
    // targetPos.x = rawPos.x * cos(alignmentAngle) - rawPos.z * sin(alignmentAngle) + alignmentOffset.x
    // targetPos.z = rawPos.x * sin(alignmentAngle) + rawPos.z * cos(alignmentAngle) + alignmentOffset.z
    private var alignmentAngle: Float = 0.0
    private var alignmentOffset: SIMD3<Float> = .zero
    private var alignmentScale: Float = 1.0
    
    // Multi-wall observations accumulator
    private var observedWalls: [ObservedWallSurface] = []
    private var verticalPlaneAnchors: [UUID: ARPlaneAnchor] = [:]
    
    // Auto-localization temporal hypothesis tracking
    private var candidateStreak: Int = 0
    private var lastCandidateTargetId: UUID? = nil
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
        let hasImportedPlan = room?.importedPlan != nil && !(room?.importedPlan?.vectorLines.isEmpty ?? true)
        self.isLocatingOnImportedPlan = hasImportedPlan
        
        if let r = room {
            if hasImportedPlan {
                self.alignmentOffset = .zero
            } else {
                let bounds = r.boundingBox
                let center = (bounds.min + bounds.max) / 2.0
                self.alignmentOffset = SIMD3<Float>(center.x, 0, center.z)
            }
        } else {
            self.alignmentOffset = .zero
        }
        
        self.alignmentAngle = 0.0
        self.alignmentScale = 1.0
        self.isCalibrated = false
        self.isAutoLocalized = false
        self.candidateStreak = 0
        self.localizationConfidence = 0.0
        self.lastCandidateTargetId = nil
        self.targetDistanceMeters = nil
        self.observedWalls.removeAll()
        self.verticalPlaneAnchors.removeAll()
        
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isTracking = true
        trackingStatusText = hasImportedPlan ? "Look around room to locate on imported plan..." : "Point camera at room walls to localize..."
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
        self.lastCandidateTargetId = nil
        self.observedWalls.removeAll()
        self.trackingStatusText = "Relocalizing... Look around at the walls"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    // MARK: - ARSessionDelegate
    
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        let camTransform = frame.camera.transform
        
        // 1. Raw camera position in AR tracking coordinates
        let rawPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
        
        // 2. Camera looking direction in AR space
        let lookX = -camTransform.columns.2.x
        let lookZ = -camTransform.columns.2.z
        let forwardLen = sqrt(lookX * lookX + lookZ * lookZ)
        let normARForward = (forwardLen > 0.001) ? SIMD2<Float>(lookX / forwardLen, lookZ / forwardLen) : SIMD2<Float>(0, 1)
        
        // 3. Measure physical obstacle distance directly in front of camera
        let measuredFront = measureSurfaceInFront(frame: frame, camPos: rawPos)
        
        // 4. Record observed surface in AR world space
        if let measured = measuredFront, measured.distance >= 0.4 && measured.distance <= 7.0 {
            recordObservedSurface(camPos: rawPos, forward: normARForward, dist: measured.distance)
        }
        
        // 5. Perform Automatic Multi-Wall Localization every 3 frames until firmly locked
        if let room = self.room, (frameCount % 3 == 0) {
            let targets = getReferenceTargets(for: room)
            if !targets.isEmpty {
                evaluateMultiWallLocalization(
                    targets: targets,
                    rawPos: rawPos,
                    arForward: normARForward,
                    measured: measuredFront
                )
            }
        }
        
        // 6. Apply Rigid SE(2) Transformation to Room / Plan Frame
        let cosA = cos(alignmentAngle)
        let sinA = sin(alignmentAngle)
        
        // Rotate and scale raw position into target coordinate frame
        let rotX = (rawPos.x * cosA - rawPos.z * sinA) * alignmentScale
        let rotZ = (rawPos.x * sinA + rawPos.z * cosA) * alignmentScale
        let transformedPos = SIMD3<Float>(rotX + alignmentOffset.x, rawPos.y, rotZ + alignmentOffset.z)
        
        // Rotate camera forward vector into target coordinate frame
        let roomLookX = normARForward.x * cosA - normARForward.y * sinA
        let roomLookZ = normARForward.x * sinA + normARForward.y * cosA
        
        // Heading on 2D Canvas: +X is right, +Z is down -> atan2(roomLookZ, roomLookX)
        let screenHeading = atan2(roomLookZ, roomLookX)
        
        let dist = measuredFront?.distance
        
        DispatchQueue.main.async {
            self.currentPosition = transformedPos
            self.currentHeading = screenHeading
            self.targetDistanceMeters = dist
        }
    }
    
    // MARK: - Plane Anchor Callbacks
    
    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            if let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical {
                verticalPlaneAnchors[plane.identifier] = plane
            }
        }
    }
    
    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            if let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical {
                verticalPlaneAnchors[plane.identifier] = plane
            }
        }
    }
    
    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            verticalPlaneAnchors.removeValue(forKey: anchor.identifier)
        }
    }
    
    // MARK: - Surface Accumulator
    
    private func recordObservedSurface(camPos: SIMD3<Float>, forward: SIMD2<Float>, dist: Float) {
        let surfX = camPos.x + forward.x * dist
        let surfZ = camPos.z + forward.y * dist
        let surfPos = SIMD2<Float>(surfX, surfZ)
        let wallNormal = -forward
        let now = Date().timeIntervalSince1970
        
        // Check if this surface is already observed
        for i in 0..<observedWalls.count {
            let existing = observedWalls[i]
            if simd_distance(existing.position, surfPos) < 0.6 {
                // Update existing observation
                observedWalls[i] = ObservedWallSurface(normal: wallNormal, position: surfPos, distance: dist, timestamp: now)
                return
            }
        }
        
        // Add new observed wall surface
        observedWalls.append(ObservedWallSurface(normal: wallNormal, position: surfPos, distance: dist, timestamp: now))
        if observedWalls.count > 12 {
            observedWalls.removeFirst()
        }
    }
    
    // MARK: - Reference Targets Builder
    
    private func getReferenceTargets(for room: MaquetteRoom) -> [ReferenceWallTarget] {
        var targets: [ReferenceWallTarget] = []
        
        // Priority 1: If an imported plan is present, use its vector lines directly
        if let plan = room.importedPlan, !plan.vectorLines.isEmpty {
            for (idx, line) in plan.vectorLines.enumerated() {
                let p1 = SIMD2<Float>(line.startX, line.startZ)
                let p2 = SIMD2<Float>(line.endX, line.endZ)
                let dx = p2.x - p1.x
                let dz = p2.y - p1.y
                let len = sqrt(dx*dx + dz*dz)
                guard len >= 0.4 else { continue }
                let norm = SIMD2<Float>(-dz / len, dx / len)
                targets.append(ReferenceWallTarget(
                    start: p1,
                    end: p2,
                    normal: norm,
                    displayName: "Plan Wall #\(idx + 1)"
                ))
            }
            if !targets.isEmpty { return targets }
        }
        
        // Priority 2: Use room.walls
        for wall in room.walls {
            let s = wall.startPoint2D
            let e = wall.endPoint2D
            let p1 = SIMD2<Float>(Float(s.x), Float(s.y))
            let p2 = SIMD2<Float>(Float(e.x), Float(e.y))
            let dx = p2.x - p1.x
            let dz = p2.y - p1.y
            let len = sqrt(dx*dx + dz*dz)
            guard len >= 0.4 else { continue }
            let norm = SIMD2<Float>(-dz / len, dx / len)
            targets.append(ReferenceWallTarget(
                start: p1,
                end: p2,
                normal: norm,
                displayName: wall.displayName
            ))
        }
        
        return targets
    }
    
    // MARK: - Automatic Multi-Wall Localization Engine
    
    private func evaluateMultiWallLocalization(
        targets: [ReferenceWallTarget],
        rawPos: SIMD3<Float>,
        arForward: SIMD2<Float>,
        measured: SurfaceMeasurement?
    ) {
        guard let measured = measured else { return }
        let measuredDist = measured.distance
        guard measuredDist >= 0.4 && measuredDist <= 7.0 else { return }
        
        var bestCandidateTarget: ReferenceWallTarget? = nil
        var bestCandidateAngle: Float = 0.0
        var bestCandidateOffset = SIMD3<Float>.zero
        var highestScore: Float = -1.0
        
        // Primary candidate loop over reference targets
        for target in targets {
            let targetForward = -target.normal
            let targetAngle = atan2(targetForward.y, targetForward.x)
            let arAngle = atan2(arForward.y, arForward.x)
            let candidateYaw = targetAngle - arAngle
            
            let cosYaw = cos(candidateYaw)
            let sinYaw = sin(candidateYaw)
            let rotCamX = rawPos.x * cosYaw - rawPos.z * sinYaw
            let rotCamZ = rawPos.x * sinYaw + rawPos.z * cosYaw
            
            let expectedCamX = target.center.x - measuredDist * targetForward.x
            let expectedCamZ = target.center.y - measuredDist * targetForward.y
            
            let candOffsetX = expectedCamX - rotCamX
            let candOffsetZ = expectedCamZ - rotCamZ
            let candCam = SIMD2<Float>(expectedCamX, expectedCamZ)
            
            // Check ray intersection with this primary wall
            guard let hitDist = raySegmentIntersection(origin: candCam, dir: targetForward, a: target.start, b: target.end) else {
                continue
            }
            let distErr = abs(hitDist - measuredDist)
            guard distErr < 0.65 else { continue }
            
            var matchScore: Float = max(0, 1.0 - (distErr / 0.65))
            
            // Multi-wall verification: Test other accumulated observed walls against other reference walls
            for obs in observedWalls {
                // Rotate observed wall normal and position by candidate transform
                let obsRotNormX = obs.normal.x * cosYaw - obs.normal.y * sinYaw
                let obsRotNormZ = obs.normal.x * sinYaw + obs.normal.y * cosYaw
                let obsRotNorm = SIMD2<Float>(obsRotNormX, obsRotNormZ)
                
                let obsRotPosX = (obs.position.x * cosYaw - obs.position.y * sinYaw) + candOffsetX
                let obsRotPosZ = (obs.position.x * sinYaw + obs.position.y * cosYaw) + candOffsetZ
                let obsWorldPos = SIMD2<Float>(obsRotPosX, obsRotPosZ)
                
                for otherTarget in targets where otherTarget.id != target.id {
                    // Check normal alignment (parallel or perpendicular)
                    let dotNorm = simd_dot(obsRotNorm, otherTarget.normal)
                    if dotNorm > 0.85 { // Co-oriented wall
                        let distToWall = pointToSegmentDistance(p: obsWorldPos, a: otherTarget.start, b: otherTarget.end)
                        if distToWall < 0.45 {
                            matchScore += 2.5 // Confirmed co-oriented wall
                        }
                    } else if abs(dotNorm) < 0.25 { // Perpendicular wall (L-corner junction!)
                        let distToWall = pointToSegmentDistance(p: obsWorldPos, a: otherTarget.start, b: otherTarget.end)
                        if distToWall < 0.45 {
                            matchScore += 5.0 // Rock-solid 90° corner lock!
                        }
                    }
                }
            }
            
            if matchScore > highestScore {
                highestScore = matchScore
                bestCandidateTarget = target
                bestCandidateAngle = candidateYaw
                bestCandidateOffset = SIMD3<Float>(candOffsetX, 0, candOffsetZ)
            }
        }
        
        // Process candidate match score
        if let target = bestCandidateTarget, highestScore > 0.5 {
            if lastCandidateTargetId == target.id {
                // If multi-wall agreement is detected (score >= 3.0), advance streak much faster!
                candidateStreak += (highestScore >= 3.0) ? 2 : 1
            } else {
                lastCandidateTargetId = target.id
                candidateStreak = (highestScore >= 3.0) ? 2 : 1
            }
            
            let confidence = min(Float(candidateStreak) / 4.0, 1.0)
            
            // Lock localization once streak reaches threshold
            if candidateStreak >= 3 {
                if !isAutoLocalized {
                    self.alignmentAngle = bestCandidateAngle
                    self.alignmentOffset = bestCandidateOffset
                    self.isCalibrated = true
                    self.isAutoLocalized = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    // Smooth subtle damping
                    let alpha: Float = 0.25
                    self.alignmentAngle = self.alignmentAngle * (1.0 - alpha) + bestCandidateAngle * alpha
                    self.alignmentOffset = self.alignmentOffset * (1.0 - alpha) + bestCandidateOffset * alpha
                }
                
                let targetName = target.displayName
                let planPrefix = isLocatingOnImportedPlan ? "Plan" : "Room"
                DispatchQueue.main.async {
                    self.localizedTargetName = targetName
                    self.localizationConfidence = confidence
                    self.trackingStatusText = "✓ Localized on \(planPrefix): Facing \(targetName) (\(String(format: "%.1fm", measuredDist)))"
                }
            } else {
                DispatchQueue.main.async {
                    self.localizationConfidence = confidence * 0.7
                    self.trackingStatusText = "Scanning walls... (\(Int(confidence * 100))%)"
                }
            }
        } else {
            candidateStreak = max(candidateStreak - 1, 0)
        }
    }
    
    // MARK: - LiDAR & Raycast Surface Distance Measurement
    
    private struct SurfaceMeasurement {
        var distance: Float
        var normal: SIMD3<Float>?
    }
    
    private func measureSurfaceInFront(frame: ARFrame, camPos: SIMD3<Float>) -> SurfaceMeasurement? {
        let centerPoint = CGPoint(x: 0.5, y: 0.5)
        
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
    
    // MARK: - Geometry Helpers
    
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
    
    private func pointToSegmentDistance(p: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lenSq = simd_length_squared(ab)
        if lenSq < 1e-6 { return simd_distance(p, a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / lenSq))
        let proj = a + t * ab
        return simd_distance(p, proj)
    }
    
    // MARK: - Tracking State Handlers
    
    public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        DispatchQueue.main.async {
            switch camera.trackingState {
            case .normal:
                if !self.isAutoLocalized {
                    self.trackingStatusText = self.isLocatingOnImportedPlan ? "Look around room to locate on imported plan..." : "LiDAR Active: Point at room walls to locate..."
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
