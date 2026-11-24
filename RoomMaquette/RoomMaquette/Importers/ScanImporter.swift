import Foundation
import SceneKit
import simd

public enum ScanImportError: LocalizedError {
    case invalidFileFormat(String)
    case unreadableData
    case sceneParsingFailed
    case emptyScan
    
    public var errorDescription: String? {
        switch self {
        case .invalidFileFormat(let ext):
            return "Unsupported format: .\(ext). Supported formats include 3D scans (.usdz, .json, .obj) and floor plans (.png, .jpg, .svg, .pdf, .dxf)."
        case .unreadableData:
            return "Unable to read scan data from the selected file."
        case .sceneParsingFailed:
            return "Failed to parse 3D scene geometry from scan."
        case .emptyScan:
            return "The imported file contains no recognizable room geometry."
        }
    }
}

public class ScanImporter {
    
    public static func importScan(from url: URL) throws -> MaquetteRoom {
        let needsStopAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if needsStopAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let ext = url.pathExtension.lowercased()
        let fileName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        
        switch ext {
        case "usdz":
            return try importUSDZ(from: url, roomName: fileName)
            
        case "json":
            return try importJSON(from: url, roomName: fileName)
            
        case "obj":
            return try importOBJ(from: url, roomName: fileName)
            
        case "png", "jpg", "jpeg", "heic", "svg", "pdf", "dxf":
            let plan = try PlanImporter.import(from: url)
            return PlanImporter.createRoom(from: plan, name: fileName)
            
        default:
            throw ScanImportError.invalidFileFormat(ext)
        }
    }
    
    // MARK: - USDZ Scan Importer
    
    private enum USDZSemanticRole {
        case ignored
        case wall
        case door
        case window
        case opening
        case furniture(ObjectCategory, String)
    }
    
    private struct WorldTriangle {
        var v0: SIMD3<Float>
        var v1: SIMD3<Float>
        var v2: SIMD3<Float>
    }
    
    private static func classifyUSDZNodeName(_ rawName: String?) -> USDZSemanticRole? {
        guard let raw = rawName, !raw.isEmpty else { return nil }
        let name = raw.lowercased()
        
        if name.contains("floorplinth") || name.contains("floor") || name.contains("ceiling") ||
            name.contains("roof") || name.contains("camera") || name.contains("light") ||
            name.contains("plinth") || name.contains("grid") {
            return .ignored
        }
        if name.contains("wall") { return .wall }
        if name.contains("door") { return .door }
        if name.contains("window") { return .window }
        if name.contains("opening") || name.contains("archway") { return .opening }
        
        let catMap: [(String, ObjectCategory)] = [
            ("sofa", .sofa), ("couch", .sofa),
            ("bed", .bed),
            ("desk", .desk),
            ("table", .table),
            ("chair", .chair), ("stool", .chair),
            ("storage", .storage), ("cabinet", .storage), ("shelf", .storage), ("bookcase", .storage), ("wardrobe", .storage),
            ("refrigerator", .refrigerator), ("fridge", .refrigerator),
            ("stove", .stove),
            ("oven", .oven),
            ("sink", .sink),
            ("washer", .washerDryer), ("dryer", .washerDryer),
            ("toilet", .toilet),
            ("bathtub", .bathtub), ("tub", .bathtub),
            ("television", .television), ("tv", .television),
            ("plant", .plant)
        ]
        for (keyword, cat) in catMap {
            if name.contains(keyword) {
                return .furniture(cat, raw)
            }
        }
        return nil
    }
    
