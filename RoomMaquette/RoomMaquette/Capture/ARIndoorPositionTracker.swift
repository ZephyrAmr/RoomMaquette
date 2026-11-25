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
    public var displayName: String
    public var dominantColor: SurfaceColor? = nil
    
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
    @Published public var liveCenterColor: SurfaceColor? = nil
    @Published public var learnedColorsCount: Int = 0
    @Published public var activeDiscrepancy: RoomDiscrepancy? = nil
    
    public var session: ARSession
    public var room: MaquetteRoom?
    
    // MARK: - Internal Spatial Types
    
    private struct ObservedWallPoint {
        var pos: SIMD2<Float>
        var normal: SIMD2<Float>
        var weight: Float
        var timestamp: TimeInterval
        var color: SurfaceColor? = nil
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
        var color: SurfaceColor? = nil
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
    
    // Rigid SE(2) Transform: AR space -> Reference space (Room or Imported Plan)
    private var alignmentAngle: Float = 0.0
    private var alignmentOffset: SIMD3<Float> = .zero
    private let transformLock = NSLock()
    
    // Reference Geometry built from MaquetteRoom
    private var referenceTargets: [ReferenceWallTarget] = []
    private var referencePortals: [RefPortal] = []
    private var referenceFurniture: [RefFurniture] = []
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
    private var consistentCandidateCount: Int = 0
    private var lastBestCandidate: (angle: Float, tx: Float, tz: Float)? = nil
    
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
        }
        
        transformLock.lock()
        self.alignmentAngle = 0.0
        self.alignmentOffset = .zero
        transformLock.unlock()
        
        // IMPORTANT: Keep position nil until localization is genuinely confirmed!
        self.currentPosition = nil
        self.currentHeading = nil
        self.isCalibrated = false
        self.isAutoLocalized = false
        self.localizationConfidence = 0.0
        self.consistentCandidateCount = 0
        self.lastBestCandidate = nil
        self.localizedTargetName = nil
        self.targetDistanceMeters = nil
        self.observedWallCount = 0
        self.observedLandmarkCount = 0
        self.activeDiscrepancy = nil
        
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
    
    /// Samples live camera colors onto visible walls, doors, and furniture once localized
    @discardableResult
    public func captureVisibleColors(into room: inout MaquetteRoom) -> Int {
        guard isAutoLocalized, let frame = session.currentFrame else { return 0 }
        transformLock.lock()
        let yaw = alignmentAngle
        let offset = alignmentOffset
        transformLock.unlock()
        
        let cosInv = cos(-yaw)
        let sinInv = sin(-yaw)
        func toAR(_ rp: SIMD3<Float>) -> SIMD3<Float> {
            let dx = rp.x - offset.x
            let dz = rp.z - offset.z
            let ax = dx * cosInv - dz * sinInv
            let az = dx * sinInv + dz * cosInv
            let ay = estimatedFloorY + max(rp.y - roomFloorY, 0.25)
            return SIMD3<Float>(ax, ay, az)
        }
        
        var updatedCount = 0
        for i in 0..<room.walls.count {
            let arPt = toAR(room.walls[i].position)
            if let col = CameraColorSampler.sampleColor(in: frame, atWorldPoint: arPt, patchRadiusPx: 10) {
                room.walls[i].dominantColor = room.walls[i].dominantColor?.blended(with: col) ?? col
                updatedCount += 1
            }
        }
        for i in 0..<room.doors.count {
            let arPt = toAR(room.doors[i].position)
            if let col = CameraColorSampler.sampleColor(in: frame, atWorldPoint: arPt, patchRadiusPx: 8) {
                room.doors[i].dominantColor = room.doors[i].dominantColor?.blended(with: col) ?? col
                updatedCount += 1
            }
        }
        for i in 0..<room.objects.count {
            let arPt = toAR(room.objects[i].position)
            if let col = CameraColorSampler.sampleColor(in: frame, atWorldPoint: arPt, patchRadiusPx: 8) {
                room.objects[i].dominantColor = room.objects[i].dominantColor?.blended(with: col) ?? col
                updatedCount += 1
            }
        }
        if updatedCount > 0 {
            learnedColorsCount += updatedCount
            updateRoom(room)
        }
        return updatedCount
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
        self.observedWallCount = 0
        self.observedLandmarkCount = 0
        self.activeDiscrepancy = nil
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
        
        // 1. Live center LiDAR/vertical distance + center RGB swatch for crosshair HUD
        if frameCount % 3 == 0 {
            let frontDist = measureCenterWallOrDepthDistance(frame: frame, camPos: rawPos)
            let centerCol = CameraColorSampler.sampleCenterColor(in: frame, radiusPx: 12)
            DispatchQueue.main.async {
                self.targetDistanceMeters = frontDist
                if let c = centerCol { self.liveCenterColor = c }
            }
        }
        
        // 2. Sample vertical walls + dense LiDAR depth (for furniture obstacles & clear-air rays)
        if frameCount % 4 == 0 {
            if !isAutoLocalized {
                sampleHorizontalVerticalWallFan(frame: frame, camPos: rawPos)
            }
            sampleSceneDepthFeatures(frame: frame, camPos: rawPos)
        }
        
        // 3. Solve rigid SE(2) pose until locked with high certainty + uniqueness
        let now = Date().timeIntervalSince1970
        if !isAutoLocalized && !isSolving && !referenceTargets.isEmpty && (now - lastSolveTime) > 0.38 {
            lastSolveTime = now
            triggerLocalizationSolve(camPosAR: SIMD2<Float>(rawPos.x, rawPos.z), arForward: normARForward)
        }
        
        // 4. Only publish position & heading ONCE genuinely localized (never show misleading guesses!)
        if isAutoLocalized {
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
            
            // 5. Discrepancy Detection (Missing items & New items in the room)
            if activeDiscrepancy == nil && (!isLocatingOnImportedPlan || !referenceFurniture.isEmpty) && (now - lastDiscrepancyCheckTime) > 0.40 {
                lastDiscrepancyCheckTime = now
                evaluateLiveDiscrepancies(frame: frame, camPosAR: rawPos, yaw: yaw, offset: offset)
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
        
        if usePlanSpace, let plan = room.importedPlan, !plan.vectorLines.isEmpty {
            for (idx, line) in plan.vectorLines.enumerated() {
                if let t = makeReferenceTarget(p1: SIMD2<Float>(line.startX, line.startZ),
                                               p2: SIMD2<Float>(line.endX, line.endZ),
                                               name: "Plan Wall #\(idx + 1)") {
                    targets.append(t)
                }
            }
        } else {
            for (idx, wall) in room.walls.enumerated() {
                let s = wall.startPoint2D
                let e = wall.endPoint2D
                if let t = makeReferenceTarget(p1: SIMD2<Float>(Float(s.x), Float(s.y)),
                                               p2: SIMD2<Float>(Float(e.x), Float(e.y)),
                                               name: "\(wall.displayName) #\(idx + 1)",
                                               dominantColor: wall.dominantColor) {
                    targets.append(t)
                }
            }
        }
        self.referenceTargets = targets
        
        // Floor Y in room coordinates
        if let firstWall = room.walls.first {
            let floorEstimates = room.walls.map { $0.position.y - $0.height * 0.5 }
            self.roomFloorY = floorEstimates.reduce(0, +) / Float(max(floorEstimates.count, 1))
            _ = firstWall
        } else {
            self.roomFloorY = room.boundingBox.min.y
        }
        
        // Portals (Windows, Doors, Openings)
        var portals: [RefPortal] = []
        let align = room.importedPlan?.alignment
        func mapToActive(_ pos: SIMD3<Float>) -> SIMD2<Float> {
            if usePlanSpace, let al = align {
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
                rotY: obj.rotationY + (usePlanSpace ? (align?.rotationAngle ?? 0) : 0),
                heightAboveFloor: max(obj.height, 0.35)
            ))
        }
        self.referenceFurniture = furn
        
        // Bounding Envelope
        if targets.isEmpty {
            refMinBounds = SIMD2<Float>(-5, -5)
            refMaxBounds = SIMD2<Float>(5, 5)
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
        }
    }
    
    private func makeReferenceTarget(p1: SIMD2<Float>, p2: SIMD2<Float>, name: String, dominantColor: SurfaceColor? = nil) -> ReferenceWallTarget? {
        let diff = p2 - p1
        let len = simd_length(diff)
        guard len >= 0.35 else { return nil }
        let tangent = diff / len
        let normal = SIMD2<Float>(-tangent.y, tangent.x)
        return ReferenceWallTarget(
            start: p1,
            end: p2,
            tangent: tangent,
            normal: normal,
            offset: simd_dot(p1, normal),
            angle: atan2(normal.y, normal.x),
            displayName: name,
            dominantColor: dominantColor
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
            let sampledCol = CameraColorSampler.sampleColor(in: frame, atWorldPoint: hp3, patchRadiusPx: 8)
            
            addObservedRayPoint(ObservedWallPoint(pos: hitXZ, normal: norm2, weight: 1.0, timestamp: now, color: sampledCol))
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
                        let col = CameraColorSampler.sampleColor(in: frame, atWorldPoint: wp, patchRadiusPx: 6)
                        let lm = ObservedLandmark(
                            pos: wp,
                            kind: .furniture(label: "Object", category: .generic, estWidth: 0.65, estDepth: 0.65, estHeight: hAboveFloor),
                            timestamp: now,
                            color: col
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
            
            // 3. Candidate Yaws aligning dominant observed normal to reference normals
            var refNormals: [SIMD2<Float>] = []
            for t in targets {
                refNormals.append(t.normal)
                refNormals.append(-t.normal)
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
                var score: Float
                var wallInlierRatio: Float
                var semanticMatches: Int
                var facingName: String?
            }
            var allHypotheses: [PoseHyp] = []
            let totalWallWeight = max(obsWalls.reduce(Float(0)) { $0 + $1.weight }, 1.0)
            
            // 4. Generate & Score Candidate Transforms
            for yaw in candidateYaws {
                let cosY = cos(yaw)
                let sinY = sin(yaw)
                func rot(_ v: SIMD2<Float>) -> SIMD2<Float> {
                    SIMD2<Float>(v.x * cosY - v.y * sinY, v.x * sinY + v.y * cosY)
                }
                
                let rotCam = rot(camPosAR)
                let rotClusters = topClusters.map { (center: rot($0.center), normal: rot($0.normal)) }
                let rotWalls = obsWalls.map { (pos: rot($0.pos), normal: rot($0.normal), weight: $0.weight, color: $0.color) }
                let rotPortals = obsPortals.map { (pos: rot(SIMD2<Float>($0.pos.x, $0.pos.z)), kind: $0.kind) }
                let rotFurn = obsFurnClusters.map { (pos: rot(SIMD2<Float>($0.pos.x, $0.pos.z)), color: $0.color) }
                let rotClearRays = clearRaySnapshot.map { (origin: rot($0.origin), dir: rot($0.dir), dist: $0.clearDist, furnH: $0.atFurnitureHeight) }
                
                var candidateTrans: [SIMD2<Float>] = []
                
                // A. 2-Wall Corner Intersection (non-parallel pairs)
                if rotClusters.count >= 2 {
                    for i in 0..<rotClusters.count {
                        let cA = rotClusters[i]
                        for j in (i + 1)..<rotClusters.count {
                            let cB = rotClusters[j]
                            guard abs(cA.normal.x * cB.normal.y - cA.normal.y * cB.normal.x) > 0.35 else { continue }
                            let matchA = targets.filter { abs(simd_dot(cA.normal, $0.normal)) > 0.85 }
                            let matchB = targets.filter { abs(simd_dot(cB.normal, $0.normal)) > 0.85 }
                            
                            for rA in matchA {
                                let sA: Float = simd_dot(cA.normal, rA.normal) >= 0 ? 1.0 : -1.0
                                let nA = rA.normal * sA
                                let rhsA = rA.offset * sA - simd_dot(cA.center, nA)
                                for rB in matchB where rB.id != rA.id {
                                    let sB: Float = simd_dot(cB.normal, rB.normal) >= 0 ? 1.0 : -1.0
                                    let nB = rB.normal * sB
                                    let rhsB = rB.offset * sB - simd_dot(cB.center, nB)
                                    let det = nA.x * nB.y - nA.y * nB.x
                                    guard abs(det) > 0.35 else { continue }
                                    let tx = (rhsA * nB.y - rhsB * nA.y) / det
                                    let tz = (nA.x * rhsB - nB.x * rhsA) / det
                                    let camW = SIMD2<Float>(rotCam.x + tx, rotCam.y + tz)
                                    // STRICT inside-bounds check (never put user outside the room!)
                                    if camW.x >= minB.x - 0.30 && camW.x <= maxB.x + 0.30 &&
                                       camW.y >= minB.y - 0.30 && camW.y <= maxB.y + 0.30 {
                                        candidateTrans.append(SIMD2<Float>(tx, tz))
                                    }
                                }
                            }
                        }
                    }
                }
                
                // B. 1-Wall + Landmark / Sliding fallback (helps when looking at 1 wall + window/furniture)
                if candidateTrans.isEmpty {
                    let cA = rotClusters[0]
                    for rA in targets where abs(simd_dot(cA.normal, rA.normal)) > 0.88 {
                        let sA: Float = simd_dot(cA.normal, rA.normal) >= 0 ? 1.0 : -1.0
                        let nA = rA.normal * sA
                        let perpShift = rA.offset * sA - simd_dot(cA.center, nA)
                        let steps = max(Int(rA.length / 0.5), 2)
                        for k in 0...steps {
                            let targetPt = rA.start + rA.tangent * (rA.length * (Float(k) / Float(steps)))
                            let alongShift = simd_dot(targetPt - cA.center, rA.tangent)
                            let tr = nA * perpShift + rA.tangent * alongShift
                            let camW = rotCam + tr
                            if camW.x >= minB.x - 0.30 && camW.x <= maxB.x + 0.30 &&
                               camW.y >= minB.y - 0.30 && camW.y <= maxB.y + 0.30 {
                                candidateTrans.append(tr)
                            }
                        }
                    }
                }
                
                // Deduplicate translations within 0.20m
                var uniqueTrans: [SIMD2<Float>] = []
                for t in candidateTrans {
                    if !uniqueTrans.contains(where: { simd_distance($0, t) < 0.20 }) {
                        uniqueTrans.append(t)
                    }
                }
                
                for tr in uniqueTrans {
                    let camW = rotCam + tr
                    var score: Float = 0.0
                    var inlierWeight: Float = 0.0
                    var semanticHits = 0
                    
                    // i. Wall geometry + dominant wall color agreement
                    for pt in rotWalls {
                        let wp = pt.pos + tr
                        var bestDistSq: Float = .greatestFiniteMagnitude
                        var bestWallColor: SurfaceColor? = nil
                        for ref in targets {
                            guard abs(simd_dot(pt.normal, ref.normal)) > 0.78 else { continue }
                            let dSq = Self.pointToSegmentDistanceSquared(p: wp, a: ref.start, b: ref.end)
                            if dSq < bestDistSq {
                                bestDistSq = dSq
                                bestWallColor = ref.dominantColor
                            }
                        }
                        let kernel = 1.0 / (1.0 + bestDistSq / 0.0625)
                        score += pt.weight * kernel
                        if bestDistSq <= 0.1225 {
                            inlierWeight += pt.weight
                            if let obsC = pt.color, let refC = bestWallColor {
                                let dE = obsC.deltaE(to: refC)
                                if dE < 18.0 {
                                    score += 1.4
                                    semanticHits += 1
                                } else if dE > 42.0 {
                                    score -= 1.4
                                }
                            }
                        }
                    }
                    
                    // ii. Portal agreement (Windows, Doors, Openings) — huge symmetry breaker!
                    for op in rotPortals {
                        let wp = op.pos + tr
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
                    
                    // iii. Furniture occupation + dominant color agreement (Beds, Sofas, Tables, Desks)
                    for fp in rotFurn {
                        let wp = fp.pos + tr
                        var matchedFurn: RefFurniture? = nil
                        for rf in furniture {
                            let d = Self.distanceToOrientedBox2D(pt: wp, center: rf.pos, halfW: rf.halfW + 0.35, halfD: rf.halfD + 0.35, rotY: rf.rotY)
                            if d <= 0.01 {
                                matchedFurn = rf
                                break
                            }
                        }
                        if let mf = matchedFurn {
                            score += 2.8
                            semanticHits += 1
                            if let obsC = fp.color, let refC = mf.object.dominantColor {
                                let dE = obsC.deltaE(to: refC)
                                if dE < 22.0 {
                                    score += 2.4
                                    semanticHits += 1
                                } else if dE > 45.0 {
                                    score -= 1.4
                                }
                            }
                        } else if !furniture.isEmpty {
                            // Observed interior furniture where plan says open floor
                            score -= 0.75
                        }
                    }
                    
                    // iv. Free-Space Ray Carving (Penalize rays passing straight through solid walls or furniture!)
                    for ray in rotClearRays {
                        let rayOrig = ray.origin + tr
                        var rayBlockedByWall = false
                        for ref in targets {
                            if let hitD = Self.raySegmentIntersection(origin: rayOrig, dir: ray.dir, a: ref.start, b: ref.end) {
                                if hitD > 0.25 && hitD < ray.dist - 0.40 {
                                    // Check if hit falls inside a known door/opening/window
                                    let hitPt = rayOrig + ray.dir * hitD
                                    let isPortal = portals.contains { simd_distance($0.pos, hitPt) < ($0.width * 0.6 + 0.20) }
                                    if !isPortal {
                                        rayBlockedByWall = true
                                        break
                                    }
                                }
                            }
                        }
                        if rayBlockedByWall {
                            score -= 1.2
                        } else if ray.furnH {
                            // Check if ray at 0.4m..1.25m height passes right through a tall scanned furniture item
                            let midRay = rayOrig + ray.dir * (ray.dist * 0.5)
                            for rf in furniture where rf.heightAboveFloor >= 0.55 {
                                let d = Self.distanceToOrientedBox2D(pt: midRay, center: rf.pos, halfW: max(rf.halfW - 0.12, 0.1), halfD: max(rf.halfD - 0.12, 0.1), rotY: rf.rotY)
                                if d <= 0.0 {
                                    score -= 0.45
                                    break
                                }
                            }
                        }
                    }
                    
                    let inlierRatio = inlierWeight / totalWallWeight
                    let lookW = rot(arForward)
                    var facingName: String? = nil
                    var minFaceDist: Float = .greatestFiniteMagnitude
                    for ref in targets {
                        if let d = Self.raySegmentIntersection(origin: camW, dir: lookW, a: ref.start, b: ref.end), d < minFaceDist {
                            minFaceDist = d
                            facingName = ref.displayName
                        }
                    }
                    
                    allHypotheses.append(PoseHyp(
                        yaw: yaw,
                        tx: tr.x,
                        tz: tr.y,
                        score: score,
                        wallInlierRatio: inlierRatio,
                        semanticMatches: semanticHits,
                        facingName: facingName
                    ))
                }
            }
            
            allHypotheses.sort { $0.score > $1.score }
            guard let best = allHypotheses.first, best.score > 0 else {
                DispatchQueue.main.async {
                    self.trackingStatusText = "Pan slowly across walls, doors & furniture..."
                }
                return
            }
            
            // Find highest scoring distinct corner/rotation competitor
            let secondBest = allHypotheses.first { h in
                let posDiff = hypot(h.tx - best.tx, h.tz - best.tz)
                let angDiff = abs(Self.normalizeAngle(h.yaw - best.yaw))
                return posDiff > 0.90 || angDiff > (25.0 * .pi / 180.0)
            }
            let margin = secondBest.map { best.score - $0.score } ?? 10.0
            
            // STRICT CERTAINTY + UNIQUENESS GATE
            let hasSymmetryBreaker = (best.semanticMatches >= 1 && margin >= 1.1) || (margin >= 2.2) || (secondBest == nil)
            let isConfident = hasCorner && best.wallInlierRatio >= 0.62 && hasSymmetryBreaker
            
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
                self.lastBestCandidate = (best.yaw, best.tx, best.tz)
                
                if self.consistentCandidateCount >= 2 {
                    self.transformLock.lock()
                    self.alignmentAngle = best.yaw
                    self.alignmentOffset = SIMD3<Float>(best.tx, 0, best.tz)
                    self.transformLock.unlock()
                    
                    let prefix = isPlanMode ? "Plan" : "Room"
                    let landmarkNote = best.semanticMatches > 0 ? " + \(best.semanticMatches) landmarks" : ""
                    DispatchQueue.main.async {
                        if !self.isAutoLocalized {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                        self.isCalibrated = true
                        self.isAutoLocalized = true
                        self.localizationConfidence = best.wallInlierRatio
                        self.localizedTargetName = best.facingName ?? "\(topClusters.count) walls"
                        self.trackingStatusText = "✓ Locked on \(prefix) (\(Int(best.wallInlierRatio * 100))%\(landmarkNote))"
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
    
    // MARK: - Live Discrepancy Detection (Missing Objects & New Objects)
    
    private func evaluateLiveDiscrepancies(frame: ARFrame, camPosAR: SIMD3<Float>, yaw: Float, offset: SIMD3<Float>) {
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
            let dx = rx - offset.x
            let dz = rz - offset.z
            let ax = dx * cosY - dz * sinY
            let az = dx * sinY + dz * cosY
            let ay = estimatedFloorY + max(ry - roomFloorY, 0.25)
            return SIMD3<Float>(ax, ay, az)
        }
        
        func arToRoom(_ ax: Float, _ ay: Float, _ az: Float) -> SIMD3<Float> {
            let cF = cos(yaw)
            let sF = sin(yaw)
            let rx = ax * cF - az * sF + offset.x
            let rz = ax * sF + az * cF + offset.z
            let ry = roomFloorY + max(ay - estimatedFloorY, 0.0)
            return SIMD3<Float>(rx, ry, rz)
        }
        
        let camRoomX = camPosAR.x * cos(yaw) - camPosAR.z * sin(yaw) + offset.x
        let camRoomZ = camPosAR.x * sin(yaw) + camPosAR.z * cos(yaw) + offset.z
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
