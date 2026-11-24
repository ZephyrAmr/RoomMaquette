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
    public var tangent: SIMD2<Float>
    public var normal: SIMD2<Float>   // Canonical unit normal
    public var offset: Float          // dot(start, normal)
    public var angle: Float           // atan2(normal.y, normal.x)
    public var displayName: String
    
    public var length: Float {
        simd_distance(start, end)
    }
    
    public var center: SIMD2<Float> {
        (start + end) * 0.5
    }
}

public struct ObservedWallPoint {
    public var pos: SIMD2<Float>      // AR world XZ coordinate
    public var normal: SIMD2<Float>   // Outward wall normal (pointing toward camera / interior)
    public var weight: Float
    public var timestamp: TimeInterval
}

public class ARIndoorPositionTracker: NSObject, ObservableObject, ARSessionDelegate {
    @Published public var currentPosition: SIMD3<Float>? = nil
    @Published public var currentHeading: Float? = nil // radians on 2D canvas (0 = +X, pi/2 = +Z)
    @Published public var isTracking: Bool = false
    @Published public var trackingStatusText: String = "Point camera at a wall, then pan to a corner..."
    @Published public var isCalibrated: Bool = false
    @Published public var isAutoLocalized: Bool = false
    @Published public var isLocatingOnImportedPlan: Bool = false
    @Published public var localizedTargetName: String? = nil
    @Published public var targetDistanceMeters: Float? = nil
    @Published public var localizationConfidence: Float = 0.0
    @Published public var observedWallCount: Int = 0
    
    public var session: ARSession
    public var room: MaquetteRoom?
    
    // Rigid SE(2) Transform: AR space -> Reference space (Room or Imported Plan)
    private var alignmentAngle: Float = 0.0
    private var alignmentOffset: SIMD3<Float> = .zero
    private let transformLock = NSLock()
    
    // Reference wall segments built once on start
    private var referenceTargets: [ReferenceWallTarget] = []
    private var refMinBounds = SIMD2<Float>(-5, -5)
    private var refMaxBounds = SIMD2<Float>(5, 5)
    
    // Live physical observations in AR coordinates
    private var verticalPlaneAnchors: [UUID: ARPlaneAnchor] = [:]
    private var observedRayPoints: [ObservedWallPoint] = []
    private var frameCount: Int = 0
    
    // Background solver state
    private let solverQueue = DispatchQueue(label: "com.roommaquette.localization", qos: .userInitiated)
    private var isSolving: Bool = false
    private var lastSolveTime: TimeInterval = 0
    private var consistentCandidateCount: Int = 0
    private var lastBestCandidate: (angle: Float, tx: Float, tz: Float)? = nil
    
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
        config.planeDetection = [.vertical]
        
        // Determine whether we are localizing directly on an imported plan or a scanned room
        let hasImportedPlan = room?.importedPlan != nil && !(room?.importedPlan?.vectorLines.isEmpty ?? true)
        let isPlanOnlyRoom = (room?.walls.isEmpty ?? true) || (room?.notes.hasPrefix("Created from imported plan:") ?? false)
        self.isLocatingOnImportedPlan = hasImportedPlan && isPlanOnlyRoom
        
        if let r = room {
            self.referenceTargets = buildReferenceTargets(for: r, usePlanSpace: self.isLocatingOnImportedPlan)
            computeReferenceBounds()
        } else {
            self.referenceTargets = []
        }
        
        let refCenter = (refMinBounds + refMaxBounds) * 0.5
        
        transformLock.lock()
        self.alignmentAngle = 0.0
        self.alignmentOffset = SIMD3<Float>(refCenter.x, 0, refCenter.y)
        transformLock.unlock()
        