    private static func importUSDZ(from url: URL, roomName: String) throws -> MaquetteRoom {
        guard let data = try? Data(contentsOf: url) else {
            throw ScanImportError.unreadableData
        }
        
        // Copy to temporary location for SceneKit reading
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("import_\(UUID().uuidString).usdz")
        try? data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        guard let scene = try? SCNScene(url: tempURL, options: nil) else {
            throw ScanImportError.sceneParsingFailed
        }
        
        var walls: [WallSurface] = []
        var doors: [DoorSurface] = []
        var windows: [WindowSurface] = []
        var openings: [OpeningSurface] = []
        var objects: [FurnitureObject] = []
        var fallbackStructuralTriangles: [WorldTriangle] = []
        
        var minPt = SIMD3<Float>(.infinity, .infinity, .infinity)
        var maxPt = SIMD3<Float>(-.infinity, -.infinity, -.infinity)
        
        func expandSceneBounds(with verts: [SIMD3<Float>]) {
            for v in verts {
                minPt.x = min(minPt.x, v.x)
                minPt.y = min(minPt.y, v.y)
                minPt.z = min(minPt.z, v.z)
                maxPt.x = max(maxPt.x, v.x)
                maxPt.y = max(maxPt.y, v.y)
                maxPt.z = max(maxPt.z, v.z)
            }
        }
        
        func processNode(_ node: SCNNode, inheritedRole: USDZSemanticRole?) {
            let ownRole = classifyUSDZNodeName(node.name)
            if case .ignored = ownRole { return }
            let role = ownRole ?? inheritedRole
            
            // Determine if this node is a container whose children carry distinct semantic names
            let hasSemanticChild = node.childNodes.contains { child in
                if let r = classifyUSDZNodeName(child.name) {
                    if case .ignored = r { return false }
                    return true
                }
                return false
            }
            
            if let activeRole = role, !hasSemanticChild {
                // Collect geometry for this single semantic entity (from self and unnamed mesh children)
                let (worldVerts, worldTris) = collectSubtreeGeometry(from: node)
                if !worldVerts.isEmpty {
                    expandSceneBounds(with: worldVerts)
                    
                    switch activeRole {
                    case .ignored:
                        break
                    case .wall:
                        let extracted = buildWallsFromEntity(node: node, worldVerts: worldVerts, worldTris: worldTris)
                        walls.append(contentsOf: extracted)
                    case .door:
                        if let obb = computeOrientedBox2D(node: node, worldVerts: worldVerts) {
                            let isOpen = !(node.name?.lowercased().contains("closed") ?? false)
                            doors.append(DoorSurface(
                                id: UUID(),
                                dimensions: SIMD3<Float>(max(obb.length, 0.55), max(obb.height, 1.9), max(obb.thickness, 0.08)),
                                transform: makeTransformMatrix(center: obb.center, yaw: obb.yaw),
                                isOpen: isOpen
                            ))
                        }
                    case .window:
                        if let obb = computeOrientedBox2D(node: node, worldVerts: worldVerts) {
                            windows.append(WindowSurface(
                                id: UUID(),
                                dimensions: SIMD3<Float>(max(obb.length, 0.45), max(obb.height, 0.5), max(obb.thickness, 0.08)),
                                transform: makeTransformMatrix(center: obb.center, yaw: obb.yaw)
                            ))
                        }
                    case .opening:
                        if let obb = computeOrientedBox2D(node: node, worldVerts: worldVerts) {
                            openings.append(OpeningSurface(
                                id: UUID(),
                                dimensions: SIMD3<Float>(max(obb.length, 0.6), max(obb.height, 1.9), max(obb.thickness, 0.12)),
                                transform: makeTransformMatrix(center: obb.center, yaw: obb.yaw)
                            ))
                        }
                    case .furniture(let cat, let rawName):
                        if let obb = computeOrientedBox2D(node: node, worldVerts: worldVerts) {
                            let cleanName = rawName
                                .replacingOccurrences(of: "Object_", with: "")
                                .components(separatedBy: "_").first ?? cat.displayName
                            objects.append(FurnitureObject(
                                id: UUID(),
                                category: cat,
                                customName: cleanName.capitalized,
                                dimensions: SIMD3<Float>(max(obb.length, 0.3), max(obb.height, 0.3), max(obb.thickness, 0.3)),
                                transform: makeTransformMatrix(center: obb.center, yaw: obb.yaw)
                            ))
                        }
                    }
                    return
                }
            }
            
            // If node has unnamed geometry directly and no semantic role yet, record triangles for structural fallback
            if role == nil && node.geometry != nil {
                let (verts, tris) = extractNodeGeometry(node: node)
                if !verts.isEmpty {
                    expandSceneBounds(with: verts)
                    fallbackStructuralTriangles.append(contentsOf: tris)
                }
            }
            
            for child in node.childNodes {
                processNode(child, inheritedRole: role)
            }
        }
        
        for child in scene.rootNode.childNodes {
            processNode(child, inheritedRole: nil)
        }
        
        // Fallback 1: If no named wall nodes were found, slice walls out of any structural scene triangles
        if walls.isEmpty && !fallbackStructuralTriangles.isEmpty {
            walls = extractWallSegmentsFromMergedMesh(triangles: fallbackStructuralTriangles)
        }
        
        // Fallback 2: Bounding-box synthesis only if literally no wall geometry could be parsed
        if walls.isEmpty {
            if minPt.x >= maxPt.x || minPt.z >= maxPt.z {
                let (bMin, bMax) = scene.rootNode.boundingBox
                if bMin.x < bMax.x && bMin.z < bMax.z {
                    minPt = SIMD3<Float>(bMin.x, bMin.y, bMin.z)
                    maxPt = SIMD3<Float>(bMax.x, bMax.y, bMax.z)
                } else {
                    minPt = SIMD3<Float>(-2.0, 0.0, -2.5)
                    maxPt = SIMD3<Float>(2.0, 2.6, 2.5)
                }
            }
            
            let width = max(maxPt.x - minPt.x, 2.0)
            let depth = max(maxPt.z - minPt.z, 2.0)
            let height = max(maxPt.y - minPt.y, 2.5)
            let midX = (minPt.x + maxPt.x) / 2.0
            let midZ = (minPt.z + maxPt.z) / 2.0
            
            var nMat = matrix_identity_float4x4
            nMat.columns.3 = SIMD4<Float>(midX, height / 2.0, minPt.z, 1.0)
            walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(width, height, 0.15), transform: nMat))
            
