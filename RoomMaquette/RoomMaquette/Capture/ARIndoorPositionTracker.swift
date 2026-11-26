import Foundation
import ARKit
import Metal
import Combine
import SwiftUI
import CoreVideo
import simd

public struct ReferenceWallTarget: Identifiable {
    public var id = UUID()
    public var start: SIMD2<Float>
    public var end: SIMD2<Float>
    public var tangent: SIMD2<Float>
    public var normal: SIMD2<Float>
    public var offset: Float
    public var angle: Float
    public var thickness: Float
    public var interiorNormalSide: Float // +1 = +normal faces indoors, -1 = -normal faces indoors, 0 = both sides (interior wall)
    public var displayName: String
    
    public var length: Float {
        simd_distance(start, end)
    }
    
    public var center: SIMD2<Float> {
        (start + end) * 0.5
    }
}

public struct RoomDiscrepancy: Identifiable, Equatable {
    public enum Kind: Equatable {
        case missingObject(FurnitureObject)
        case newObject(roomPosition: SIMD3<Float>, dimensions: SIMD3<Float>, suggestedName: String, category: ObjectCategory)
    }
    
    public var id = UUID()
    public var kind: Kind
    public var title: String
    public var subtitle: String
}

public class ARIndoorPositionTracker: NSObject, ObservableObject, ARSessionDelegate {
    @Published public var currentPosition: SIMD3<Float>? = nil
    @Published public var currentHeading: Float? = nil
    @Published public var isTracking: Bool = false
    @Published public var trackingStatusText: String = "Scan a corner, furniture, or window to locate..."
    @Published public var isCalibrated: Bool = false
    @Published public var isAutoLocalized: Bool = false
    @Published public var isLocatingOnImportedPlan: Bool = false
    @Published public var localizedTargetName: String? = nil
    @Published public var targetDistanceMeters: Float? = nil
    @Published public var localizationConfidence: Float = 0.0
    @Published public var observedWallCount: Int = 0
    @Published public var observedLandmarkCount: Int = 0
    @Published public var activeDiscrepancy: RoomDiscrepancy? = nil
    @Published public var lockedPlanScale: Float = 1.0
    
    public var session: ARSession
    public var room: MaquetteRoom?
    
    // MARK: - Internal Spatial Types
    
    private struct ObservedWallPoint {
        var pos: SIMD2<Float>
        var normal: SIMD2<Float>
        var weight: Float
        var timestamp: TimeInterval
    }
    
    private enum PortalType: Equatable {
        case window
        case door
        case opening
    }
    
    private struct RefPortal {
        var id: UUID
        var pos: SIMD2<Float>
        var width: Float
        var type: PortalType
    }
    
    private struct RefFurniture {
        var object: FurnitureObject
        var pos: SIMD2<Float>
        var halfW: Float
        var halfD: Float
        var rotY: Float
        var heightAboveFloor: Float
    }
    
    private struct ObservedLandmark {
        enum Kind {
            case furniture(label: String, category: ObjectCategory, estWidth: Float, estDepth: Float, estHeight: Float)
            case window
            case door
        }
        var pos: SIMD3<Float>
        var kind: Kind
        var timestamp: TimeInterval
    }
    
    private struct ClearRay {
        var origin: SIMD2<Float>
        var dir: SIMD2<Float>
        var clearDist: Float
        var atFurnitureHeight: Bool
    }
    
    private struct MeshSemanticExtract {
        var wallPoints: [ObservedWallPoint]
        var landmarks: [ObservedLandmark]
        var floorY: Float?
    }
    
    // Rigid/Similarity SE(2) Transform: AR space -> Reference space (Room or Imported Plan)
    private var alignmentAngle: Float = 0.0
    private var alignmentOffset: SIMD3<Float> = .zero
    private var effectiveScale: Float = 1.0
    private let transformLock = NSLock()
    
    private struct IndoorOccupancyGrid {
        var minX: Float
        var minZ: Float
        var maxX: Float
        var maxZ: Float
        var cellSize: Float
        var cols: Int
        var rows: Int
        var cells: [UInt8] // 0 = indoors, 1 = wall/portal barrier, 2 = outdoors
        var hasEnclosedInterior: Bool
        
        func isOutdoor(_ pt: SIMD2<Float>) -> Bool {
            if !hasEnclosedInterior {
                return pt.x < minX || pt.x > maxX || pt.y < minZ || pt.y > maxZ
            }
            let c = Int(floor((pt.x - minX) / cellSize))
            let r = Int(floor((pt.y - minZ) / cellSize))
            guard c >= 0 && c < cols && r >= 0 && r < rows else { return true }
            return cells[r * cols + c] == 2
        }
        
        func isStrictlyIndoors(_ pt: SIMD2<Float>) -> Bool {
            if !hasEnclosedInterior {
                return pt.x >= minX && pt.x <= maxX && pt.y >= minZ && pt.y <= maxZ
            }
            let c = Int(floor((pt.x - minX) / cellSize))
            let r = Int(floor((pt.y - minZ) / cellSize))
            guard c >= 0 && c < cols && r >= 0 && r < rows else { return false }
            let val = cells[r * cols + c]
            if val == 0 { return true }
            if val == 2 { return false }
            // Wall barrier cell (1): allow only if directly touching an enclosed indoor cell (0)
            for dr in -1...1 {
                for dc in -1...1 {
                    let nr = r + dr
                    let nc = c + dc
                    if nr >= 0 && nr < rows && nc >= 0 && nc < cols {
                        if cells[nr * cols + nc] == 0 {
                            return true
                        }
                    }
                }
            }
            return false
        }
    }
    
    // Reference Geometry built from MaquetteRoom
    private var referenceTargets: [ReferenceWallTarget] = []
    private var referencePortals: [RefPortal] = []
    private var referenceFurniture: [RefFurniture] = []
    private var referenceCorners: [SIMD2<Float>] = []
    private var indoorGrid: IndoorOccupancyGrid? = nil
    private var refMinBounds = SIMD2<Float>(-5, -5)
    private var refMaxBounds = SIMD2<Float>(5, 5)
    private var roomFloorY: Float = 0.0
    
    // Live Sensor State (accessed on delegate / solver)
    private var estimatedFloorY: Float = -1.30
    private var floorCalibrated: Bool = false
    private var verticalPlaneAnchors: [UUID: ARPlaneAnchor] = [:]
    private var horizontalPlaneAnchors: [UUID: ARPlaneAnchor] = [:]
    private var meshExtracts: [UUID: MeshSemanticExtract] = [:]
    private var observedRayPoints: [ObservedWallPoint] = []
    private var observedDepthObstacles: [ObservedLandmark] = []
    private var clearRays: [ClearRay] = []
    private var frameCount: Int = 0
    
    // Background Solver State
    private let solverQueue = DispatchQueue(label: "com.roommaquette.localization", qos: .userInitiated)
    private var isSolving: Bool = false
    private var lastSolveTime: TimeInterval = 0
    private var lastRefineTime: TimeInterval = 0
    private var consistentCandidateCount: Int = 0
    private var lastBestCandidate: (angle: Float, tx: Float, tz: Float, scale: Float)? = nil
    
    // Discrepancy Verification State
    private var lastDiscrepancyCheckTime: TimeInterval = 0
    private var missingStrikes: [UUID: Int] = [:]
    private var newObjectStrikes: [String: (count: Int, sumPos: SIMD3<Float>, name: String, cat: ObjectCategory)] = [:]
    private var dismissedMissingIds: Set<UUID> = []
    private var dismissedNewPositions: [SIMD2<Float>] = []
    
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
        config.planeDetection = [.horizontal, .vertical]
        
        if #available(iOS 13.0, *), ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if #available(iOS 14.0, *), ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        
        let hasImportedPlan = room?.importedPlan != nil && !(room?.importedPlan?.vectorLines.isEmpty ?? true)
        let isPlanOnlyRoom = (room?.walls.isEmpty ?? true) || (room?.notes.hasPrefix("Created from imported plan:") ?? false)
        self.isLocatingOnImportedPlan = hasImportedPlan && isPlanOnlyRoom
        
        if let r = room {
            rebuildReferenceGeometry(for: r, usePlanSpace: self.isLocatingOnImportedPlan)
        } else {
            self.referenceTargets = []
            self.referencePortals = []
            self.referenceFurniture = []
            self.referenceCorners = []
            self.indoorGrid = nil
        }
        
        transformLock.lock()
        self.alignmentAngle = 0.0
        self.alignmentOffset = .zero
        self.effectiveScale = 1.0
        transformLock.unlock()
        
        // IMPORTANT: Keep position nil until localization is genuinely confirmed!
        self.currentPosition = nil
        self.currentHeading = nil
        self.isCalibrated = false
        self.isAutoLocalized = false
        self.localizationConfidence = 0.0
        self.lockedPlanScale = 1.0
        self.consistentCandidateCount = 0
        self.lastBestCandidate = nil
        self.localizedTargetName = nil
        self.targetDistanceMeters = nil
        self.observedWallCount = 0
        self.observedLandmarkCount = 0
        self.activeDiscrepancy = nil
        self.lastRefineTime = 0
        