        self.isCalibrated = false
        self.isAutoLocalized = false
        self.localizationConfidence = 0.0
        self.consistentCandidateCount = 0
        self.lastBestCandidate = nil
        self.localizedTargetName = nil
        self.targetDistanceMeters = nil
        self.observedWallCount = 0
        self.observedRayPoints.removeAll()
        self.verticalPlaneAnchors.removeAll()
        self.lastSolveTime = 0
        self.isSolving = false
        
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isTracking = true
        trackingStatusText = isLocatingOnImportedPlan
            ? "Scan 2 walls or a corner to locate on plan..."
            : "Scan 2 walls or a corner to auto-locate..."
    }
    
    public func stop() {
        session.pause()
        isTracking = false
        currentPosition = nil
        currentHeading = nil
        targetDistanceMeters = nil
    }
    
    public func relocalize() {
        self.isAutoLocalized = false
        self.isCalibrated = false
        self.consistentCandidateCount = 0
        self.lastBestCandidate = nil
        self.localizationConfidence = 0.0
        self.observedWallCount = 0
        self.observedRayPoints.removeAll()
        self.trackingStatusText = "Relocalizing... Look at 2 walls or a corner"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    // MARK: - ARSessionDelegate
    
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        let camTransform = frame.camera.transform
        let rawPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
        
        // Camera optical axis in AR space (-columns.2)
        let lookX = -camTransform.columns.2.x
        let lookZ = -camTransform.columns.2.z
        let forwardLen = hypot(lookX, lookZ)
        let normARForward = (forwardLen > 0.001) ? SIMD2<Float>(lookX / forwardLen, lookZ / forwardLen) : SIMD2<Float>(0, 1)
        
        // 1. Live center LiDAR/vertical distance for crosshair HUD
        if frameCount % 2 == 0 {
            let frontDist = measureCenterWallOrDepthDistance(frame: frame, camPos: rawPos)
            DispatchQueue.main.async {
                self.targetDistanceMeters = frontDist
            }
        }
        
        // 2. While not yet locked, sample vertical wall rays across horizontal scan band
        if !isAutoLocalized && (frameCount % 4 == 0) {
            sampleHorizontalVerticalWallFan(frame: frame, camPos: rawPos)
        }
        
        // 3. Trigger rigid SE(2) solver every ~0.35s until locked
        let now = Date().timeIntervalSince1970
        if !isAutoLocalized && !isSolving && !referenceTargets.isEmpty && (now - lastSolveTime) > 0.35 {
            lastSolveTime = now
            triggerLocalizationSolve(camPosAR: SIMD2<Float>(rawPos.x, rawPos.z), arForward: normARForward)
        }
        
        // 4. Transform live AR pose into Reference frame cleanly (60 FPS, never mutated mid-turn once locked)
        transformLock.lock()
        let yaw = alignmentAngle
        let offset = alignmentOffset
        transformLock.unlock()
        
        let cosA = cos(yaw)
        let sinA = sin(yaw)
        
        let rotX = rawPos.x * cosA - rawPos.z * sinA
        let rotZ = rawPos.x * sinA + rawPos.z * cosA
        let transformedPos = SIMD3<Float>(rotX + offset.x, rawPos.y, rotZ + offset.z)
        
        let roomLookX = normARForward.x * cosA - normARForward.y * sinA
        let roomLookZ = normARForward.x * sinA + normARForward.y * cosA
        let screenHeading = atan2(roomLookZ, roomLookX)
        
        DispatchQueue.main.async {
            self.currentPosition = transformedPos
            self.currentHeading = screenHeading
        }
    }
    
    // MARK: - Vertical Plane Anchor Tracking
    
    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        var changed = false
        for anchor in anchors {
            if let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical {
                verticalPlaneAnchors[plane.identifier] = plane
                changed = true
            }
        }
        if changed { updateObservedWallCount() }
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
    
    private func updateObservedWallCount() {
        let count = verticalPlaneAnchors.count
        DispatchQueue.main.async {
            self.observedWallCount = max(self.observedWallCount, count)
        }
    }
    
    // MARK: - Reference Wall Map Builder
    
    private func buildReferenceTargets(for room: MaquetteRoom, usePlanSpace: Bool) -> [ReferenceWallTarget] {
        var targets: [ReferenceWallTarget] = []
        
        if usePlanSpace, let plan = room.importedPlan, !plan.vectorLines.isEmpty {
            for (idx, line) in plan.vectorLines.enumerated() {
                let p1 = SIMD2<Float>(line.startX, line.startZ)
                let p2 = SIMD2<Float>(line.endX, line.endZ)
                if let t = makeReferenceTarget(p1: p1, p2: p2, name: "Plan Wall #\(idx + 1)") {
                    targets.append(t)
                }
            }
            if !targets.isEmpty { return targets }
        }
        
        for (idx, wall) in room.walls.enumerated() {
            let s = wall.startPoint2D
            let e = wall.endPoint2D
            let p1 = SIMD2<Float>(Float(s.x), Float(s.y))
            let p2 = SIMD2<Float>(Float(e.x), Float(e.y))
            if let t = makeReferenceTarget(p1: p1, p2: p2, name: "\(wall.displayName) #\(idx + 1)") {
                targets.append(t)
            }
        }
        
        return targets
    }
    
    private func makeReferenceTarget(p1: SIMD2<Float>, p2: SIMD2<Float>, name: String) -> ReferenceWallTarget? {
        let diff = p2 - p1
        let len = simd_length(diff)
        guard len >= 0.35 else { return nil }
        let tangent = diff / len
        let normal = SIMD2<Float>(-tangent.y, tangent.x)
        let offset = simd_dot(p1, normal)
        let angle = atan2(normal.y, normal.x)
        return ReferenceWallTarget(
            start: p1,
            end: p2,
            tangent: tangent,
            normal: normal,
            offset: offset,
            angle: angle,
            displayName: name
        )
    }
    
    private func computeReferenceBounds() {
        guard !referenceTargets.isEmpty else {
            refMinBounds = SIMD2<Float>(-5, -5)
            refMaxBounds = SIMD2<Float>(5, 5)
            return
        }
        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        var minZ: Float = .greatestFiniteMagnitude
        var maxZ: Float = -.greatestFiniteMagnitude
        for t in referenceTargets {
            minX = min(minX, t.start.x, t.end.x)
            maxX = max(maxX, t.start.x, t.end.x)
            minZ = min(minZ, t.start.y, t.end.y)
            maxZ = max(maxZ, t.start.y, t.end.y)
        }
        refMinBounds = SIMD2<Float>(minX, minZ)
        refMaxBounds = SIMD2<Float>(maxX, maxZ)
    }
    
    // MARK: - Vertical Wall Ray Sampling
    
    private func sampleHorizontalVerticalWallFan(frame: ARFrame, camPos: SIMD3<Float>) {
        let camXZ = SIMD2<Float>(camPos.x, camPos.z)
        let sampleX: [CGFloat] = [0.22, 0.36, 0.50, 0.64, 0.78]
        let now = Date().timeIntervalSince1970
        
        for sx in sampleX {
            let query = frame.raycastQuery(from: CGPoint(x: sx, y: 0.50), allowing: .estimatedPlane, alignment: .vertical)
            let hits = session.raycast(query)
            guard let hit = hits.first else { continue }
            
            let col1 = hit.worldTransform.columns.1
            // Strictly reject non-vertical hits (floors, desks, slanted clutter)
            guard abs(col1.y) < 0.35 else { continue }
            
            let hp3 = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
            let dist = simd_distance(camPos, hp3)
            guard dist >= 0.35 && dist <= 8.5 else { continue }
            
            var norm2 = SIMD2<Float>(col1.x, col1.z)
            let nLen = simd_length(norm2)
            guard nLen > 0.2 else { continue }
            norm2 /= nLen
            
            let hitXZ = SIMD2<Float>(hp3.x, hp3.z)
            // Orient normal toward camera so we know which side of the wall we're observing from
            if simd_dot(norm2, camXZ - hitXZ) < 0 {
                norm2 = -norm2
            }
            
            addObservedRayPoint(ObservedWallPoint(pos: hitXZ, normal: norm2, weight: 1.0, timestamp: now))
        }
    }
    
    private func addObservedRayPoint(_ pt: ObservedWallPoint) {
        for i in 0..<observedRayPoints.count {
            if simd_distance(observedRayPoints[i].pos, pt.pos) < 0.22 &&
               simd_dot(observedRayPoints[i].normal, pt.normal) > 0.85 {
                observedRayPoints[i] = pt
                return
            }
        }
        observedRayPoints.append(pt)
        if observedRayPoints.count > 75 {
            observedRayPoints.removeFirst()
        }
    }
    
    // MARK: - Rigid SE(2) Multi-Wall Localization Solver
    
    private func triggerLocalizationSolve(camPosAR: SIMD2<Float>, arForward: SIMD2<Float>) {
        isSolving = true
        
        // Snapshot vertical planes into value types on delegate thread before dispatching
        let planeSnapshots: [(transform: simd_float4x4, width: Float)] = verticalPlaneAnchors.values.map { plane in
            let w: Float
            if #available(iOS 16.0, *) {
                w = max(plane.planeExtent.width, 0.35)
            } else {
                w = max(plane.extent.x, 0.35)
            }
            return (transform: plane.transform, width: w)
        }
        let rayPointsSnapshot = observedRayPoints
        let targets = referenceTargets
        let minB = refMinBounds
        let maxB = refMaxBounds
        let isPlanMode = isLocatingOnImportedPlan
        
        solverQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async {
                    self.isSolving = false
                }
            }
            
            // 1. Build combined weighted observed wall point cloud in AR space
            var obsPoints: [ObservedWallPoint] = []
            let now = Date().timeIntervalSince1970
            
            for plane in planeSnapshots {
                let wt = plane.transform
                let c = SIMD2<Float>(wt.columns.3.x, wt.columns.3.z)
                let col1 = SIMD2<Float>(wt.columns.1.x, wt.columns.1.z)
                let nLen = simd_length(col1)
                guard nLen > 0.2 else { continue }
                var norm = col1 / nLen
                if simd_dot(norm, camPosAR - c) < 0 { norm = -norm }
                
                var tangent = SIMD2<Float>(wt.columns.0.x, wt.columns.0.z)
                let tLen = simd_length(tangent)
                if tLen > 0.2 {
                    tangent /= tLen
                } else {
                    tangent = SIMD2<Float>(-norm.y, norm.x)
                }
                
                let width = plane.width
                let steps = max(Int(width / 0.35), 2)
                for s in 0...steps {
                    let frac = Float(s) / Float(steps) - 0.5
                    let samplePos = c + tangent * (frac * width)
                    obsPoints.append(ObservedWallPoint(pos: samplePos, normal: norm, weight: 2.0, timestamp: now))
                }
            }
            
            // Append non-duplicate raycast wall hits
            obsPoints.append(contentsOf: rayPointsSnapshot)
            
            guard obsPoints.count >= 4 else {
                DispatchQueue.main.async {
                    self.trackingStatusText = "Point camera at a wall, then pan slowly..."
                }
                return
            }
            
            // 2. Cluster observed points into dominant wall lines (normal + offset)
            struct ObsWallCluster {
                var normal: SIMD2<Float>
                var center: SIMD2<Float>
                var offset: Float
                var totalWeight: Float
            }
            
            var obsClusters: [ObsWallCluster] = []
            for p in obsPoints {
                let d = simd_dot(p.pos, p.normal)
                var merged = false
                for idx in 0..<obsClusters.count {
                    if simd_dot(obsClusters[idx].normal, p.normal) > 0.88 && abs(obsClusters[idx].offset - d) < 0.45 {
                        let wSum = obsClusters[idx].totalWeight + p.weight
                        obsClusters[idx].center = (obsClusters[idx].center * obsClusters[idx].totalWeight + p.pos * p.weight) / wSum
                        obsClusters[idx].normal = simd_normalize(obsClusters[idx].normal * obsClusters[idx].totalWeight + p.normal * p.weight)
                        obsClusters[idx].offset = simd_dot(obsClusters[idx].center, obsClusters[idx].normal)
                        obsClusters[idx].totalWeight = wSum
                        merged = true
                        break
                    }
                }
                if !merged {
                    obsClusters.append(ObsWallCluster(normal: p.normal, center: p.pos, offset: d, totalWeight: p.weight))
                }
            }
            
            obsClusters.sort { $0.totalWeight > $1.totalWeight }
            let topClusters = Array(obsClusters.prefix(5))
            
            // Check if two non-parallel walls (a genuine corner ~45°-135°) have been observed
            var hasCornerOrMultiOrientation = false
            if topClusters.count >= 2 {
                for i in 0..<topClusters.count {
                    for j in (i + 1)..<topClusters.count {
                        if abs(simd_dot(topClusters[i].normal, topClusters[j].normal)) < 0.72 {
                            hasCornerOrMultiOrientation = true
                            break
                        }
                    }
                    if hasCornerOrMultiOrientation { break }
                }
            }
            
            DispatchQueue.main.async {
                self.observedWallCount = max(topClusters.count, planeSnapshots.count)
            }
            
            guard !topClusters.isEmpty else { return }
            
            // 3. Generate candidate yaw rotations aligning observed wall normals to reference wall normals
            var refNormals: [SIMD2<Float>] = []
            for t in targets {
                refNormals.append(t.normal)
                refNormals.append(-t.normal) // Two-sided walls!
            }
            
            var candidateYaws: [Float] = []
            let anchorNorm = topClusters[0].normal
            let obsAng = atan2(anchorNorm.y, anchorNorm.x)
            for rn in refNormals {
                let refAng = atan2(rn.y, rn.x)
                let yaw = Self.normalizeAngle(refAng - obsAng)
                if !candidateYaws.contains(where: { abs(Self.normalizeAngle($0 - yaw)) < (6.0 * .pi / 180.0) }) {
                    candidateYaws.append(yaw)
                }
            }
            
            // 4. Evaluate rigid transforms (yaw, tx, tz) using 2-wall intersection + parallel fallback
            var bestScore: Float = -1.0
            var bestInlierRatio: Float = 0.0
            var bestYaw: Float = 0.0
            var bestTx: Float = 0.0
            var bestTz: Float = 0.0
            var bestFacingName: String? = nil
            
            let totalWeight = obsPoints.reduce(Float(0)) { $0 + $1.weight }
            
            for yaw in candidateYaws {
                let cosY = cos(yaw)
                let sinY = sin(yaw)
                func rot(_ v: SIMD2<Float>) -> SIMD2<Float> {
                    SIMD2<Float>(v.x * cosY - v.y * sinY, v.x * sinY + v.y * cosY)
                }
                
                let rotCam = rot(camPosAR)
                let rotClusters = topClusters.map { (center: rot($0.center), normal: rot($0.normal), weight: $0.totalWeight) }
                let rotPoints = obsPoints.map { (pos: rot($0.pos), normal: rot($0.normal), weight: $0.weight) }
                
                var candidateTranslations: [SIMD2<Float>] = []
                
                // Method A: Non-parallel pair closed-form 2x2 line intersection (Corner lock!)
                if rotClusters.count >= 2 {
                    for i in 0..<rotClusters.count {
                        let cA = rotClusters[i]
                        for j in (i + 1)..<rotClusters.count {
                            let cB = rotClusters[j]
                            let detAbs = abs(cA.normal.x * cB.normal.y - cA.normal.y * cB.normal.x)
                            guard detAbs > 0.35 else { continue }
                            
                            let matchingA = targets.filter { abs(simd_dot(cA.normal, $0.normal)) > 0.85 }
                            let matchingB = targets.filter { abs(simd_dot(cB.normal, $0.normal)) > 0.85 }
                            
                            for rA in matchingA {
                                let nA = (simd_dot(cA.normal, rA.normal) >= 0) ? rA.normal : -rA.normal
                                let dA = (simd_dot(cA.normal, rA.normal) >= 0) ? rA.offset : -rA.offset
                                let rhsA = dA - simd_dot(cA.center, nA)
                                
                                for rB in matchingB where rB.id != rA.id {
                                    let nB = (simd_dot(cB.normal, rB.normal) >= 0) ? rB.normal : -rB.normal
                                    let dB = (simd_dot(cB.normal, rB.normal) >= 0) ? rB.offset : -rB.offset
                                    let rhsB = dB - simd_dot(cB.center, nB)
                                    
                                    let det = nA.x * nB.y - nA.y * nB.x
                                    guard abs(det) > 0.35 else { continue }
                                    let tx = (rhsA * nB.y - rhsB * nA.y) / det
                                    let tz = (nA.x * rhsB - nB.x * rhsA) / det
                                    
                                    // Quick camera bounds check
                                    let camWorld = SIMD2<Float>(rotCam.x + tx, rotCam.y + tz)
                                    if camWorld.x >= minB.x - 0.8 && camWorld.x <= maxB.x + 0.8 &&
                                       camWorld.y >= minB.y - 0.8 && camWorld.y <= maxB.y + 0.8 {
                                        candidateTranslations.append(SIMD2<Float>(tx, tz))
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Method B: Single-wall sliding hypothesis when user has scanned parallel walls or 1 wide wall
                if candidateTranslations.isEmpty {
                    let cA = rotClusters[0]
                    let matchingA = targets.filter { abs(simd_dot(cA.normal, $0.normal)) > 0.88 }
                    for rA in matchingA {
                        let nA = (simd_dot(cA.normal, rA.normal) >= 0) ? rA.normal : -rA.normal
                        let dA = (simd_dot(cA.normal, rA.normal) >= 0) ? rA.offset : -rA.offset
                        let perpShift = dA - simd_dot(cA.center, nA)
                        
                        // Slide cluster center along reference wall rA in 0.5m increments
                        let steps = max(Int(rA.length / 0.5), 2)
                        for k in 0...steps {
                            let frac = Float(k) / Float(steps)
                            let targetPtOnWall = rA.start + rA.tangent * (rA.length * frac)
                            let alongShift = simd_dot(targetPtOnWall - cA.center, rA.tangent)
                            let trans = nA * perpShift + rA.tangent * alongShift
                            let camWorld = rotCam + trans
                            if camWorld.x >= minB.x - 0.8 && camWorld.x <= maxB.x + 0.8 &&
                               camWorld.y >= minB.y - 0.8 && camWorld.y <= maxB.y + 0.8 {
                                candidateTranslations.append(trans)
                            }
                        }
                    }
                }
                
                // Deduplicate close translation hypotheses (within 0.20m)
                var uniqueTrans: [SIMD2<Float>] = []
                for t in candidateTranslations {
                    if !uniqueTrans.contains(where: { simd_distance($0, t) < 0.20 }) {
                        uniqueTrans.append(t)
                    }
                }
                
                for trans in uniqueTrans {
                    let camWorld = rotCam + trans
                    var score: Float = 0.0
                    var inlierWeight: Float = 0.0
                    
                    for pt in rotPoints {
                        let wp = pt.pos + trans
                        var bestPtDistSq: Float = .greatestFiniteMagnitude
                        
                        for ref in targets {
                            // Normal must align with either side of the two-sided reference wall
                            let normAlign = abs(simd_dot(pt.normal, ref.normal))
                            guard normAlign > 0.78 else { continue }
                            let dSq = Self.pointToSegmentDistanceSquared(p: wp, a: ref.start, b: ref.end)
                            bestPtDistSq = min(bestPtDistSq, dSq)
                        }
                        
                        // Visibility check: ensure camera -> observed wall is not blocked by another wall
                        var occluded = false
                        let rayVec = wp - camWorld
                        let rayDist = simd_length(rayVec)
                        if rayDist > 0.5 {
                            let rayDir = rayVec / rayDist
                            for ref in targets {
                                if let hitD = Self.raySegmentIntersection(origin: camWorld, dir: rayDir, a: ref.start, b: ref.end) {
                                    if hitD > 0.20 && hitD < rayDist - 0.35 {
                                        occluded = true
                                        break
                                    }
                                }
                            }
                        }
                        
                        if occluded {
                            score -= pt.weight * 0.65
                        } else {
                            let kernel = 1.0 / (1.0 + bestPtDistSq / 0.0625) // 25cm half-score scale
                            score += pt.weight * kernel
                            if bestPtDistSq <= 0.1225 { // within 35cm
                                inlierWeight += pt.weight
                            }
                        }
                    }
                    
                    if score > bestScore {
                        bestScore = score
                        bestInlierRatio = totalWeight > 0 ? (inlierWeight / totalWeight) : 0.0
                        bestYaw = yaw
                        bestTx = trans.x
                        bestTz = trans.y
                        
                        // Identify facing wall name
                        let lookWorld = rot(arForward)
                        var closestWallName: String? = nil
                        var closestRayDist: Float = .greatestFiniteMagnitude
                        for ref in targets {
                            if let d = Self.raySegmentIntersection(origin: camWorld, dir: lookWorld, a: ref.start, b: ref.end) {
                                if d < closestRayDist {
                                    closestRayDist = d
                                    closestWallName = ref.displayName
                                }
                            }
                        }
                        bestFacingName = closestWallName
                    }
                }
            }
            
            // 5. Evaluate stability & lock-on consensus
            if hasCornerOrMultiOrientation && bestInlierRatio >= 0.60 && bestScore > 0 {
                if let prev = self.lastBestCandidate {
                    let posDelta = hypot(prev.tx - bestTx, prev.tz - bestTz)
                    let angDelta = abs(Self.normalizeAngle(prev.angle - bestYaw))
                    if posDelta < 0.45 && angDelta < (15.0 * .pi / 180.0) {
                        self.consistentCandidateCount += 1
                    } else {
                        self.consistentCandidateCount = 1
                    }
                } else {
                    self.consistentCandidateCount = 1
                }
                self.lastBestCandidate = (bestYaw, bestTx, bestTz)
                
                let progress = min(Float(self.consistentCandidateCount) / 2.0, 1.0)
                if self.consistentCandidateCount >= 2 {
                    self.transformLock.lock()
                    self.alignmentAngle = bestYaw
                    self.alignmentOffset = SIMD3<Float>(bestTx, 0, bestTz)
                    self.transformLock.unlock()
                    
                    let prefix = isPlanMode ? "Plan" : "Room"
                    let wallText = bestFacingName ?? "\(topClusters.count) walls"
                    DispatchQueue.main.async {
                        if !self.isAutoLocalized {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                        self.isCalibrated = true
                        self.isAutoLocalized = true
                        self.localizationConfidence = bestInlierRatio
                        self.localizedTargetName = wallText
                        self.trackingStatusText = "✓ Locked on \(prefix) (\(Int(bestInlierRatio * 100))% match)"
                    }
                } else {
                    DispatchQueue.main.async {
                        self.localizationConfidence = progress * 0.75
                        self.trackingStatusText = "Corner seen — verifying alignment..."
                    }
                }
            } else {
                // Keep updating transform smoothly as preview while waiting for 2nd wall / corner
                if bestScore > 0 && bestInlierRatio >= 0.45 {
                    self.transformLock.lock()
                    self.alignmentAngle = bestYaw
                    self.alignmentOffset = SIMD3<Float>(bestTx, 0, bestTz)
                    self.transformLock.unlock()
                }
                DispatchQueue.main.async {
                    self.localizationConfidence = bestInlierRatio * 0.5
                    if !hasCornerOrMultiOrientation {
                        self.trackingStatusText = "Wall scanned — turn toward an adjacent wall or corner"
                    } else {
                        self.trackingStatusText = "Matching walls (\(Int(bestInlierRatio * 100))%)... Keep panning slowly"
                    }
                }
            }
        }
    }
    
    // MARK: - LiDAR Center Distance HUD Measurement
    
    private func measureCenterWallOrDepthDistance(frame: ARFrame, camPos: SIMD3<Float>) -> Float? {
        let centerPoint = CGPoint(x: 0.5, y: 0.5)
        let query = frame.raycastQuery(from: centerPoint, allowing: .estimatedPlane, alignment: .vertical)
        if let hit = session.raycast(query).first {
            let hitPos = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
            let d = simd_distance(camPos, hitPos)
            if d > 0.25 && d < 12.0 { return d }
        }
        if #available(iOS 14.0, *), let depthBuffer = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap {
            return readCenterDepth(from: depthBuffer)
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
        let depth = floatBuffer[(height / 2) * width + (width / 2)]
        if depth > 0.25 && depth < 12.0 && !depth.isNaN {
            return depth
        }
        return nil
    }
    
    // MARK: - Geometry Helpers
    
    private static func normalizeAngle(_ a: Float) -> Float {
        var r = a.truncatingRemainder(dividingBy: 2.0 * .pi)
        if r > .pi { r -= 2.0 * .pi }
        if r < -.pi { r += 2.0 * .pi }
        return r
    }
    
    private static func raySegmentIntersection(origin: SIMD2<Float>, dir: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> Float? {
        let v1 = origin - a
        let v2 = b - a
        let v3 = SIMD2<Float>(-dir.y, dir.x)
        
        let dot = simd_dot(v2, v3)
        guard abs(dot) > 1e-6 else { return nil }
        
        let t1 = (v2.x * v1.y - v2.y * v1.x) / dot
        let t2 = simd_dot(v1, v3) / dot
        
        if t1 > 0.1 && t2 >= -0.05 && t2 <= 1.05 {
            return t1
        }
        return nil
    }
    
    private static func pointToSegmentDistanceSquared(p: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lenSq = simd_length_squared(ab)
        if lenSq < 1e-6 { return simd_distance_squared(p, a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / lenSq))
        let proj = a + t * ab
        return simd_distance_squared(p, proj)
    }
    
    // MARK: - Tracking State Handlers
    
    public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        DispatchQueue.main.async {
            switch camera.trackingState {
            case .normal:
                if !self.isAutoLocalized {
                    self.trackingStatusText = self.isLocatingOnImportedPlan
                        ? "Look around at 2 walls or a corner to locate on plan..."
                        : "LiDAR Ready: Pan across 2 walls or a corner..."
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
                    self.trackingStatusText = "Point at walls or corners"
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