            var sMat = matrix_identity_float4x4
            sMat.columns.3 = SIMD4<Float>(midX, height / 2.0, maxPt.z, 1.0)
            walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(width, height, 0.15), transform: sMat))
            
            let rot90 = simd_float4x4(
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-1, 0, 0, 0),
                SIMD4<Float>(maxPt.x, height / 2.0, midZ, 1)
            )
            walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(depth, height, 0.15), transform: rot90))
            
            let rotW90 = simd_float4x4(
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-1, 0, 0, 0),
                SIMD4<Float>(minPt.x, height / 2.0, midZ, 1)
            )
            walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(depth, height, 0.15), transform: rotW90))
        }
        
        return MaquetteRoom(
            id: UUID(),
            name: roomName.isEmpty ? "Imported USDZ Scan" : roomName,
            createdAt: Date(),
            modifiedAt: Date(),
            notes: "Imported from 3D USDZ scan (\(walls.count) walls recovered)",
            walls: walls,
            doors: doors,
            windows: windows,
            openings: openings,
            objects: objects,
            usdzData: data
        )
    }
    
    // MARK: - USDZ Geometry & Oriented Wall Recovery Helpers
    
    private struct OrientedBox2D {
        var center: SIMD3<Float>
        var length: Float    // Along yaw axis (local X)
        var thickness: Float // Perpendicular axis (local Z)
        var height: Float    // Vertical span (Y)
        var yaw: Float       // Rotation around Y: col0 = (cos(yaw), 0, sin(yaw))
    }
    
    private static func makeTransformMatrix(center: SIMD3<Float>, yaw: Float) -> simd_float4x4 {
        let c = cos(yaw)
        let s = sin(yaw)
        return simd_float4x4(
            SIMD4<Float>(c, 0, s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(-s, 0, c, 0),
            SIMD4<Float>(center.x, center.y, center.z, 1.0)
        )
    }
    
    private static func collectSubtreeGeometry(from root: SCNNode) -> ([SIMD3<Float>], [WorldTriangle]) {
        var allVerts: [SIMD3<Float>] = []
        var allTris: [WorldTriangle] = []
        
        func walk(_ node: SCNNode) {
            if case .ignored = classifyUSDZNodeName(node.name) { return }
            let (v, t) = extractNodeGeometry(node: node)
            allVerts.append(contentsOf: v)
            allTris.append(contentsOf: t)
            for child in node.childNodes {
                walk(child)
            }
        }
        walk(root)
        return (allVerts, allTris)
    }
    
    private static func extractNodeGeometry(node: SCNNode) -> ([SIMD3<Float>], [WorldTriangle]) {
        guard let geo = node.geometry else { return ([], []) }
        let worldMat = node.simdWorldTransform
        var worldVerts: [SIMD3<Float>] = []
        var worldTris: [WorldTriangle] = []
        
        if let vertexSource = geo.sources(for: .vertex).first {
            let localVerts = readVertices(from: vertexSource)
            worldVerts = localVerts.map { v in
                let w = simd_mul(worldMat, SIMD4<Float>(v.x, v.y, v.z, 1.0))
                return SIMD3<Float>(w.x, w.y, w.z)
            }
            
            for element in geo.elements {
                let indices = readIndices(from: element)
                if element.primitiveType == .triangles {
                    var i = 0
                    while i + 2 < indices.count {
                        let a = indices[i]
                        let b = indices[i + 1]
                        let c = indices[i + 2]
                        if a < worldVerts.count && b < worldVerts.count && c < worldVerts.count {
                            worldTris.append(WorldTriangle(v0: worldVerts[a], v1: worldVerts[b], v2: worldVerts[c]))
                        }
                        i += 3
                    }
                } else if element.primitiveType == .triangleStrip && indices.count >= 3 {
                    for i in 0..<(indices.count - 2) {
                        let a = indices[i]
                        let b = indices[i + 1]
                        let c = indices[i + 2]
                        if a < worldVerts.count && b < worldVerts.count && c < worldVerts.count {
                            if i % 2 == 0 {
                                worldTris.append(WorldTriangle(v0: worldVerts[a], v1: worldVerts[b], v2: worldVerts[c]))
                            } else {
                                worldTris.append(WorldTriangle(v0: worldVerts[b], v1: worldVerts[a], v2: worldVerts[c]))
                            }
                        }
                    }
                }
            }
        }
        
        // Fallback if vertex buffer couldn't be read directly: sample the 8 corners of node.boundingBox
        if worldVerts.isEmpty {
            let (bMin, bMax) = node.boundingBox
            if bMin.x < bMax.x || bMin.y < bMax.y || bMin.z < bMax.z {
                let xs = [bMin.x, bMax.x]
                let ys = [bMin.y, bMax.y]
                let zs = [bMin.z, bMax.z]
                for x in xs {
                    for y in ys {
                        for z in zs {
                            let w = simd_mul(worldMat, SIMD4<Float>(x, y, z, 1.0))
                            worldVerts.append(SIMD3<Float>(w.x, w.y, w.z))
                        }
                    }
                }
            }
        }
        
        return (worldVerts, worldTris)
    }
    
    private static func readVertices(from source: SCNGeometrySource) -> [SIMD3<Float>] {
        let count = source.vectorCount
        guard count > 0, source.componentsPerVector >= 3 else { return [] }
        let stride = max(source.dataStride, source.componentsPerVector * source.bytesPerComponent)
        let offset = source.dataOffset
        let bpc = source.bytesPerComponent
        let data = source.data
        
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            for i in 0..<count {
                let byteIdx = offset + i * stride
                guard byteIdx + 3 * bpc <= data.count else { break }
                if source.usesFloatComponents && bpc == 4 {
                    let x = base.loadUnaligned(fromByteOffset: byteIdx, as: Float.self)
                    let y = base.loadUnaligned(fromByteOffset: byteIdx + 4, as: Float.self)
                    let z = base.loadUnaligned(fromByteOffset: byteIdx + 8, as: Float.self)
                    if x.isFinite && y.isFinite && z.isFinite {
                        result.append(SIMD3<Float>(x, y, z))
                    }
                } else if source.usesFloatComponents && bpc == 8 {
                    let x = Float(base.loadUnaligned(fromByteOffset: byteIdx, as: Double.self))
                    let y = Float(base.loadUnaligned(fromByteOffset: byteIdx + 8, as: Double.self))
                    let z = Float(base.loadUnaligned(fromByteOffset: byteIdx + 16, as: Double.self))
                    if x.isFinite && y.isFinite && z.isFinite {
                        result.append(SIMD3<Float>(x, y, z))
                    }
                }
            }
        }
        return result
    }
    
    private static func readIndices(from element: SCNGeometryElement) -> [Int] {
        let indexCount: Int
        switch element.primitiveType {
        case .triangles:
            indexCount = element.primitiveCount * 3
        case .triangleStrip:
            indexCount = element.primitiveCount + 2
        default:
            return []
        }
        
        let bpi = element.bytesPerIndex
        let data = element.data
        guard indexCount > 0, bpi == 1 || bpi == 2 || bpi == 4 else { return [] }
        
        var indices: [Int] = []
        indices.reserveCapacity(indexCount)
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            for i in 0..<indexCount {
                let byteIdx = i * bpi
                guard byteIdx + bpi <= data.count else { break }
                if bpi == 2 {
                    indices.append(Int(base.loadUnaligned(fromByteOffset: byteIdx, as: UInt16.self)))
                } else if bpi == 4 {
                    indices.append(Int(base.loadUnaligned(fromByteOffset: byteIdx, as: UInt32.self)))
                } else {
                    indices.append(Int(base.loadUnaligned(fromByteOffset: byteIdx, as: UInt8.self)))
                }
            }
        }
        return indices
    }
    
    private static func buildWallsFromEntity(node: SCNNode, worldVerts: [SIMD3<Float>], worldTris: [WorldTriangle]) -> [WallSurface] {
        // First check if this is a clean thin slab (single wall) via 2D OBB
        if let obb = computeOrientedBox2D(node: node, worldVerts: worldVerts) {
            if obb.thickness <= 0.65 && obb.length >= 0.35 {
                let mat = makeTransformMatrix(center: obb.center, yaw: obb.yaw)
                return [WallSurface(
                    id: UUID(),
                    dimensions: SIMD3<Float>(obb.length, max(obb.height, 2.2), max(obb.thickness, 0.12)),
                    transform: mat
                )]
            }
        }
        
        // Otherwise, this wall node holds multiple merged walls (e.g. L-wall or entire RoomPlan .mesh Walls object)
        if !worldTris.isEmpty {
            let segmented = extractWallSegmentsFromMergedMesh(triangles: worldTris)
            if !segmented.isEmpty {
                return segmented
            }
        }
        
        if let obb = computeOrientedBox2D(node: node, worldVerts: worldVerts), obb.length >= 0.35 {
            let mat = makeTransformMatrix(center: obb.center, yaw: obb.yaw)
            return [WallSurface(
                id: UUID(),
                dimensions: SIMD3<Float>(obb.length, max(obb.height, 2.2), max(obb.thickness, 0.15)),
                transform: mat
            )]
        }
        return []
    }
    
    private static func computeOrientedBox2D(node: SCNNode, worldVerts: [SIMD3<Float>]) -> OrientedBox2D? {
        guard !worldVerts.isEmpty else { return nil }
        
        // Check if node itself has clean local bounds centered near local origin and a meaningful transform
        if let geo = node.geometry {
            let (bMin, bMax) = geo.boundingBox
            let lx = bMax.x - bMin.x
            let ly = bMax.y - bMin.y
            let lz = bMax.z - bMin.z
            let lcx = (bMin.x + bMax.x) * 0.5
            let lcz = (bMin.z + bMax.z) * 0.5
            let wt = node.simdWorldTransform
            let hasWorldRotation = abs(wt.columns.0.z) > 0.02 || abs(wt.columns.2.x) > 0.02 || wt.columns.0.x < 0.98
            let isThinOrLocalBox = (min(lx, lz) < 0.55) || hasWorldRotation
            if lx > 0.05 && lz > 0.05 && abs(lcx) < 0.25 && abs(lcz) < 0.25 && isThinOrLocalBox {
                let col0 = SIMD2<Float>(wt.columns.0.x, wt.columns.0.z)
                let col2 = SIMD2<Float>(wt.columns.2.x, wt.columns.2.z)
                let s0 = simd_length(col0)
                let s2 = simd_length(col2)
                if s0 > 1e-4 && s2 > 1e-4 {
                    let wLen = lx * s0
                    let wThick = lz * s2
                    let localCenter = SIMD4<Float>(lcx, (bMin.y + bMax.y) * 0.5, lcz, 1.0)
                    let wc = simd_mul(wt, localCenter)
                    let center = SIMD3<Float>(wc.x, wc.y, wc.z)
                    if wLen >= wThick {
                        let yaw = atan2(col0.y, col0.x)
                        return OrientedBox2D(center: center, length: wLen, thickness: wThick, height: ly, yaw: yaw)
                    } else {
                        let yaw = atan2(col2.y, col2.x)
                        return OrientedBox2D(center: center, length: wThick, thickness: wLen, height: ly, yaw: yaw)
                    }
                }
            }
        }
        
        // World-space minimum-area / PCA 2D oriented bounding box on vertices
        var minY: Float = .greatestFiniteMagnitude
        var maxY: Float = -.greatestFiniteMagnitude
        var meanX: Double = 0
        var meanZ: Double = 0
        for v in worldVerts {
            minY = min(minY, v.y)
            maxY = max(maxY, v.y)
            meanX += Double(v.x)
            meanZ += Double(v.z)
        }
        let invN = 1.0 / Double(worldVerts.count)
        meanX *= invN
        meanZ *= invN
        
        var cxx: Double = 0
        var czz: Double = 0
        var cxz: Double = 0
        for v in worldVerts {
            let dx = Double(v.x) - meanX
            let dz = Double(v.z) - meanZ
            cxx += dx * dx
            czz += dz * dz
            cxz += dx * dz
        }
        
        let pcaYaw = Float(0.5 * atan2(2.0 * cxz, cxx - czz))
        // Refine angle around PCA axis (+ check 45-degree offsets) to minimize bounding rectangle area
        var bestArea: Float = .greatestFiniteMagnitude
        var bestYaw: Float = pcaYaw
        var bestMinU: Float = 0, bestMaxU: Float = 0
        var bestMinV: Float = 0, bestMaxV: Float = 0
        
        var candidateAngles: [Float] = []
        for deg in stride(from: -15, through: 15, by: 3) {
            candidateAngles.append(pcaYaw + Float(deg) * .pi / 180.0)
        }
        candidateAngles.append(0.0)
        candidateAngles.append(.pi / 2.0)
        
        for ang in candidateAngles {
            let cu = cos(ang)
            let su = sin(ang)
            var minU: Float = .greatestFiniteMagnitude
            var maxU: Float = -.greatestFiniteMagnitude
            var minV: Float = .greatestFiniteMagnitude
            var maxV: Float = -.greatestFiniteMagnitude
            for v in worldVerts {
                let u = v.x * cu + v.z * su
                let w = -v.x * su + v.z * cu
                minU = min(minU, u)
                maxU = max(maxU, u)
                minV = min(minV, w)
                maxV = max(maxV, w)
            }
            let spanU = maxU - minU
            let spanV = maxV - minV
            let area = spanU * spanV
            if area < bestArea {
                bestArea = area
                bestYaw = ang
                bestMinU = minU
                bestMaxU = maxU
                bestMinV = minV
                bestMaxV = maxV
            }
        }
        
        let spanU = bestMaxU - bestMinU
        let spanV = bestMaxV - bestMinV
        let midU = (bestMinU + bestMaxU) * 0.5
        let midV = (bestMinV + bestMaxV) * 0.5
        
        let cu = cos(bestYaw)
        let su = sin(bestYaw)
        let worldX = midU * cu - midV * su
        let worldZ = midU * su + midV * cu
        let centerY = (minY + maxY) * 0.5
        let height = max(maxY - minY, 0.3)
        
        if spanU >= spanV {
            return OrientedBox2D(
                center: SIMD3<Float>(worldX, centerY, worldZ),
                length: spanU,
                thickness: spanV,
                height: height,
                yaw: bestYaw
            )
        } else {
            return OrientedBox2D(
                center: SIMD3<Float>(worldX, centerY, worldZ),
                length: spanV,
                thickness: spanU,
                height: height,
                yaw: bestYaw + .pi / 2.0
            )
        }
    }
    
    private static func extractWallSegmentsFromMergedMesh(triangles: [WorldTriangle]) -> [WallSurface] {
        struct WallTriPatch {
            var tangent: SIMD2<Float>
            var normal: SIMD2<Float>
            var offset: Float      // dot(centerXZ, normal)
            var sMin: Float        // min dot(v.xz, tangent)
            var sMax: Float        // max dot(v.xz, tangent)
            var yMin: Float
            var yMax: Float
            var angle: Float       // in [0, pi)
        }
        
        var patches: [WallTriPatch] = []
        for tri in triangles {
            let e1 = tri.v1 - tri.v0
            let e2 = tri.v2 - tri.v0
            let crossN = simd_cross(e1, e2)
            let nLen = simd_length(crossN)
            guard nLen > 1e-4 else { continue }
            let n = crossN / nLen
            
            // Strictly vertical faces (walls)
            guard abs(n.y) < 0.30 else { continue }
            
            var nh = SIMD2<Float>(n.x, n.z)
            let nhLen = simd_length(nh)
            guard nhLen > 1e-4 else { continue }
            nh /= nhLen
            
            // Canonicalize normal to half-circle [0, pi) so front & back wall faces group together
            var ang = atan2(nh.y, nh.x)
            if ang < 0 { ang += .pi; nh = -nh }
            if ang >= .pi { ang -= .pi; nh = -nh }
            
            let t = SIMD2<Float>(-nh.y, nh.x)
            let v0xz = SIMD2<Float>(tri.v0.x, tri.v0.z)
            let v1xz = SIMD2<Float>(tri.v1.x, tri.v1.z)
            let v2xz = SIMD2<Float>(tri.v2.x, tri.v2.z)
            let cXZ = (v0xz + v1xz + v2xz) / 3.0
            
            let d = simd_dot(cXZ, nh)
            let s0 = simd_dot(v0xz, t)
            let s1 = simd_dot(v1xz, t)
            let s2 = simd_dot(v2xz, t)
            let yMin = min(tri.v0.y, tri.v1.y, tri.v2.y)
            let yMax = max(tri.v0.y, tri.v1.y, tri.v2.y)
            
            patches.append(WallTriPatch(
                tangent: t,
                normal: nh,
                offset: d,
                sMin: min(s0, s1, s2),
                sMax: max(s0, s1, s2),
                yMin: yMin,
                yMax: yMax,
                angle: ang
            ))
        }
        
        guard !patches.isEmpty else { return [] }
        
        // Cluster patches into wall planes by angle (~10 deg) and normal offset (~0.35m)
        struct PlaneCluster {
            var angle: Float
            var normal: SIMD2<Float>
            var tangent: SIMD2<Float>
            var offsetSum: Float
            var minOffset: Float
            var maxOffset: Float
            var count: Int
            var intervals: [(sMin: Float, sMax: Float, yMin: Float, yMax: Float)]
        }
        
        var clusters: [PlaneCluster] = []
        let angTol: Float = 10.0 * .pi / 180.0
        let distTol: Float = 0.35
        
        for p in patches {
            var matched = false
            for idx in 0..<clusters.count {
                var dAng = abs(clusters[idx].angle - p.angle)
                if dAng > .pi * 0.5 { dAng = abs(dAng - .pi) }
                let meanOffset = clusters[idx].offsetSum / Float(clusters[idx].count)
                if dAng <= angTol && abs(meanOffset - p.offset) <= distTol {
                    clusters[idx].offsetSum += p.offset
                    clusters[idx].minOffset = min(clusters[idx].minOffset, p.offset)
                    clusters[idx].maxOffset = max(clusters[idx].maxOffset, p.offset)
                    clusters[idx].count += 1
                    clusters[idx].intervals.append((p.sMin, p.sMax, p.yMin, p.yMax))
                    matched = true
                    break
                }
            }
            if !matched {
                clusters.append(PlaneCluster(
                    angle: p.angle,
                    normal: p.normal,
                    tangent: p.tangent,
                    offsetSum: p.offset,
                    minOffset: p.offset,
                    maxOffset: p.offset,
                    count: 1,
                    intervals: [(p.sMin, p.sMax, p.yMin, p.yMax)]
                ))
            }
        }
        
        var walls: [WallSurface] = []
        for cluster in clusters {
            let sorted = cluster.intervals.sorted { $0.sMin < $1.sMin }
            guard var cur = sorted.first else { continue }
            
            var mergedSpans: [(sMin: Float, sMax: Float, yMin: Float, yMax: Float)] = []
            for next in sorted.dropFirst() {
                if next.sMin <= cur.sMax + 0.35 {
                    cur.sMax = max(cur.sMax, next.sMax)
                    cur.yMin = min(cur.yMin, next.yMin)
                    cur.yMax = max(cur.yMax, next.yMax)
                } else {
                    mergedSpans.append(cur)
                    cur = next
                }
            }
            mergedSpans.append(cur)
            
            let meanOffset = cluster.offsetSum / Float(cluster.count)
            let thickness = max(min(cluster.maxOffset - cluster.minOffset, 0.35), 0.14)
            let yaw = atan2(cluster.tangent.y, cluster.tangent.x)
            
            for span in mergedSpans {
                let len = span.sMax - span.sMin
                guard len >= 0.45 else { continue }
                let midS = (span.sMin + span.sMax) * 0.5
                let midXZ = cluster.normal * meanOffset + cluster.tangent * midS
                let h = max(span.yMax - span.yMin, 2.3)
                let midY = (span.yMin + span.yMax) * 0.5
                let mat = makeTransformMatrix(center: SIMD3<Float>(midXZ.x, midY, midXZ.y), yaw: yaw)
                walls.append(WallSurface(
                    id: UUID(),
                    dimensions: SIMD3<Float>(len, h, thickness),
                    transform: mat
                ))
            }
        }
        
        return walls
    }
    
    // MARK: - JSON Scan Importer
    
    private static func importJSON(from url: URL, roomName: String) throws -> MaquetteRoom {
        guard let data = try? Data(contentsOf: url) else {
            throw ScanImportError.unreadableData
        }
        
        if var room = try? JSONDecoder().decode(MaquetteRoom.self, from: data) {
            room.id = UUID() // new unique ID
            if room.name.isEmpty || room.name == "Scanned Room" {
                room.name = roomName
            }
            room.modifiedAt = Date()
            return room
        }
        
        throw ScanImportError.sceneParsingFailed
    }
    
    // MARK: - Wavefront OBJ Scan Importer
    
    private static func importOBJ(from url: URL, roomName: String) throws -> MaquetteRoom {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ScanImportError.unreadableData
        }
        
        var minX: Float = .infinity
        var maxX: Float = -.infinity
        var minY: Float = .infinity
        var maxY: Float = -.infinity
        var minZ: Float = .infinity
        var maxZ: Float = -.infinity
        
        var vertexCount = 0
        
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("v ") {
                let parts = trimmed.split(separator: " ").filter { !$0.isEmpty }
                if parts.count >= 4,
                   let x = Float(parts[1]),
                   let y = Float(parts[2]),
                   let z = Float(parts[3]) {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                    minZ = min(minZ, z)
                    maxZ = max(maxZ, z)
                    vertexCount += 1
                }
            }
        }
        
        guard vertexCount >= 4, minX < maxX, minZ < maxZ else {
            throw ScanImportError.emptyScan
        }
        
        let width = maxX - minX
        let depth = maxZ - minZ
        let height = max(maxY - minY, 2.5)
        let midX = (minX + maxX) / 2.0
        let midZ = (minZ + maxZ) / 2.0
        
        var walls: [WallSurface] = []
        
        // North wall
        var nMat = matrix_identity_float4x4
        nMat.columns.3 = SIMD4<Float>(midX, height / 2.0, minZ, 1.0)
        walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(width, height, 0.15), transform: nMat))
        
        // South wall
        var sMat = matrix_identity_float4x4
        sMat.columns.3 = SIMD4<Float>(midX, height / 2.0, maxZ, 1.0)
        walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(width, height, 0.15), transform: sMat))
        
        // East wall (rotated 90°)
        let rotE90 = simd_float4x4(
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(-1, 0, 0, 0),
            SIMD4<Float>(maxX, height / 2.0, midZ, 1)
        )
        walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(depth, height, 0.15), transform: rotE90))
        
        // West wall (rotated 90°)
        let rotW90 = simd_float4x4(
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(-1, 0, 0, 0),
            SIMD4<Float>(minX, height / 2.0, midZ, 1)
        )
        walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(depth, height, 0.15), transform: rotW90))
        
        return MaquetteRoom(
            id: UUID(),
            name: roomName.isEmpty ? "Imported OBJ Scan" : roomName,
            createdAt: Date(),
            modifiedAt: Date(),
            notes: "Imported Wavefront OBJ scan with \(vertexCount) vertices",
            walls: walls,
            doors: [],
            windows: [],
            objects: []
        )
    }
}