        self.floorCalibrated = false
        self.estimatedFloorY = -1.30
        self.verticalPlaneAnchors.removeAll()
        self.horizontalPlaneAnchors.removeAll()
        self.meshExtracts.removeAll()
        self.observedRayPoints.removeAll()
        self.observedDepthObstacles.removeAll()
        self.clearRays.removeAll()
        self.missingStrikes.removeAll()
        self.newObjectStrikes.removeAll()
        self.dismissedMissingIds.removeAll()
        self.dismissedNewPositions.removeAll()
        self.lastSolveTime = 0
        self.isSolving = false
        
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isTracking = true
        trackingStatusText = isLocatingOnImportedPlan
            ? "Scan a corner & doorway/furniture to locate on plan"
            : "Look around at walls, furniture & windows to locate..."
    }
    
    public func updateRoom(_ updatedRoom: MaquetteRoom) {
        self.room = updatedRoom
        rebuildReferenceGeometry(for: updatedRoom, usePlanSpace: self.isLocatingOnImportedPlan)
        self.missingStrikes.removeAll()
        self.newObjectStrikes.removeAll()
    }
    
    public func dismissDiscrepancy(_ discrepancy: RoomDiscrepancy) {
        switch discrepancy.kind {
        case .missingObject(let obj):
            dismissedMissingIds.insert(obj.id)
        case .newObject(let pos, _, _, _):
            dismissedNewPositions.append(SIMD2<Float>(pos.x, pos.z))
        }
        if activeDiscrepancy?.id == discrepancy.id {
            activeDiscrepancy = nil
        }
    }
    
    public func stop() {
        session.pause()
        isTracking = false
        currentPosition = nil
        currentHeading = nil
        targetDistanceMeters = nil
        activeDiscrepancy = nil
    }
    
    public func relocalize() {
        self.isAutoLocalized = false
        self.isCalibrated = false
        self.currentPosition = nil
        self.currentHeading = nil
        self.consistentCandidateCount = 0
        self.lastBestCandidate = nil
        self.localizationConfidence = 0.0
        self.lockedPlanScale = 1.0
        self.observedWallCount = 0
        self.observedLandmarkCount = 0
        self.activeDiscrepancy = nil
        self.lastRefineTime = 0
        transformLock.lock()
        self.effectiveScale = 1.0
        transformLock.unlock()
        self.observedRayPoints.removeAll()
        self.observedDepthObstacles.removeAll()
        self.clearRays.removeAll()
        self.missingStrikes.removeAll()
        self.newObjectStrikes.removeAll()
        self.trackingStatusText = "Relocalizing... Pan across walls, furniture & windows"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    // MARK: - ARSessionDelegate
    
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        let camTransform = frame.camera.transform
        let rawPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
        if !floorCalibrated {
            estimatedFloorY = rawPos.y - 1.35
        }
        
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
        
        // 2. Sample vertical walls + dense LiDAR depth (for furniture obstacles & clear-air rays)
        if frameCount % 4 == 0 {
            sampleHorizontalVerticalWallFan(frame: frame, camPos: rawPos)
            sampleSceneDepthFeatures(frame: frame, camPos: rawPos)
        }
        
        // 3. Solve similarity/rigid SE(2) pose until locked with high certainty + uniqueness
        let now = Date().timeIntervalSince1970
        if !isAutoLocalized && !isSolving && !referenceTargets.isEmpty && (now - lastSolveTime) > 0.38 {
            lastSolveTime = now
            triggerLocalizationSolve(camPosAR: SIMD2<Float>(rawPos.x, rawPos.z), arForward: normARForward)
        }
        
        // 4. Publish position & heading ONCE localized + periodic continuous drift refinement
        if isAutoLocalized {
            transformLock.lock()
            let yaw = alignmentAngle
            let offset = alignmentOffset
            let curScale = effectiveScale
            transformLock.unlock()
            
            let cosA = cos(yaw)
            let sinA = sin(yaw)
            
            let sx = rawPos.x * curScale
            let sz = rawPos.z * curScale
            let rotX = sx * cosA - sz * sinA
            let rotZ = sx * sinA + sz * cosA
            let transformedPos = SIMD3<Float>(rotX + offset.x, rawPos.y, rotZ + offset.z)
            
            let roomLookX = normARForward.x * cosA - normARForward.y * sinA
            let roomLookZ = normARForward.x * sinA + normARForward.y * cosA
            let screenHeading = atan2(roomLookZ, roomLookX)
            
            DispatchQueue.main.async {
                self.currentPosition = transformedPos
                self.currentHeading = screenHeading
            }
            
            // Continuous local refinement against live vertical wall planes to prevent VIO drift
            if !isSolving && !referenceTargets.isEmpty && (now - lastRefineTime) > 0.90 {
                lastRefineTime = now
                triggerContinuousPoseRefinement(camPosAR: SIMD2<Float>(rawPos.x, rawPos.z))
            }
            
            // 5. Discrepancy Detection (Missing items & New items in the room)
            if activeDiscrepancy == nil && (!isLocatingOnImportedPlan || !referenceFurniture.isEmpty) && (now - lastDiscrepancyCheckTime) > 0.40 {
                lastDiscrepancyCheckTime = now
                evaluateLiveDiscrepancies(frame: frame, camPosAR: rawPos, yaw: yaw, offset: offset, curScale: curScale)
            }
        }
    }
    
    // MARK: - Plane & Mesh Anchor Delegates
    
    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        processAnchors(anchors)
    }
    
    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        processAnchors(anchors)
    }
    
    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            verticalPlaneAnchors.removeValue(forKey: anchor.identifier)
            horizontalPlaneAnchors.removeValue(forKey: anchor.identifier)
            meshExtracts.removeValue(forKey: anchor.identifier)
        }
    }
    
    private func processAnchors(_ anchors: [ARAnchor]) {
        let now = Date().timeIntervalSince1970
        for anchor in anchors {
            if let plane = anchor as? ARPlaneAnchor {
                if plane.alignment == .vertical {
                    verticalPlaneAnchors[plane.identifier] = plane
                } else if plane.alignment == .horizontal {
                    horizontalPlaneAnchors[plane.identifier] = plane
                    let area: Float
                    if #available(iOS 16.0, *) {
                        area = plane.planeExtent.width * plane.planeExtent.height
                    } else {
                        area = plane.extent.x * plane.extent.z
                    }
                    let y = plane.transform.columns.3.y
                    if area > 0.70 && (!floorCalibrated || y < estimatedFloorY + 0.10) && y < -0.50 {
                        estimatedFloorY = y
                        floorCalibrated = true
                    }
                }
            } else if let meshAnchor = anchor as? ARMeshAnchor {
                meshExtracts[meshAnchor.identifier] = extractMeshSemantics(meshAnchor: meshAnchor, now: now)
            }
        }
    }
    
    private func extractMeshSemantics(meshAnchor: ARMeshAnchor, now: TimeInterval) -> MeshSemanticExtract {
        let geo = meshAnchor.geometry
        let wt = meshAnchor.transform
        let verts = geo.vertices
        let faces = geo.faces
        let faceCount = faces.count
        
        guard faceCount > 0, faces.indexCountPerPrimitive == 3 else {
            return MeshSemanticExtract(wallPoints: [], landmarks: [], floorY: nil)
        }
        
        let vPtr = verts.buffer.contents()
        let fPtr = faces.buffer.contents()
        let cSource = geo.classification
        let cPtr = cSource?.buffer.contents()
        
        let strideStep = max(faceCount / 140, 1)
        var wallPts: [ObservedWallPoint] = []
        var landmarks: [ObservedLandmark] = []
        var floorYSum: Float = 0
        var floorYCount: Int = 0
        
        func readVertex(_ idx: Int) -> SIMD3<Float>? {
            guard idx >= 0 && idx < verts.count else { return nil }
            let byteOff = verts.offset + idx * verts.stride
            guard byteOff + 12 <= verts.buffer.length else { return nil }
            let x = vPtr.load(fromByteOffset: byteOff, as: Float.self)
            let y = vPtr.load(fromByteOffset: byteOff + 4, as: Float.self)
            let z = vPtr.load(fromByteOffset: byteOff + 8, as: Float.self)
            return SIMD3<Float>(x, y, z)
        }
        
        func readIndex(_ i: Int) -> Int {
            let off = i * faces.bytesPerIndex
            guard off + faces.bytesPerIndex <= faces.buffer.length else { return -1 }
            if faces.bytesPerIndex == 4 {
                return Int(fPtr.load(fromByteOffset: off, as: UInt32.self))
            } else {
                return Int(fPtr.load(fromByteOffset: off, as: UInt16.self))
            }
        }
        
        var faceIdx = 0
        while faceIdx < faceCount {
            defer { faceIdx += strideStep }
            let i0 = readIndex(faceIdx * 3)
            let i1 = readIndex(faceIdx * 3 + 1)
            let i2 = readIndex(faceIdx * 3 + 2)
            guard let lv0 = readVertex(i0), let lv1 = readVertex(i1), let lv2 = readVertex(i2) else { continue }
            
            let w0 = simd_mul(wt, SIMD4<Float>(lv0, 1.0))
            let w1 = simd_mul(wt, SIMD4<Float>(lv1, 1.0))
            let w2 = simd_mul(wt, SIMD4<Float>(lv2, 1.0))
            let p0 = SIMD3<Float>(w0.x, w0.y, w0.z)
            let p1 = SIMD3<Float>(w1.x, w1.y, w1.z)
            let p2 = SIMD3<Float>(w2.x, w2.y, w2.z)
            let centroid = (p0 + p1 + p2) / 3.0
            
            let crossN = simd_cross(p1 - p0, p2 - p0)
            let nLen = simd_length(crossN)
            guard nLen > 1e-4 else { continue }
            let norm = crossN / nLen
            
            var classification: ARMeshClassification = .none
            if let cs = cSource, let cp = cPtr, faceIdx < cs.count {
                let cOff = cs.offset + faceIdx * cs.stride
                if cOff + 1 <= cs.buffer.length {
                    let rawClass = cp.load(fromByteOffset: cOff, as: UInt8.self)
                    classification = ARMeshClassification(rawValue: Int(rawClass)) ?? .none
                }
            }
            
            switch classification {
            case .wall:
                if abs(norm.y) < 0.35 {
                    let hNorm = SIMD2<Float>(norm.x, norm.z)
                    if simd_length(hNorm) > 0.2 {
                        wallPts.append(ObservedWallPoint(
                            pos: SIMD2<Float>(centroid.x, centroid.z),
                            normal: simd_normalize(hNorm),
                            weight: 1.5,
                            timestamp: now
                        ))
                    }
                }
            case .window:
                landmarks.append(ObservedLandmark(pos: centroid, kind: .window, timestamp: now))
            case .door:
                landmarks.append(ObservedLandmark(pos: centroid, kind: .door, timestamp: now))
            case .table:
                if centroid.y - estimatedFloorY > 0.25 {
                    landmarks.append(ObservedLandmark(
                        pos: centroid,
                        kind: .furniture(label: "Table / Desk", category: .table, estWidth: 1.0, estDepth: 0.7, estHeight: max(centroid.y - estimatedFloorY, 0.65)),
                        timestamp: now
                    ))
                }
            case .seat:
                if centroid.y - estimatedFloorY > 0.20 {
                    landmarks.append(ObservedLandmark(
                        pos: centroid,
                        kind: .furniture(label: "Chair / Sofa", category: .chair, estWidth: 0.8, estDepth: 0.8, estHeight: max(centroid.y - estimatedFloorY, 0.55)),
                        timestamp: now
                    ))
                }
            case .floor:
                floorYSum += centroid.y
                floorYCount += 1
            default:
                break
            }
        }
        
        let avgFloorY = floorYCount >= 3 ? (floorYSum / Float(floorYCount)) : nil
        return MeshSemanticExtract(wallPoints: wallPts, landmarks: landmarks, floorY: avgFloorY)
    }
    
    // MARK: - Reference Geometry Builder
    
    private func rebuildReferenceGeometry(for room: MaquetteRoom, usePlanSpace: Bool) {
        var targets: [ReferenceWallTarget] = []
        let isPlanCreated = room.notes.hasPrefix("Created from imported plan:")
        
        // Prefer room.walls whenever present so 2D editor edits, custom walls & thicknesses apply immediately!
        if !room.walls.isEmpty {
            let align = (usePlanSpace && !isPlanCreated) ? room.importedPlan?.alignment : nil
            for (idx, wall) in room.walls.enumerated() {
                let s = wall.startPoint2D
                let e = wall.endPoint2D
                var p1 = SIMD2<Float>(Float(s.x), Float(s.y))
                var p2 = SIMD2<Float>(Float(e.x), Float(e.y))
                var thick = wall.thickness
                if let al = align {
                    let m1 = al.mapScanToPlan(point: SIMD3<Float>(p1.x, 0, p1.y))
                    let m2 = al.mapScanToPlan(point: SIMD3<Float>(p2.x, 0, p2.y))
                    p1 = SIMD2<Float>(m1.x, m1.z)
                    p2 = SIMD2<Float>(m2.x, m2.z)
                    thick *= al.scale
                }
                if let t = makeReferenceTarget(p1: p1, p2: p2, thickness: thick, name: "\(wall.displayName) #\(idx + 1)") {
                    targets.append(t)
                }
            }
        } else if usePlanSpace, let plan = room.importedPlan, !plan.vectorLines.isEmpty {
            for (idx, line) in plan.vectorLines.enumerated() {
                if let t = makeReferenceTarget(p1: SIMD2<Float>(line.startX, line.startZ),
                                               p2: SIMD2<Float>(line.endX, line.endZ),
                                               thickness: 0.15,
                                               name: "Plan Wall #\(idx + 1)") {
                    targets.append(t)
                }
            }
        }
        self.referenceTargets = targets
        
        // Precompute structural L-corners & T-junction vertices
        var rawCorners: [SIMD2<Float>] = []
        for i in 0..<targets.count {
            let wA = targets[i]
            for j in (i + 1)..<targets.count {
                let wB = targets[j]
                guard abs(wA.tangent.x * wB.tangent.y - wA.tangent.y * wB.tangent.x) > 0.35 else { continue }
                let endpointsA = [wA.start, wA.end]
                let endpointsB = [wB.start, wB.end]
                var mergedPt: SIMD2<Float>? = nil
                for epA in endpointsA {
                    for epB in endpointsB where simd_distance(epA, epB) <= 0.45 {
                        mergedPt = (epA + epB) * 0.5
                        break
                    }
                    if mergedPt != nil { break }
                }
                if mergedPt == nil {
                    for epA in endpointsA where Self.pointToSegmentDistanceSquared(p: epA, a: wB.start, b: wB.end) <= (0.40 * 0.40) {
                        mergedPt = epA
                        break
                    }
                }
                if mergedPt == nil {
                    for epB in endpointsB where Self.pointToSegmentDistanceSquared(p: epB, a: wA.start, b: wA.end) <= (0.40 * 0.40) {
                        mergedPt = epB
                        break
                    }
                }
                if let corner = mergedPt, !rawCorners.contains(where: { simd_distance($0, corner) < 0.35 }) {
                    rawCorners.append(corner)
                }
            }
        }
        self.referenceCorners = rawCorners
        
        // Floor Y in room coordinates
        if let firstWall = room.walls.first {
            let floorEstimates = room.walls.map { $0.position.y - $0.height * 0.5 }
            self.roomFloorY = floorEstimates.reduce(0, +) / Float(max(floorEstimates.count, 1))
            _ = firstWall
        } else {
            self.roomFloorY = room.boundingBox.min.y
        }
        
        // Portals (Windows, Doors, Openings) — map only if walls aren't already in active plan space
        var portals: [RefPortal] = []
        let alignPortals = (usePlanSpace && !isPlanCreated) ? room.importedPlan?.alignment : nil
        func mapToActive(_ pos: SIMD3<Float>) -> SIMD2<Float> {
            if let al = alignPortals {
                let p = al.mapScanToPlan(point: pos)
                return SIMD2<Float>(p.x, p.z)
            }
            return SIMD2<Float>(pos.x, pos.z)
        }
        for w in room.windows {
            portals.append(RefPortal(id: w.id, pos: mapToActive(w.position), width: w.width, type: .window))
        }
        for d in room.doors {
            portals.append(RefPortal(id: d.id, pos: mapToActive(d.position), width: d.width, type: .door))
        }
        for o in room.openings {
            portals.append(RefPortal(id: o.id, pos: mapToActive(o.position), width: o.width, type: .opening))
        }
        // Fallback: if room arrays are empty, check plan.detectedDoors/Windows/Openings
        if portals.isEmpty, usePlanSpace, let plan = room.importedPlan {
            for w in plan.detectedWindows ?? [] {
                portals.append(RefPortal(id: w.id, pos: SIMD2<Float>(w.position.x, w.position.z), width: w.width, type: .window))
            }
            for d in plan.detectedDoors ?? [] {
                portals.append(RefPortal(id: d.id, pos: SIMD2<Float>(d.position.x, d.position.z), width: d.width, type: .door))
            }
            for o in plan.detectedOpenings ?? [] {
                portals.append(RefPortal(id: o.id, pos: SIMD2<Float>(o.position.x, o.position.z), width: o.width, type: .opening))
            }
        }
        self.referencePortals = portals
        
        // Furniture Objects
        var furn: [RefFurniture] = []
        for obj in room.objects {
            let p2 = mapToActive(obj.position)
            furn.append(RefFurniture(
                object: obj,
                pos: p2,
                halfW: obj.width * 0.5,
                halfD: obj.depth * 0.5,
                rotY: obj.rotationY + (alignPortals?.rotationAngle ?? 0),
                heightAboveFloor: max(obj.height, 0.35)
            ))
        }
        self.referenceFurniture = furn
        
        // Bounding Envelope & Strict Indoor Perimeter Grid
        if targets.isEmpty {
            refMinBounds = SIMD2<Float>(-5, -5)
            refMaxBounds = SIMD2<Float>(5, 5)
            self.indoorGrid = nil
        } else {
            var minX: Float = .greatestFiniteMagnitude, maxX: Float = -.greatestFiniteMagnitude
            var minZ: Float = .greatestFiniteMagnitude, maxZ: Float = -.greatestFiniteMagnitude
            for t in targets {
                minX = min(minX, t.start.x, t.end.x)
                maxX = max(maxX, t.start.x, t.end.x)
                minZ = min(minZ, t.start.y, t.end.y)
                maxZ = max(maxZ, t.start.y, t.end.y)
            }
            refMinBounds = SIMD2<Float>(minX, minZ)
            refMaxBounds = SIMD2<Float>(maxX, maxZ)
            
            let grid = Self.buildIndoorOccupancyGrid(targets: targets, portals: portals, minB: refMinBounds, maxB: refMaxBounds)
            self.indoorGrid = grid
            
            // Determine which side(s) of each wall are indoors vs outdoors
            if grid.hasEnclosedInterior {
                for i in 0..<targets.count {
                    let w = targets[i]
                    var plusOutCount = 0
                    var minusOutCount = 0
                    let probeFracs: [Float] = [0.25, 0.50, 0.75]
                    for frac in probeFracs {
                        let sampleBase = w.start + (w.end - w.start) * frac
                        let pPlus = sampleBase + w.normal * 0.45
                        let pMinus = sampleBase - w.normal * 0.45
                        if grid.isOutdoor(pPlus) && !grid.isOutdoor(pMinus) {
                            plusOutCount += 1
                        } else if grid.isOutdoor(pMinus) && !grid.isOutdoor(pPlus) {
                            minusOutCount += 1
                        }
                    }
                    if plusOutCount >= 2 && minusOutCount == 0 {
                        targets[i].interiorNormalSide = -1.0 // only -normal points inside
                    } else if minusOutCount >= 2 && plusOutCount == 0 {
                        targets[i].interiorNormalSide = 1.0  // only +normal points inside
                    } else {
                        targets[i].interiorNormalSide = 0.0  // interior partition wall (both sides inside)
                    }
                }
                self.referenceTargets = targets
            }
        }
    }
    
    private static func buildIndoorOccupancyGrid(
        targets: [ReferenceWallTarget],
        portals: [RefPortal],
        minB: SIMD2<Float>,
        maxB: SIMD2<Float>
    ) -> IndoorOccupancyGrid {
        let spanX = max(maxB.x - minB.x, 1.0)
        let spanZ = max(maxB.y - minB.y, 1.0)
        let cellSize: Float = max(0.20, max(spanX, spanZ) / 150.0)
        let pad: Float = max(cellSize * 3.0, 0.60)
        
        let gMinX = minB.x - pad
        let gMinZ = minB.y - pad
        let gMaxX = maxB.x + pad
        let gMaxZ = maxB.y + pad
        
        let cols = max(Int(ceil((gMaxX - gMinX) / cellSize)) + 1, 8)
        let rows = max(Int(ceil((gMaxZ - gMinZ) / cellSize)) + 1, 8)
        var cells = [UInt8](repeating: 0, count: cols * rows)
        
        func rasterizeSegment(_ a: SIMD2<Float>, _ b: SIMD2<Float>) {
            let dist = simd_distance(a, b)
            let steps = max(Int(ceil(dist / (cellSize * 0.35))), 1)
            var prevC: Int? = nil
            var prevR: Int? = nil
            for k in 0...steps {
                let t = Float(k) / Float(steps)
                let p = a + (b - a) * t
                let c = min(max(Int(floor((p.x - gMinX) / cellSize)), 0), cols - 1)
                let r = min(max(Int(floor((p.y - gMinZ) / cellSize)), 0), rows - 1)
                cells[r * cols + c] = 1
                // Keep barrier 4-connected across diagonal steps so exterior BFS cannot leak diagonally
                if let pc = prevC, let pr = prevR, pc != c && pr != r {
                    cells[pr * cols + c] = 1
                }
                prevC = c
                prevR = r
            }
        }
        
        // 1. Rasterize all walls
        for w in targets {
            rasterizeSegment(w.start, w.end)
        }
        
        // 2. Seal doorway/window gaps along collinear wall pairs and corner snaps so entrance doors don't leak BFS outside
        for i in 0..<targets.count {
            let wA = targets[i]
            for j in (i + 1)..<targets.count {
                let wB = targets[j]
                let isCollinear = abs(simd_dot(wA.tangent, wB.tangent)) > 0.90
                let ptsA = [wA.start, wA.end]
                let ptsB = [wB.start, wB.end]
                for p1 in ptsA {
                    for p2 in ptsB {
                        let d = simd_distance(p1, p2)
                        if d <= 0.45 {
                            rasterizeSegment(p1, p2)
                        } else if isCollinear && d <= 1.45 {
                            let perp = abs(simd_dot(p2 - p1, wA.normal))
                            if perp <= 0.35 {
                                rasterizeSegment(p1, p2)
                            }
                        }
                    }
                }
            }
        }
        for p in portals {
            let c = min(max(Int(floor((p.pos.x - gMinX) / cellSize)), 1), cols - 2)
            let r = min(max(Int(floor((p.pos.y - gMinZ) / cellSize)), 1), rows - 2)
            for dr in -1...1 {
                for dc in -1...1 {
                    cells[(r + dr) * cols + (c + dc)] = 1
                }
            }
        }
        
        // 3. 4-connected BFS flood fill from outer padding border to label all outdoor cells (2)
        var queue: [Int] = []
        queue.reserveCapacity(cols * 2 + rows * 2)
        for c in 0..<cols {
            for r in [0, rows - 1] {
                let idx = r * cols + c
                if cells[idx] == 0 {
                    cells[idx] = 2
                    queue.append(idx)
                }
            }
        }
        for r in 0..<rows {
            for c in [0, cols - 1] {
                let idx = r * cols + c
                if cells[idx] == 0 {
                    cells[idx] = 2
                    queue.append(idx)
                }
            }
        }
        
        var head = 0
        while head < queue.count {
            let idx = queue[head]
            head += 1
            let r = idx / cols
            let c = idx % cols
            if c > 0 {
                let n = idx - 1
                if cells[n] == 0 { cells[n] = 2; queue.append(n) }
            }
            if c + 1 < cols {
                let n = idx + 1
                if cells[n] == 0 { cells[n] = 2; queue.append(n) }
            }
            if r > 0 {
                let n = idx - cols
                if cells[n] == 0 { cells[n] = 2; queue.append(n) }
            }
            if r + 1 < rows {
                let n = idx + cols
                if cells[n] == 0 { cells[n] = 2; queue.append(n) }
            }
        }
        
        var interiorCount = 0
        for v in cells where v == 0 { interiorCount += 1 }
        let hasEnclosed = interiorCount >= 6
        
        return IndoorOccupancyGrid(
            minX: hasEnclosed ? gMinX : minB.x - 0.12,
            minZ: hasEnclosed ? gMinZ : minB.y - 0.12,
            maxX: hasEnclosed ? gMaxX : maxB.x + 0.12,
            maxZ: hasEnclosed ? gMaxZ : maxB.y + 0.12,
            cellSize: cellSize,
            cols: cols,
            rows: rows,
            cells: cells,
            hasEnclosedInterior: hasEnclosed
        )
    }
    
    private func makeReferenceTarget(p1: SIMD2<Float>, p2: SIMD2<Float>, thickness: Float = 0.15, name: String) -> ReferenceWallTarget? {
        let diff = p2 - p1
        let len = simd_length(diff)
        guard len >= 0.25 else { return nil }
        let tangent = diff / len
        let normal = SIMD2<Float>(-tangent.y, tangent.x)
        return ReferenceWallTarget(
            start: p1,
            end: p2,
            tangent: tangent,
            normal: normal,
            offset: simd_dot(p1, normal),
            angle: atan2(normal.y, normal.x),
            thickness: thickness,
            interiorNormalSide: 0.0,
            displayName: name
        )
    }
    
    // MARK: - LiDAR Wall Ray & Depth Feature Sampling
    
    private func sampleHorizontalVerticalWallFan(frame: ARFrame, camPos: SIMD3<Float>) {
        let camXZ = SIMD2<Float>(camPos.x, camPos.z)
        let sampleX: [CGFloat] = [0.22, 0.36, 0.50, 0.64, 0.78]
        let now = Date().timeIntervalSince1970
        
        for sx in sampleX {
            let query = frame.raycastQuery(from: CGPoint(x: sx, y: 0.50), allowing: .estimatedPlane, alignment: .vertical)
            guard let hit = session.raycast(query).first else { continue }
            
            let col1 = hit.worldTransform.columns.1
            guard abs(col1.y) < 0.35 else { continue }
            
            let hp3 = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
            let dist = simd_distance(camPos, hp3)
            guard dist >= 0.35 && dist <= 8.5 else { continue }
            
            var norm2 = SIMD2<Float>(col1.x, col1.z)
            let nLen = simd_length(norm2)
            guard nLen > 0.2 else { continue }
            norm2 /= nLen
            
            let hitXZ = SIMD2<Float>(hp3.x, hp3.z)
            if simd_dot(norm2, camXZ - hitXZ) < 0 { norm2 = -norm2 }
            
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
    
    private func sampleSceneDepthFeatures(frame: ARFrame, camPos: SIMD3<Float>) {
        guard #available(iOS 14.0, *),
              let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        let depthBuf = sceneDepth.depthMap
        let confBuf = sceneDepth.confidenceMap
        
        CVPixelBufferLockBaseAddress(depthBuf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuf, .readOnly) }
        if let cb = confBuf { CVPixelBufferLockBaseAddress(cb, .readOnly) }
        defer { if let cb = confBuf { CVPixelBufferUnlockBaseAddress(cb, .readOnly) } }
        
        let dW = CVPixelBufferGetWidth(depthBuf)
        let dH = CVPixelBufferGetHeight(depthBuf)
        guard dW > 16, dH > 16, let dBase = CVPixelBufferGetBaseAddress(depthBuf) else { return }
        let dFloats = dBase.assumingMemoryBound(to: Float32.self)
        let cBytes = confBuf.flatMap { CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to: UInt8.self) }
        
        let imgRes = frame.camera.imageResolution
        guard imgRes.width > 0 && imgRes.height > 0 else { return }
        let scaleX = Float(dW) / Float(imgRes.width)
        let scaleY = Float(dH) / Float(imgRes.height)
        let K = frame.camera.intrinsics
        let fx = K.columns.0.x * scaleX
        let fy = K.columns.1.y * scaleY
        let cx = K.columns.2.x * scaleX
        let cy = K.columns.2.y * scaleY
        guard fx > 1 && fy > 1 else { return }
        
        let camT = frame.camera.transform
        let camXZ = SIMD2<Float>(camPos.x, camPos.z)
        let now = Date().timeIntervalSince1970
        
        let stepX = max(dW / 9, 1)
        let stepY = max(dH / 7, 1)
        
        for py in stride(from: stepY, to: dH - stepY, by: stepY) {
            for px in stride(from: stepX, to: dW - stepX, by: stepX) {
                let idx = py * dW + px
                if let cb = cBytes, cb[idx] == 0 { continue } // skip low confidence
                let d = dFloats[idx]
                guard d.isFinite && d >= 0.45 && d <= 6.5 else { continue }
                
                let lx = (Float(px) - cx) * d / fx
                let ly = -(Float(py) - cy) * d / fy
                let lz = -d
                let wp4 = simd_mul(camT, SIMD4<Float>(lx, ly, lz, 1.0))
                let wp = SIMD3<Float>(wp4.x, wp4.y, wp4.z)
                let hAboveFloor = wp.y - estimatedFloorY
                
                let rayVec = SIMD2<Float>(wp.x, wp.z) - camXZ
                let rayLen = simd_length(rayVec)
                if rayLen > 0.6 {
                    let rayDir = rayVec / rayLen
                    let atFurnHeight = (hAboveFloor >= 0.40 && hAboveFloor <= 1.25)
                    clearRays.append(ClearRay(origin: camXZ, dir: rayDir, clearDist: rayLen, atFurnitureHeight: atFurnHeight))
                    if clearRays.count > 45 { clearRays.removeFirst() }
                }
                
                // Candidate interior elevated obstacle (0.28m to 1.20m above floor)
                if hAboveFloor >= 0.28 && hAboveFloor <= 1.20 {
                    // Check it's not right on a detected vertical plane (not a wall)
                    var nearVerticalWall = false
                    let wpXZ = SIMD2<Float>(wp.x, wp.z)
                    for vp in verticalPlaneAnchors.values {
                        let vc = SIMD2<Float>(vp.transform.columns.3.x, vp.transform.columns.3.z)
                        let vn = simd_normalize(SIMD2<Float>(vp.transform.columns.1.x, vp.transform.columns.1.z))
                        if abs(simd_dot(wpXZ - vc, vn)) < 0.30 && simd_distance(wpXZ, vc) < 2.0 {
                            nearVerticalWall = true
                            break
                        }
                    }
                    if !nearVerticalWall {
                        let lm = ObservedLandmark(
                            pos: wp,
                            kind: .furniture(label: "Object", category: .generic, estWidth: 0.65, estDepth: 0.65, estHeight: hAboveFloor),
                            timestamp: now
                        )
                        addDepthObstacle(lm)
                    }
                }
            }
        }
    }
    
    private func addDepthObstacle(_ lm: ObservedLandmark) {
        let p2 = SIMD2<Float>(lm.pos.x, lm.pos.z)
        for i in 0..<observedDepthObstacles.count {
            let ep = SIMD2<Float>(observedDepthObstacles[i].pos.x, observedDepthObstacles[i].pos.z)
            if simd_distance(ep, p2) < 0.45 {
                observedDepthObstacles[i] = lm
                return
            }
        }
        observedDepthObstacles.append(lm)
        if observedDepthObstacles.count > 40 {
            observedDepthObstacles.removeFirst()
        }
    }
    
    // MARK: - Multi-Modal Rigid SE(2) Solver (Walls + Furniture + Windows/Doors + Free Space)
    
    private func triggerLocalizationSolve(camPosAR: SIMD2<Float>, arForward: SIMD2<Float>) {
        isSolving = true
        
        let vPlaneSnapshots: [(transform: simd_float4x4, width: Float)] = verticalPlaneAnchors.values.map { plane in
            let w: Float
            if #available(iOS 16.0, *) { w = max(plane.planeExtent.width, 0.35) }
            else { w = max(plane.extent.x, 0.35) }
            return (transform: plane.transform, width: w)
        }
        
        let hPlaneSnapshots: [(pos: SIMD3<Float>, width: Float, depth: Float)] = horizontalPlaneAnchors.values.compactMap { plane in
            let pos = SIMD3<Float>(plane.transform.columns.3.x, plane.transform.columns.3.y, plane.transform.columns.3.z)
            let hAbove = pos.y - estimatedFloorY
            guard hAbove >= 0.25 && hAbove <= 1.35 else { return nil }
            let w: Float
            let d: Float
            if #available(iOS 16.0, *) {
                w = plane.planeExtent.width
                d = plane.planeExtent.height
            } else {
                w = plane.extent.x
                d = plane.extent.z
            }
            guard max(w, d) >= 0.35 else { return nil }
            return (pos: pos, width: w, depth: d)
        }
        
        let meshList = Array(meshExtracts.values)
        let rayPointsSnapshot = observedRayPoints
        let depthObstaclesSnapshot = observedDepthObstacles
        let clearRaySnapshot = Array(clearRays.suffix(24))
        
        let targets = referenceTargets
        let portals = referencePortals
        let furniture = referenceFurniture
        let corners = referenceCorners
        let grid = indoorGrid
        let minB = refMinBounds
        let maxB = refMaxBounds
        let curFloorY = estimatedFloorY
        let isPlanMode = isLocatingOnImportedPlan
        
        solverQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async {
                    self.isSolving = false
                }
            }
            
            let now = Date().timeIntervalSince1970
            var obsWalls: [ObservedWallPoint] = []
            var obsPortals: [ObservedLandmark] = []
            var obsFurnClusters: [ObservedLandmark] = []
            
            // 1a. Wall points from vertical planes
            for plane in vPlaneSnapshots {
                let wt = plane.transform
                let c = SIMD2<Float>(wt.columns.3.x, wt.columns.3.z)
                let col1 = SIMD2<Float>(wt.columns.1.x, wt.columns.1.z)
                let nLen = simd_length(col1)
                guard nLen > 0.2 else { continue }
                var norm = col1 / nLen
                if simd_dot(norm, camPosAR - c) < 0 { norm = -norm }
                
                var tangent = SIMD2<Float>(wt.columns.0.x, wt.columns.0.z)
                tangent = simd_length(tangent) > 0.2 ? simd_normalize(tangent) : SIMD2<Float>(-norm.y, norm.x)
                
                let steps = max(Int(plane.width / 0.35), 2)
                for s in 0...steps {
                    let frac = Float(s) / Float(steps) - 0.5
                    obsWalls.append(ObservedWallPoint(pos: c + tangent * (frac * plane.width), normal: norm, weight: 2.0, timestamp: now))
                }
            }
            obsWalls.append(contentsOf: rayPointsSnapshot)
            
            // 1b. Mesh semantics (walls, windows, doors, tables, seats)
            for ext in meshList {
                if let fy = ext.floorY, (!self.floorCalibrated || fy < curFloorY + 0.1) {
                    DispatchQueue.main.async {
                        self.estimatedFloorY = fy
                        self.floorCalibrated = true
                    }
                }
                for wp in ext.wallPoints {
                    var n = wp.normal
                    if simd_dot(n, camPosAR - wp.pos) < 0 { n = -n }
                    obsWalls.append(ObservedWallPoint(pos: wp.pos, normal: n, weight: 1.5, timestamp: now))
                }
                for lm in ext.landmarks {
                    switch lm.kind {
                    case .window, .door:
                        Self.mergeLandmark(lm, into: &obsPortals, radius: 0.65)
                    case .furniture:
                        Self.mergeLandmark(lm, into: &obsFurnClusters, radius: 0.60)
                    }
                }
            }
            
            // 1c. Elevated horizontal planes (beds, tables, counters, sofas)
            for hp in hPlaneSnapshots {
                let hAbove = max(hp.pos.y - curFloorY, 0.4)
                let lm = ObservedLandmark(
                    pos: hp.pos,
                    kind: .furniture(label: "Surface", category: .table, estWidth: hp.width, estDepth: hp.depth, estHeight: hAbove),
                    timestamp: now
                )
                Self.mergeLandmark(lm, into: &obsFurnClusters, radius: 0.65)
            }
            
            // 1d. Depth elevated obstacles not on walls (supplement if ARMeshClassification wasn't ready yet)
            for dob in depthObstaclesSnapshot {
                let p2 = SIMD2<Float>(dob.pos.x, dob.pos.z)
                let nearWall = obsWalls.contains { simd_distance($0.pos, p2) < 0.38 }
                if !nearWall {
                    Self.mergeLandmark(dob, into: &obsFurnClusters, radius: 0.60)
                }
            }
            
            let totalLandmarks = obsPortals.count + obsFurnClusters.count
            DispatchQueue.main.async {
                self.observedLandmarkCount = totalLandmarks
            }
            
            guard obsWalls.count >= 4 else {
                DispatchQueue.main.async {
                    self.trackingStatusText = "Point at walls & furniture to begin..."
                }
                return
            }
            
            // 2. Cluster observed walls into dominant wall lines
            struct ObsWallCluster {
                var normal: SIMD2<Float>
                var center: SIMD2<Float>
                var offset: Float
                var totalWeight: Float
            }
            var obsClusters: [ObsWallCluster] = []
            for p in obsWalls {
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
            
            var hasCorner = false
            if topClusters.count >= 2 {
                for i in 0..<topClusters.count {
                    for j in (i + 1)..<topClusters.count {
                        if abs(simd_dot(topClusters[i].normal, topClusters[j].normal)) < 0.72 {
                            hasCorner = true
                            break
                        }
                    }
                    if hasCorner { break }
                }
            }
            
            DispatchQueue.main.async {
                self.observedWallCount = max(topClusters.count, vPlaneSnapshots.count)
            }
            guard !topClusters.isEmpty else { return }
            
            // 3. Candidate Yaws aligning dominant observed normal ONLY to indoor wall faces
            var refNormals: [SIMD2<Float>] = []
            for t in targets {
                if t.interiorNormalSide > 0.5 {
                    refNormals.append(t.normal)
                } else if t.interiorNormalSide < -0.5 {
                    refNormals.append(-t.normal)
                } else {
                    refNormals.append(t.normal)
                    refNormals.append(-t.normal)
                }
            }
            var candidateYaws: [Float] = []
            let obsAng = atan2(topClusters[0].normal.y, topClusters[0].normal.x)
            for rn in refNormals {
                let yaw = Self.normalizeAngle(atan2(rn.y, rn.x) - obsAng)
                if !candidateYaws.contains(where: { abs(Self.normalizeAngle($0 - yaw)) < (6.0 * .pi / 180.0) }) {
                    candidateYaws.append(yaw)
                }
            }
            
            struct PoseHyp {
                var yaw: Float
                var tx: Float
                var tz: Float
                var scale: Float
                var score: Float
                var wallInlierRatio: Float
                var semanticMatches: Int
                var facingName: String?
            }
            
            // Compute actual observed AR corner intersections where two dominant walls meet
            var obsCornersAR: [SIMD2<Float>] = []
            if topClusters.count >= 2 {
                for i in 0..<topClusters.count {
                    let cA = topClusters[i]
                    for j in (i + 1)..<topClusters.count {
                        let cB = topClusters[j]
                        let det = cA.normal.x * cB.normal.y - cA.normal.y * cB.normal.x
                        guard abs(det) > 0.35 else { continue }
                        let ix = (cA.offset * cB.normal.y - cB.offset * cA.normal.y) / det
                        let iz = (cA.normal.x * cB.offset - cB.normal.x * cA.offset) / det
                        let cornerPt = SIMD2<Float>(ix, iz)
                        if simd_distance(cornerPt, cA.center) < 2.8 && simd_distance(cornerPt, cB.center) < 2.8 {
                            obsCornersAR.append(cornerPt)
                        }
                    }
                }
            }
            
            let totalWallWeight = max(obsWalls.reduce(Float(0)) { $0 + $1.weight }, 1.0)
            let compassRays8: [SIMD2<Float>] = (0..<8).map {
                let a = Float($0) * (.pi * 0.25)
                return SIMD2<Float>(cos(a), sin(a))
            }
            let maxSpan = max(hypot(maxB.x - minB.x, maxB.y - minB.y), 12.0)
            
            func evaluateHypothesis(yaw: Float, tr: SIMD2<Float>, s: Float) -> PoseHyp {
                let cosY = cos(yaw)
                let sinY = sin(yaw)
                func mapPt(_ v: SIMD2<Float>) -> SIMD2<Float> {
                    let vs = v * s
                    return SIMD2<Float>(vs.x * cosY - vs.y * sinY, vs.x * sinY + vs.y * cosY) + tr
                }
                func rotDir(_ v: SIMD2<Float>) -> SIMD2<Float> {
                    SIMD2<Float>(v.x * cosY - v.y * sinY, v.x * sinY + v.y * cosY)
                }
                
                let camW = mapPt(camPosAR)
                var score: Float = -abs(s - 1.0) * 3.0 // prefer 1.0 when scale is ambiguous
                var inlierWeight: Float = 0.0
                var semanticHits = 0
                
                // i. Wall geometry agreement with interior wall half-thickness compensation (ignores exterior faces!)
                for pt in obsWalls {
                    let wp = mapPt(pt.pos)
                    let wn = rotDir(pt.normal)
                    var bestDistSq: Float = .greatestFiniteMagnitude
                    for ref in targets {
                        let sideSign: Float
                        if ref.interiorNormalSide != 0 {
                            guard simd_dot(wn, ref.normal * ref.interiorNormalSide) > 0.78 else { continue }
                            sideSign = ref.interiorNormalSide
                        } else {
                            guard abs(simd_dot(wn, ref.normal)) > 0.78 else { continue }
                            sideSign = simd_dot(camW - ref.center, ref.normal) >= 0 ? 1.0 : -1.0
                        }
                        let faceShift = ref.normal * (sideSign * min(ref.thickness * 0.5, 0.14))
                        let dSq = Self.pointToSegmentDistanceSquared(p: wp, a: ref.start + faceShift, b: ref.end + faceShift)
                        bestDistSq = min(bestDistSq, dSq)
                    }
                    let kernel = 1.0 / (1.0 + bestDistSq / 0.0625)
                    score += pt.weight * kernel
                    if bestDistSq <= 0.1225 {
                        inlierWeight += pt.weight
                    }
                }
                
                // i-b. Corner junction topology agreement
                for oc in obsCornersAR {
                    let wc = mapPt(oc)
                    if corners.contains(where: { simd_distance($0, wc) <= 0.50 }) {
                        score += 1.6
                    }
                }
                
                // ii. Portal agreement (Windows, Doors, Openings)
                for op in obsPortals {
                    let wp = mapPt(SIMD2<Float>(op.pos.x, op.pos.z))
                    var matched = false
                    for refP in portals {
                        let typeOk: Bool
                        switch op.kind {
                        case .window: typeOk = (refP.type == .window)
                        case .door: typeOk = (refP.type == .door || refP.type == .opening)
                        default: typeOk = false
                        }
                        if typeOk && simd_distance(wp, refP.pos) <= max(refP.width * 0.65, 0.75) {
                            matched = true
                            break
                        }
                    }
                    if matched {
                        score += 3.5
                        semanticHits += 1
                    }
                }
                
                // iii. Furniture occupation agreement
                for fp in obsFurnClusters {
                    let wp = mapPt(SIMD2<Float>(fp.pos.x, fp.pos.z))
                    var matchedFurn = false
                    for rf in furniture {
                        let d = Self.distanceToOrientedBox2D(pt: wp, center: rf.pos, halfW: rf.halfW + 0.35, halfD: rf.halfD + 0.35, rotY: rf.rotY)
                        if d <= 0.01 {
                            matchedFurn = true
                            break
                        }
                    }
                    if matchedFurn {
                        score += 2.8
                        semanticHits += 1
                    } else if !furniture.isEmpty {
                        score -= 0.75
                    }
                }
                
                // iv. Free-Space Ray Carving (strong penalty across solid plan walls without openings)
                let wallBlockPenalty: Float = isPlanMode ? 1.75 : 1.2
                for ray in clearRaySnapshot {
                    let rayOrig = mapPt(ray.origin)
                    let rayDir = rotDir(ray.dir)
                    let rayDist = ray.clearDist * s
                    var rayBlockedByWall = false
                    for ref in targets {
                        if let hitD = Self.raySegmentIntersection(origin: rayOrig, dir: rayDir, a: ref.start, b: ref.end) {
                            if hitD > 0.25 && hitD < rayDist - 0.40 {
                                let hitPt = rayOrig + rayDir * hitD
                                let isPortal = portals.contains { simd_distance($0.pos, hitPt) < ($0.width * 0.6 + 0.25) }
                                if !isPortal {
                                    rayBlockedByWall = true
                                    break
                                }
                            }
                        }
                    }
                    if rayBlockedByWall {
                        score -= wallBlockPenalty
                    } else if ray.atFurnitureHeight {
                        let midRay = rayOrig + rayDir * (rayDist * 0.5)
                        for rf in furniture where rf.heightAboveFloor >= 0.55 {
                            let d = Self.distanceToOrientedBox2D(pt: midRay, center: rf.pos, halfW: max(rf.halfW - 0.12, 0.1), halfD: max(rf.halfD - 0.12, 0.1), rotY: rf.rotY)
                            if d <= 0.0 {
                                score -= 0.45
                                break
                            }
                        }
                    }
                }
                
                // v. Automatic 360-degree indoor enclosure check (rejects exterior L/U courtyard voids)
                if targets.count >= 4 {
                    var enclosedRays = 0
                    for dir in compassRays8 {
                        for ref in targets {
                            if let d = Self.raySegmentIntersection(origin: camW, dir: dir, a: ref.start, b: ref.end),
                               d > 0.10 && d < maxSpan {
                                enclosedRays += 1
                                break
                            }
                        }
                    }
                    if enclosedRays < 5 {
                        score -= Float(5 - enclosedRays) * 1.45
                    } else if enclosedRays >= 7 {
                        score += 0.65
                    }
                }
                
                let inlierRatio = inlierWeight / totalWallWeight
                let lookW = rotDir(arForward)
                var facingName: String? = nil
                var minFaceDist: Float = .greatestFiniteMagnitude
                for ref in targets {
                    if let d = Self.raySegmentIntersection(origin: camW, dir: lookW, a: ref.start, b: ref.end), d < minFaceDist {
                        minFaceDist = d
                        facingName = ref.displayName
                    }
                }
                
                return PoseHyp(
                    yaw: yaw,
                    tx: tr.x,
                    tz: tr.y,
                    scale: s,
                    score: score,
                    wallInlierRatio: inlierRatio,
                    semanticMatches: semanticHits,
                    facingName: facingName
                )
            }
            
            func collectHypotheses(forScale s: Float) -> [PoseHyp] {
                var results: [PoseHyp] = []
                for yaw in candidateYaws {
                    let cosY = cos(yaw)
                    let sinY = sin(yaw)
                    func rotS(_ v: SIMD2<Float>) -> SIMD2<Float> {
                        let vs = v * s
                        return SIMD2<Float>(vs.x * cosY - vs.y * sinY, vs.x * sinY + vs.y * cosY)
                    }
                    func rotDir(_ v: SIMD2<Float>) -> SIMD2<Float> {
                        SIMD2<Float>(v.x * cosY - v.y * sinY, v.x * sinY + v.y * cosY)
                    }
                    
                    let rotCam = rotS(camPosAR)
                    let rotClusters = topClusters.map { (center: rotS($0.center), normal: rotDir($0.normal)) }
                    var candidateTrans: [SIMD2<Float>] = []
                    
                    func isStrictlyInsidePerimeter(_ camW: SIMD2<Float>) -> Bool {
                        if let g = grid {
                            return g.isStrictlyIndoors(camW)
                        }
                        return camW.x >= minB.x - 0.12 && camW.x <= maxB.x + 0.12 &&
                               camW.y >= minB.y - 0.12 && camW.y <= maxB.y + 0.12
                    }
                    
                    func matchesIndoorFace(obsNorm: SIMD2<Float>, ref: ReferenceWallTarget) -> Bool {
                        if ref.interiorNormalSide != 0 {
                            return simd_dot(obsNorm, ref.normal * ref.interiorNormalSide) > 0.85
                        }
                        return abs(simd_dot(obsNorm, ref.normal)) > 0.85
                    }
                    
                    // A. 2-Wall Corner Intersection (strictly indoor faces & interior perimeter only!)
                    if rotClusters.count >= 2 {
                        for i in 0..<rotClusters.count {
                            let cA = rotClusters[i]
                            for j in (i + 1)..<rotClusters.count {
                                let cB = rotClusters[j]
                                guard abs(cA.normal.x * cB.normal.y - cA.normal.y * cB.normal.x) > 0.35 else { continue }
                                let matchA = targets.filter { matchesIndoorFace(obsNorm: cA.normal, ref: $0) }
                                let matchB = targets.filter { matchesIndoorFace(obsNorm: cB.normal, ref: $0) }
                                
                                for rA in matchA {
                                    let sA: Float = rA.interiorNormalSide != 0 ? rA.interiorNormalSide : (simd_dot(cA.normal, rA.normal) >= 0 ? 1.0 : -1.0)
                                    let nA = rA.normal * sA
                                    let rhsA = rA.offset * sA - simd_dot(cA.center, nA)
                                    for rB in matchB where rB.id != rA.id {
                                        let sB: Float = rB.interiorNormalSide != 0 ? rB.interiorNormalSide : (simd_dot(cB.normal, rB.normal) >= 0 ? 1.0 : -1.0)
                                        let nB = rB.normal * sB
                                        let rhsB = rB.offset * sB - simd_dot(cB.center, nB)
                                        let det = nA.x * nB.y - nA.y * nB.x
                                        guard abs(det) > 0.35 else { continue }
                                        let tx = (rhsA * nB.y - rhsB * nA.y) / det
                                        let tz = (nA.x * rhsB - nB.x * rhsA) / det
                                        let camW = SIMD2<Float>(rotCam.x + tx, rotCam.y + tz)
                                        if isStrictlyInsidePerimeter(camW) {
                                            candidateTrans.append(SIMD2<Float>(tx, tz))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    // B. 1-Wall sliding fallback (strictly indoor faces & interior perimeter only!)
                    if candidateTrans.isEmpty {
                        let cA = rotClusters[0]
                        for rA in targets where matchesIndoorFace(obsNorm: cA.normal, ref: rA) {
                            let sA: Float = rA.interiorNormalSide != 0 ? rA.interiorNormalSide : (simd_dot(cA.normal, rA.normal) >= 0 ? 1.0 : -1.0)
                            let nA = rA.normal * sA
                            let perpShift = rA.offset * sA - simd_dot(cA.center, nA)
                            let steps = max(Int(rA.length / 0.5), 2)
                            for k in 0...steps {
                                let targetPt = rA.start + rA.tangent * (rA.length * (Float(k) / Float(steps)))
                                let alongShift = simd_dot(targetPt - cA.center, rA.tangent)
                                let tr = nA * perpShift + rA.tangent * alongShift
                                let camW = rotCam + tr
                                if isStrictlyInsidePerimeter(camW) {
                                    candidateTrans.append(tr)
                                }
                            }
                        }
                    }
                    
                    var uniqueTrans: [SIMD2<Float>] = []
                    for t in candidateTrans {
                        if !uniqueTrans.contains(where: { simd_distance($0, t) < 0.20 }) {
                            uniqueTrans.append(t)
                        }
                    }
                    
                    for tr in uniqueTrans {
                        results.append(evaluateHypothesis(yaw: yaw, tr: tr, s: s))
                    }
                }
                return results
            }
            
            // Pass 1: Rigid SE(2) at scale 1.0
            var allHypotheses = collectHypotheses(forScale: 1.0)
            allHypotheses.sort { $0.score > $1.score }
            
            // Pass 2: Similarity Sim(2) scale compensation when locating on a possibly mis-scaled plan
            let rigidBestRatio = allHypotheses.first?.wallInlierRatio ?? 0.0
            if isPlanMode && topClusters.count >= 2 && rigidBestRatio < 0.68 {
                let candidateScales: [Float] = [0.85, 0.91, 0.95, 1.05, 1.11, 1.18]
                for sCand in candidateScales {
                    let sHyps = collectHypotheses(forScale: sCand)
                    allHypotheses.append(contentsOf: sHyps)
                }
                allHypotheses.sort { $0.score > $1.score }
            }
            
            guard var best = allHypotheses.first, best.score > 0 else {
                DispatchQueue.main.async {
                    self.trackingStatusText = "Pan slowly across walls, doors & furniture..."
                }
                return
            }
            
            // Fine continuous local polish on top hypothesis (strictly staying indoors)
            let dt: Float = 0.06
            let dyaw: Float = 1.5 * .pi / 180.0
            let ds: Float = isPlanMode ? 0.025 : 0.0
            for dx in [-dt, 0, dt] {
                for dz in [-dt, 0, dt] {
                    for dr in [-dyaw, 0, dyaw] {
                        let candYaw = Self.normalizeAngle(best.yaw + dr)
                        let candTx = best.tx + dx
                        let candTz = best.tz + dz
                        let scCam = camPosAR * best.scale
                        let cY = cos(candYaw), sY = sin(candYaw)
                        let camW = SIMD2<Float>(scCam.x * cY - scCam.y * sY + candTx, scCam.x * sY + scCam.y * cY + candTz)
                        if let g = grid, !g.isStrictlyIndoors(camW) { continue }
                        let cand = evaluateHypothesis(
                            yaw: candYaw,
                            tr: SIMD2<Float>(candTx, candTz),
                            s: best.scale
                        )
                        if cand.score > best.score + 0.02 {
                            best = cand
                        }
                    }
                }
            }
            if ds > 0 {
                for sDelta in [-ds, ds] {
                    let candS = max(0.75, min(1.30, best.scale + sDelta))
                    let scCam = camPosAR * candS
                    let cY = cos(best.yaw), sY = sin(best.yaw)
                    let camW = SIMD2<Float>(scCam.x * cY - scCam.y * sY + best.tx, scCam.x * sY + scCam.y * cY + best.tz)
                    if let g = grid, !g.isStrictlyIndoors(camW) { continue }
                    let cand = evaluateHypothesis(yaw: best.yaw, tr: SIMD2<Float>(best.tx, best.tz), s: candS)
                    if cand.score > best.score + 0.04 {
                        best = cand
                    }
                }
            }
            
            // Find highest scoring distinct competitor
            let secondBest = allHypotheses.first { h in
                let posDiff = hypot(h.tx - best.tx, h.tz - best.tz)
                let angDiff = abs(Self.normalizeAngle(h.yaw - best.yaw))
                return posDiff > 0.90 || angDiff > (25.0 * .pi / 180.0)
            }
            let margin = secondBest.map { best.score - $0.score } ?? 10.0
            
            // STRICT CERTAINTY + UNIQUENESS GATE
            let hasSymmetryBreaker = (best.semanticMatches >= 1 && margin >= 1.1) || (margin >= 2.2) || (secondBest == nil)
            let isConfident = hasCorner && best.wallInlierRatio >= 0.60 && hasSymmetryBreaker
            
            if isConfident {
                if let prev = self.lastBestCandidate {
                    let posDelta = hypot(prev.tx - best.tx, prev.tz - best.tz)
                    let angDelta = abs(Self.normalizeAngle(prev.angle - best.yaw))
                    if posDelta < 0.50 && angDelta < (16.0 * .pi / 180.0) {
                        self.consistentCandidateCount += 1
                    } else {
                        self.consistentCandidateCount = 1
                    }
                } else {
                    self.consistentCandidateCount = 1
                }
                self.lastBestCandidate = (best.yaw, best.tx, best.tz, best.scale)
                
                if self.consistentCandidateCount >= 2 {
                    self.transformLock.lock()
                    self.alignmentAngle = best.yaw
                    self.alignmentOffset = SIMD3<Float>(best.tx, 0, best.tz)
                    self.effectiveScale = best.scale
                    self.transformLock.unlock()
                    
                    let prefix = isPlanMode ? "Plan" : "Room"
                    let landmarkNote = best.semanticMatches > 0 ? " + \(best.semanticMatches) landmarks" : ""
                    let scaleNote = abs(best.scale - 1.0) >= 0.03 ? String(format: " (%.0f%% scale)", best.scale * 100.0) : ""
                    DispatchQueue.main.async {
                        if !self.isAutoLocalized {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                        self.isCalibrated = true
                        self.isAutoLocalized = true
                        self.localizationConfidence = best.wallInlierRatio
                        self.lockedPlanScale = best.scale
                        self.localizedTargetName = best.facingName ?? "\(topClusters.count) walls"
                        self.trackingStatusText = "✓ Locked on \(prefix) (\(Int(best.wallInlierRatio * 100))%\(landmarkNote)\(scaleNote))"
                    }
                } else {
                    DispatchQueue.main.async {
                        self.localizationConfidence = 0.70
                        self.trackingStatusText = "Verifying corner & landmarks..."
                    }
                }
            } else {
                self.consistentCandidateCount = 0
                DispatchQueue.main.async {
                    self.localizationConfidence = min(best.wallInlierRatio * 0.5, 0.5)
                    if !hasCorner {
                        self.trackingStatusText = "1 wall seen — pan to a corner, furniture, or window"
                    } else if !hasSymmetryBreaker {
                        self.trackingStatusText = "Ambiguous corner — look at a window, door, or furniture"
                    } else {
                        self.trackingStatusText = "Scanning room (\(Int(best.wallInlierRatio * 100))%)..."
                    }
                }
            }
        }
    }
    
    // MARK: - Continuous Post-Lock Pose Refinement (Prevents VIO Drift Across Rooms)
    
    private func triggerContinuousPoseRefinement(camPosAR: SIMD2<Float>) {
        let targets = referenceTargets
        guard !targets.isEmpty else { return }
        let grid = indoorGrid
        
        let vPlaneSnapshots: [(transform: simd_float4x4, width: Float)] = verticalPlaneAnchors.values.map { plane in
            let w: Float
            if #available(iOS 16.0, *) { w = max(plane.planeExtent.width, 0.35) }
            else { w = max(plane.extent.x, 0.35) }
            return (transform: plane.transform, width: w)
        }
        let raySnapshot = Array(observedRayPoints.suffix(25))
        
        transformLock.lock()
        let curYaw = alignmentAngle
        let curOff = alignmentOffset
        let curScale = effectiveScale
        transformLock.unlock()
        
        solverQueue.async { [weak self] in
            guard let self = self else { return }
            var pts: [(pos: SIMD2<Float>, normal: SIMD2<Float>, weight: Float)] = []
            for vp in vPlaneSnapshots {
                let wt = vp.transform
                let c = SIMD2<Float>(wt.columns.3.x, wt.columns.3.z)
                let col1 = SIMD2<Float>(wt.columns.1.x, wt.columns.1.z)
                guard simd_length(col1) > 0.2 else { continue }
                var norm = simd_normalize(col1)
                if simd_dot(norm, camPosAR - c) < 0 { norm = -norm }
                pts.append((c, norm, 2.0))
            }
            for rp in raySnapshot {
                pts.append((rp.pos, rp.normal, 1.0))
            }
            guard pts.count >= 3 else { return }
            
            func localScore(yaw: Float, tx: Float, tz: Float, sc: Float) -> Float {
                let c = cos(yaw), s = sin(yaw)
                let camSX = camPosAR.x * sc, camSZ = camPosAR.y * sc
                let camW = SIMD2<Float>(camSX * c - camSZ * s + tx, camSX * s + camSZ * c + tz)
                if let g = grid, !g.isStrictlyIndoors(camW) { return -Float.greatestFiniteMagnitude }
                var total: Float = 0.0
                for p in pts {
                    let px = p.pos.x * sc, pz = p.pos.y * sc
                    let wp = SIMD2<Float>(px * c - pz * s + tx, px * s + pz * c + tz)
                    let wn = SIMD2<Float>(p.normal.x * c - p.normal.y * s, p.normal.x * s + p.normal.y * c)
                    var bestD: Float = .greatestFiniteMagnitude
                    for ref in targets {
                        let sideSign: Float
                        if ref.interiorNormalSide != 0 {
                            guard simd_dot(wn, ref.normal * ref.interiorNormalSide) > 0.80 else { continue }
                            sideSign = ref.interiorNormalSide
                        } else {
                            guard abs(simd_dot(wn, ref.normal)) > 0.80 else { continue }
                            sideSign = simd_dot(camW - ref.center, ref.normal) >= 0 ? 1.0 : -1.0
                        }
                        let faceShift = ref.normal * (sideSign * min(ref.thickness * 0.5, 0.14))
                        let dSq = Self.pointToSegmentDistanceSquared(p: wp, a: ref.start + faceShift, b: ref.end + faceShift)
                        bestD = min(bestD, dSq)
                    }
                    total += p.weight / (1.0 + bestD / 0.04)
                }
                return total
            }
            
            let baseScore = localScore(yaw: curYaw, tx: curOff.x, tz: curOff.z, sc: curScale)
            var bestY = curYaw, bestX = curOff.x, bestZ = curOff.z, bestScore = baseScore
            
            let stepT: Float = 0.05
            let stepR: Float = 1.5 * .pi / 180.0
            for dx in [-stepT, 0, stepT] {
                for dz in [-stepT, 0, stepT] {
                    for dr in [-stepR, 0, stepR] {
                        let sc = localScore(yaw: curYaw + dr, tx: curOff.x + dx, tz: curOff.z + dz, sc: curScale)
                        if sc > bestScore {
                            bestScore = sc
                            bestY = Self.normalizeAngle(curYaw + dr)
                            bestX = curOff.x + dx
                            bestZ = curOff.z + dz
                        }
                    }
                }
            }
            
            if bestScore > baseScore + 0.08 {
                self.transformLock.lock()
                self.alignmentAngle = bestY
                self.alignmentOffset = SIMD3<Float>(curOff.x * 0.45 + bestX * 0.55, 0, curOff.z * 0.45 + bestZ * 0.55)
                self.transformLock.unlock()
            }
        }
    }
    
    // MARK: - Live Discrepancy Detection (Missing Objects & New Objects)
    
    private func evaluateLiveDiscrepancies(frame: ARFrame, camPosAR: SIMD3<Float>, yaw: Float, offset: SIMD3<Float>, curScale: Float) {
        guard #available(iOS 14.0, *),
              let depthBuf = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap else { return }
        
        CVPixelBufferLockBaseAddress(depthBuf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuf, .readOnly) }
        let dW = CVPixelBufferGetWidth(depthBuf)
        let dH = CVPixelBufferGetHeight(depthBuf)
        guard dW > 16, dH > 16, let dBase = CVPixelBufferGetBaseAddress(depthBuf) else { return }
        let dFloats = dBase.assumingMemoryBound(to: Float32.self)
        
        let imgRes = frame.camera.imageResolution
        guard imgRes.width > 0 && imgRes.height > 0 else { return }
        let scaleX = Float(dW) / Float(imgRes.width)
        let scaleY = Float(dH) / Float(imgRes.height)
        let K = frame.camera.intrinsics
        let fx = K.columns.0.x * scaleX
        let fy = K.columns.1.y * scaleY
        let cx = K.columns.2.x * scaleX
        let cy = K.columns.2.y * scaleY
        guard fx > 1 && fy > 1 else { return }
        
        let camT = frame.camera.transform
        let invCamT = simd_inverse(camT)
        let cosY = cos(-yaw)
        let sinY = sin(-yaw)
        
        func roomToAR(_ rx: Float, _ ry: Float, _ rz: Float) -> SIMD3<Float> {
            let invS = 1.0 / max(curScale, 0.2)
            let dx = (rx - offset.x) * invS
            let dz = (rz - offset.z) * invS
            let ax = dx * cosY - dz * sinY
            let az = dx * sinY + dz * cosY
            let ay = estimatedFloorY + max(ry - roomFloorY, 0.25)
            return SIMD3<Float>(ax, ay, az)
        }
        
        func arToRoom(_ ax: Float, _ ay: Float, _ az: Float) -> SIMD3<Float> {
            let cF = cos(yaw)
            let sF = sin(yaw)
            let sx = ax * curScale
            let sz = az * curScale
            let rx = sx * cF - sz * sF + offset.x
            let rz = sx * sF + sz * cF + offset.z
            let ry = roomFloorY + max(ay - estimatedFloorY, 0.0)
            return SIMD3<Float>(rx, ry, rz)
        }
        
        let camScaledX = camPosAR.x * curScale
        let camScaledZ = camPosAR.z * curScale
        let camRoomX = camScaledX * cos(yaw) - camScaledZ * sin(yaw) + offset.x
        let camRoomZ = camScaledX * sin(yaw) + camScaledZ * cos(yaw) + offset.z
        let camRoomXZ = SIMD2<Float>(camRoomX, camRoomZ)
        
        // A. Check for MISSING expected furniture directly in front of the camera
        for rf in referenceFurniture where !dismissedMissingIds.contains(rf.object.id) {
            let obj = rf.object
            guard max(obj.width, obj.depth) >= 0.40 && obj.height >= 0.30 else { continue }
            
            let objCenterAR = roomToAR(rf.pos.x, obj.position.y, rf.pos.y)
            let camDist = simd_distance(camPosAR, objCenterAR)
            guard camDist >= 0.90 && camDist <= 4.0 else { continue }
            
            // Ensure no wall blocks the sightline between camera and object
            let toObj = rf.pos - camRoomXZ
            let toObjLen = simd_length(toObj)
            guard toObjLen > 0.5 else { continue }
            let toObjDir = toObj / toObjLen
            var wallBlocked = false
            for wall in referenceTargets {
                if let hd = Self.raySegmentIntersection(origin: camRoomXZ, dir: toObjDir, a: wall.start, b: wall.end),
                   hd > 0.2 && hd < toObjLen - 0.35 {
                    wallBlocked = true
                    break
                }
            }
            if wallBlocked { continue }
            
            // Project center into camera frame & check depth
            let localPt = simd_mul(invCamT, SIMD4<Float>(objCenterAR, 1.0))
            let expectedDepth: Float = -localPt.z
            guard expectedDepth >= 0.85 else { continue }
            guard abs(localPt.x / expectedDepth) < 0.30 && abs(localPt.y / expectedDepth) < 0.25 else { continue }
            
            let uCenter = Int(cx + fx * (localPt.x / expectedDepth))
            let vCenter = Int(cy - fy * (localPt.y / expectedDepth))
            guard uCenter >= 6 && uCenter < dW - 6 && vCenter >= 6 && vCenter < dH - 6 else { continue }
            
            let objHalfExtent: Float = max(rf.halfW, rf.halfD)
            let seeThroughThresh: Float = expectedDepth + objHalfExtent + 0.35
            let hitObjThresh: Float = objHalfExtent + 0.25
            let offsets: [(Int, Int)] = [(0, 0), (-5, 0), (5, 0), (0, -4), (0, 4)]
            var seeThroughCount = 0
            var hitObjectCount = 0
            for (du, dv) in offsets {
                let dMeas: Float = dFloats[(vCenter + dv) * dW + (uCenter + du)]
                guard dMeas.isFinite && dMeas > 0.3 else { continue }
                if dMeas > seeThroughThresh {
                    seeThroughCount += 1
                } else if abs(dMeas - expectedDepth) <= hitObjThresh {
                    hitObjectCount += 1
                }
            }
            
            if seeThroughCount >= 4 && hitObjectCount == 0 {
                let count = (missingStrikes[obj.id] ?? 0) + 1
                missingStrikes[obj.id] = count
                if count >= 4 {
                    let disc = RoomDiscrepancy(
                        kind: .missingObject(obj),
                        title: "Missing Item Detected",
                        subtitle: "\"\(obj.displayName)\" wasn't found where expected in the room."
                    )
                    DispatchQueue.main.async {
                        if self.activeDiscrepancy == nil {
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            self.activeDiscrepancy = disc
                        }
                    }
                    return
                }
            } else if hitObjectCount >= 2 {
                missingStrikes[obj.id] = 0
            }
        }
        
        // B. Check for NEW unexpected interior objects (from elevated planes, mesh furniture, or depth)
        var newCandidates: [(posAR: SIMD3<Float>, name: String, cat: ObjectCategory, dims: SIMD3<Float>)] = []
        for ext in meshExtracts.values {
            for lm in ext.landmarks {
                if case let .furniture(label, cat, w, d, h) = lm.kind {
                    if simd_distance(camPosAR, lm.pos) <= 3.8 {
                        newCandidates.append((lm.pos, label, cat, SIMD3<Float>(w, h, d)))
                    }
                }
            }
        }
        for dob in observedDepthObstacles {
            if simd_distance(camPosAR, dob.pos) <= 3.5 {
                let h = max(dob.pos.y - estimatedFloorY, 0.55)
                newCandidates.append((dob.pos, "New Object", .generic, SIMD3<Float>(0.75, h, 0.75)))
            }
        }
        
        for cand in newCandidates {
            let rPos = arToRoom(cand.posAR.x, cand.posAR.y, cand.posAR.z)
            let rXZ = SIMD2<Float>(rPos.x, rPos.z)
            
            // Strictly inside room perimeter (away from walls/doors/windows by >= 0.50m)
            guard rXZ.x >= refMinBounds.x + 0.45 && rXZ.x <= refMaxBounds.x - 0.45 &&
                  rXZ.y >= refMinBounds.y + 0.45 && rXZ.y <= refMaxBounds.y - 0.45 else { continue }
            let nearWall = referenceTargets.contains { Self.pointToSegmentDistanceSquared(p: rXZ, a: $0.start, b: $0.end) < (0.50 * 0.50) }
            if nearWall { continue }
            let nearPortal = referencePortals.contains { simd_distance($0.pos, rXZ) < 0.65 }
            if nearPortal { continue }
            
            // Far from all existing saved furniture (>= 0.65m outside their bounding boxes)
            let matchesExisting = referenceFurniture.contains {
                Self.distanceToOrientedBox2D(pt: rXZ, center: $0.pos, halfW: $0.halfW + 0.60, halfD: $0.halfD + 0.60, rotY: $0.rotY) <= 0.0
            }
            if matchesExisting { continue }
            let wasDismissed = dismissedNewPositions.contains { simd_distance($0, rXZ) < 0.75 }
            if wasDismissed { continue }
            
            let cellKey = "\(Int((rXZ.x * 2.0).rounded()))_\(Int((rXZ.y * 2.0).rounded()))"
            var entry = newObjectStrikes[cellKey] ?? (count: 0, sumPos: .zero, name: cand.name, cat: cand.cat)
            entry.count += 1
            entry.sumPos += rPos
            if cand.cat != .generic {
                entry.name = cand.name
                entry.cat = cand.cat
            }
            newObjectStrikes[cellKey] = entry
            
            if entry.count >= 5 {
                let avgPos = entry.sumPos / Float(entry.count)
                let distM = simd_distance(camPosAR, cand.posAR)
                let disc = RoomDiscrepancy(
                    kind: .newObject(
                        roomPosition: SIMD3<Float>(avgPos.x, roomFloorY + cand.dims.y * 0.5, avgPos.z),
                        dimensions: cand.dims,
                        suggestedName: entry.name,
                        category: entry.cat
                    ),
                    title: "New Item Detected",
                    subtitle: "\(entry.name) spotted ~\(String(format: "%.1fm", distM)) ahead that isn't in your saved plan."
                )
                DispatchQueue.main.async {
                    if self.activeDiscrepancy == nil {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        self.activeDiscrepancy = disc
                    }
                }
                return
            }
        }
    }
    
    // MARK: - LiDAR Center Distance HUD Measurement
    
    private func measureCenterWallOrDepthDistance(frame: ARFrame, camPos: SIMD3<Float>) -> Float? {
        let query = frame.raycastQuery(from: CGPoint(x: 0.5, y: 0.5), allowing: .estimatedPlane, alignment: .vertical)
        if let hit = session.raycast(query).first {
            let hitPos = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
            let d = simd_distance(camPos, hitPos)
            if d > 0.25 && d < 12.0 { return d }
        }
        if #available(iOS 14.0, *), let depthBuffer = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap {
            CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }
            let w = CVPixelBufferGetWidth(depthBuffer)
            let h = CVPixelBufferGetHeight(depthBuffer)
            if let base = CVPixelBufferGetBaseAddress(depthBuffer) {
                let d = base.assumingMemoryBound(to: Float32.self)[(h / 2) * w + (w / 2)]
                if d > 0.25 && d < 12.0 && !d.isNaN { return d }
            }
        }
        return nil
    }
    
    // MARK: - Geometry Helpers
    
    private static func mergeLandmark(_ lm: ObservedLandmark, into list: inout [ObservedLandmark], radius: Float) {
        let p2 = SIMD2<Float>(lm.pos.x, lm.pos.z)
        for i in 0..<list.count {
            let ep = SIMD2<Float>(list[i].pos.x, list[i].pos.z)
            if simd_distance(ep, p2) < radius {
                list[i].pos = (list[i].pos + lm.pos) * 0.5
                list[i].timestamp = lm.timestamp
                return
            }
        }
        list.append(lm)
    }
    
    private static func distanceToOrientedBox2D(pt: SIMD2<Float>, center: SIMD2<Float>, halfW: Float, halfD: Float, rotY: Float) -> Float {
        let d = pt - center
        let c = cos(-rotY)
        let s = sin(-rotY)
        let lx = d.x * c - d.y * s
        let lz = d.x * s + d.y * c
        let dx = max(abs(lx) - halfW, 0.0)
        let dz = max(abs(lz) - halfD, 0.0)
        return hypot(dx, dz)
    }
    
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
        if t1 > 0.1 && t2 >= -0.05 && t2 <= 1.05 { return t1 }
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
                        ? "Look at walls, doorways & furniture to locate..."
                        : "Pan across a corner, furniture & window to locate..."
                }
            case .notAvailable:
                self.trackingStatusText = "Tracking Unavailable"
            case .limited(let reason):
                switch reason {
                case .initializing: self.trackingStatusText = "Initializing LiDAR..."
                case .excessiveMotion: self.trackingStatusText = "Slow Down Device Motion"
                case .insufficientFeatures: self.trackingStatusText = "Point at walls, furniture or windows"
                case .relocalizing: self.trackingStatusText = "Relocalizing..."
                @unknown default: self.trackingStatusText = "Tracking Limited"
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
