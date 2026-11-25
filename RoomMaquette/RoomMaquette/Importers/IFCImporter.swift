import Foundation
import simd

public class IFCImporter {
    
    private struct StepEntity {
        var id: Int
        var type: String
        var args: [String]
    }
    
    private struct ExtractedBox {
        var centerIFC: SIMD3<Float>
        var length: Float
        var thickness: Float
        var height: Float
        var axisXIFC: SIMD2<Float>
    }
    
    public static func importIFC(from url: URL, roomName: String) throws -> MaquetteRoom {
        guard let rawText = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            throw ScanImportError.unreadableData
        }
        
        let entities = parseStepEntities(from: rawText)
        guard !entities.isEmpty else {
            throw ScanImportError.sceneParsingFailed
        }
        
        let lengthScale = detectLengthUnitScale(entities: entities)
        
        // Track opening IDs that are filled by a door or window so we don't emit duplicate pass-through openings
        var filledOpeningIds = Set<Int>()
        for (_, ent) in entities where ent.type == "IFCRELFILLSELEMENT" {
            if ent.args.count >= 5, let opId = parseRef(ent.args[4]) {
                filledOpeningIds.insert(opId)
            }
        }
        
        // Resolve project name if caller didn't give a custom one
        var resolvedName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let proj = entities.values.first(where: { $0.type == "IFCPROJECT" }),
           proj.args.count >= 3,
           let projName = parseString(proj.args[2]),
           !projName.isEmpty,
           resolvedName.isEmpty {
            resolvedName = projName
        }
        if resolvedName.isEmpty {
            resolvedName = "Imported IFC Model"
        }
        
        var placementCache: [Int: simd_float4x4] = [:]
        
        func resolvePlacement(_ id: Int) -> simd_float4x4 {
            if let cached = placementCache[id] { return cached }
            guard let ent = entities[id] else { return matrix_identity_float4x4 }
            
            let result: simd_float4x4
            if ent.type == "IFCLOCALPLACEMENT", ent.args.count >= 2 {
                let parentMat: simd_float4x4
                if let parentId = parseRef(ent.args[0]) {
                    parentMat = resolvePlacement(parentId)
                } else {
                    parentMat = matrix_identity_float4x4
                }
                let relMat: simd_float4x4
                if let axisId = parseRef(ent.args[1]) {
                    relMat = resolveAxis2Placement3D(axisId)
                } else {
                    relMat = matrix_identity_float4x4
                }
                result = simd_mul(parentMat, relMat)
            } else if ent.type == "IFCAXIS2PLACEMENT3D" {
                result = resolveAxis2Placement3D(id)
            } else {
                result = matrix_identity_float4x4
            }
            placementCache[id] = result
            return result
        }
        
        func resolveAxis2Placement3D(_ id: Int) -> simd_float4x4 {
            guard let ent = entities[id], ent.type == "IFCAXIS2PLACEMENT3D", !ent.args.isEmpty else {
                return matrix_identity_float4x4
            }
            let loc: SIMD3<Float> = parseRef(ent.args[0]).flatMap { readPoint3D($0) } ?? .zero
            let rawZ: SIMD3<Float> = (ent.args.count >= 2 ? parseRef(ent.args[1]).flatMap { readDir3D($0) } : nil) ?? SIMD3<Float>(0, 0, 1)
            let rawX: SIMD3<Float> = (ent.args.count >= 3 ? parseRef(ent.args[2]).flatMap { readDir3D($0) } : nil) ?? SIMD3<Float>(1, 0, 0)
            
            let zAxis = safeNormalize(rawZ, fallback: SIMD3<Float>(0, 0, 1))
            let orthX = rawX - simd_dot(rawX, zAxis) * zAxis
            let xAxis = safeNormalize(orthX, fallback: abs(zAxis.z) < 0.9 ? safeNormalize(simd_cross(SIMD3<Float>(0, 0, 1), zAxis), fallback: SIMD3<Float>(1, 0, 0)) : SIMD3<Float>(1, 0, 0))
            let yAxis = safeNormalize(simd_cross(zAxis, xAxis), fallback: SIMD3<Float>(0, 1, 0))
            
            return simd_float4x4(
                SIMD4<Float>(xAxis.x, xAxis.y, xAxis.z, 0),
                SIMD4<Float>(yAxis.x, yAxis.y, yAxis.z, 0),
                SIMD4<Float>(zAxis.x, zAxis.y, zAxis.z, 0),
                SIMD4<Float>(loc.x, loc.y, loc.z, 1)
            )
        }
        
        func resolveAxis2Placement2D(_ id: Int) -> (origin: SIMD2<Float>, dirX: SIMD2<Float>) {
            guard let ent = entities[id], ent.type == "IFCAXIS2PLACEMENT2D", !ent.args.isEmpty else {
                return (.zero, SIMD2<Float>(1, 0))
            }
            let loc = parseRef(ent.args[0]).flatMap { readPoint2D($0) } ?? .zero
            let dir = (ent.args.count >= 2 ? parseRef(ent.args[1]).flatMap { readDir2D($0) } : nil) ?? SIMD2<Float>(1, 0)
            let dLen = simd_length(dir)
            return (loc, dLen > 1e-5 ? (dir / dLen) : SIMD2<Float>(1, 0))
        }
        
        func readPoint3D(_ id: Int) -> SIMD3<Float>? {
            guard let ent = entities[id], ent.type == "IFCCARTESIANPOINT", let first = ent.args.first else { return nil }
            let nums = parseFloatList(first)
            guard nums.count >= 2 else { return nil }
            let x = nums[0] * lengthScale
            let y = nums[1] * lengthScale
            let z = (nums.count >= 3 ? nums[2] : 0) * lengthScale
            return SIMD3<Float>(x, y, z)
        }
        
        func readPoint2D(_ id: Int) -> SIMD2<Float>? {
            guard let ent = entities[id], ent.type == "IFCCARTESIANPOINT", let first = ent.args.first else { return nil }
            let nums = parseFloatList(first)
            guard nums.count >= 2 else { return nil }
            return SIMD2<Float>(nums[0] * lengthScale, nums[1] * lengthScale)
        }
        
        func readDir3D(_ id: Int) -> SIMD3<Float>? {
            guard let ent = entities[id], ent.type == "IFCDIRECTION", let first = ent.args.first else { return nil }
            let nums = parseFloatList(first)
            guard nums.count >= 3 else { return nil }
            return SIMD3<Float>(nums[0], nums[1], nums[2])
        }
        
        func readDir2D(_ id: Int) -> SIMD2<Float>? {
            guard let ent = entities[id], ent.type == "IFCDIRECTION", let first = ent.args.first else { return nil }
            let nums = parseFloatList(first)
            guard nums.count >= 2 else { return nil }
            return SIMD2<Float>(nums[0], nums[1])
        }
        
        // Extract geometry bounding box (in IFC Z-up meters) from IFCPRODUCTDEFINITIONSHAPE / Item
        func extractGeometryBox(shapeRef: Int, placementMat: simd_float4x4) -> ExtractedBox? {
            guard let shapeEnt = entities[shapeRef] else { return nil }
            var repItems: [Int] = []
            
            if shapeEnt.type == "IFCPRODUCTDEFINITIONSHAPE", shapeEnt.args.count >= 3 {
                let repIds = parseRefList(shapeEnt.args[2])
                // Prefer Body representation if available
                let bodyReps = repIds.filter { rid in
                    if let r = entities[rid], r.args.count >= 2,
                       let idStr = parseString(r.args[1])?.lowercased() {
                        return idStr == "body"
                    }
                    return false
                }
                let chosenReps = bodyReps.isEmpty ? repIds : bodyReps
                for rid in chosenReps {
                    if let r = entities[rid], r.args.count >= 4 {
                        repItems.append(contentsOf: parseRefList(r.args[3]))
                    }
                }
            } else if shapeEnt.type == "IFCSHAPEREPRESENTATION", shapeEnt.args.count >= 4 {
                repItems.append(contentsOf: parseRefList(shapeEnt.args[3]))
            }
            
            for itemId in repItems {
                if let box = extractRepresentationItem(itemId: itemId, parentMat: placementMat, depth: 0) {
                    return box
                }
            }
            return nil
        }
        
        func extractRepresentationItem(itemId: Int, parentMat: simd_float4x4, depth: Int) -> ExtractedBox? {
            guard depth < 6, let item = entities[itemId] else { return nil }
            
            switch item.type {
            case "IFCBOOLEANCLIPPINGRESULT", "IFCBOOLEANRESULT":
                if item.args.count >= 2, let firstOp = parseRef(item.args[1]) {
                    return extractRepresentationItem(itemId: firstOp, parentMat: parentMat, depth: depth + 1)
                }
                
            case "IFCMAPPEDITEM":
                if item.args.count >= 2,
                   let mapSrcId = parseRef(item.args[0]),
                   let mapSrc = entities[mapSrcId],
                   mapSrc.type == "IFCREPRESENTATIONMAP",
                   mapSrc.args.count >= 2 {
                    let mapOriginMat = parseRef(mapSrc.args[0]).map { resolveAxis2Placement3D($0) } ?? matrix_identity_float4x4
                    let targetMat = parseRef(item.args[1]).map { resolveTransformOperator3D($0) } ?? matrix_identity_float4x4
                    let combined = simd_mul(parentMat, simd_mul(targetMat, mapOriginMat))
                    if let repId = parseRef(mapSrc.args[1]),
                       let rep = entities[repId], rep.args.count >= 4 {
                        for subId in parseRefList(rep.args[3]) {
                            if let box = extractRepresentationItem(itemId: subId, parentMat: combined, depth: depth + 1) {
                                return box
                            }
                        }
                    }
                }
                
            case "IFCEXTRUDEDAREASOLID":
                // Args: (SweptArea, Position, ExtrudedDirection, Depth)
                guard item.args.count >= 4 else { return nil }
                let posMat = parseRef(item.args[1]).map { resolveAxis2Placement3D($0) } ?? matrix_identity_float4x4
                let solidMat = simd_mul(parentMat, posMat)
                let extrudeDir = parseRef(item.args[2]).flatMap { readDir3D($0) } ?? SIMD3<Float>(0, 0, 1)
                let extrudeDepth = max((parseFloat(item.args[3]) ?? 2.5) * lengthScale, 0.04)
                
                if let profileId = parseRef(item.args[0]), let profEnt = entities[profileId] {
                    if profEnt.type == "IFCRECTANGLEPROFILEDEF", profEnt.args.count >= 5 {
                        let p2d = parseRef(profEnt.args[2]).map { resolveAxis2Placement2D($0) } ?? (.zero, SIMD2<Float>(1, 0))
                        let xDim = max((parseFloat(profEnt.args[3]) ?? 0.5) * lengthScale, 0.04)
                        let yDim = max((parseFloat(profEnt.args[4]) ?? 0.5) * lengthScale, 0.04)
                        
                        // Local center of extruded rectangle in solid coordinates
                        let halfExtrude = safeNormalize(extrudeDir, fallback: SIMD3<Float>(0, 0, 1)) * (extrudeDepth * 0.5)
                        let localCenter = SIMD4<Float>(p2d.origin.x + halfExtrude.x, p2d.origin.y + halfExtrude.y, halfExtrude.z, 1.0)
                        let worldCenter4 = simd_mul(solidMat, localCenter)
                        
                        let localAxisX = SIMD4<Float>(p2d.dirX.x, p2d.dirX.y, 0, 0)
                        let worldAxisX4 = simd_mul(solidMat, localAxisX)
                        var axis2D = SIMD2<Float>(worldAxisX4.x, worldAxisX4.y)
                        axis2D = simd_length(axis2D) > 1e-4 ? simd_normalize(axis2D) : SIMD2<Float>(1, 0)
                        
                        // Handle vertical vs horizontal extrusion orientation cleanly
                        let worldExtrude4 = simd_mul(solidMat, SIMD4<Float>(extrudeDir.x, extrudeDir.y, extrudeDir.z, 0))
                        let absZ = abs(worldExtrude4.z)
                        if absZ >= 0.7 {
                            // Standard vertical extrusion (walls, doors, windows, slabs, furniture)
                            let len = max(xDim, yDim)
                            let thick = min(xDim, yDim)
                            if xDim < yDim {
                                // Swap primary axis by 90 deg so length is along axisXIFC
                                axis2D = SIMD2<Float>(-axis2D.y, axis2D.x)
                            }
                            return ExtractedBox(
                                centerIFC: SIMD3<Float>(worldCenter4.x, worldCenter4.y, worldCenter4.z),
                                length: len,
                                thickness: thick,
                                height: extrudeDepth,
                                axisXIFC: axis2D
                            )
                        } else {
                            // Horizontal extrusion (e.g. side-profile wall)
                            let horizExtrude = SIMD2<Float>(worldExtrude4.x, worldExtrude4.y)
                            let exAxis = simd_length(horizExtrude) > 1e-4 ? simd_normalize(horizExtrude) : SIMD2<Float>(1, 0)
                            let len = max(extrudeDepth, xDim)
                            let thick = min(extrudeDepth, xDim)
                            return ExtractedBox(
                                centerIFC: SIMD3<Float>(worldCenter4.x, worldCenter4.y, worldCenter4.z),
                                length: len,
                                thickness: thick,
                                height: yDim,
                                axisXIFC: extrudeDepth >= xDim ? exAxis : axis2D
                            )
                        }
                    } else if profEnt.type == "IFCARBITRARYCLOSEDPROFILEDEF", profEnt.args.count >= 3,
                              let curveId = parseRef(profEnt.args[2]) {
                        let pts2D = collectCurvePoints2D(curveId: curveId)
                        if pts2D.count >= 3 {
                            var worldVerts: [SIMD3<Float>] = []
                            let normDir = safeNormalize(extrudeDir, fallback: SIMD3<Float>(0, 0, 1))
                            for pt in pts2D {
                                let base4 = simd_mul(solidMat, SIMD4<Float>(pt.x, pt.y, 0, 1))
                                let top4 = simd_mul(solidMat, SIMD4<Float>(pt.x + normDir.x * extrudeDepth, pt.y + normDir.y * extrudeDepth, normDir.z * extrudeDepth, 1))
                                worldVerts.append(SIMD3<Float>(base4.x, base4.y, base4.z))
                                worldVerts.append(SIMD3<Float>(top4.x, top4.y, top4.z))
                            }
                            return computeIFCBoxOBB(vertices: worldVerts)
                        }
                    } else if profEnt.type == "IFCCIRCLEPROFILEDEF", profEnt.args.count >= 4 {
                        let r = max((parseFloat(profEnt.args[3]) ?? 0.3) * lengthScale, 0.1)
                        let halfE = safeNormalize(extrudeDir, fallback: SIMD3<Float>(0, 0, 1)) * (extrudeDepth * 0.5)
                        let wc4 = simd_mul(solidMat, SIMD4<Float>(halfE.x, halfE.y, halfE.z, 1.0))
                        return ExtractedBox(
                            centerIFC: SIMD3<Float>(wc4.x, wc4.y, wc4.z),
                            length: r * 2.0,
                            thickness: r * 2.0,
                            height: extrudeDepth,
                            axisXIFC: SIMD2<Float>(1, 0)
                        )
                    }
                }
                
            case "IFCFACETEDBREP", "IFCTRIANGULATEDFACESET":
                let verts = collectBRepVertices(itemId: itemId)
                if !verts.isEmpty {
                    let worldVerts = verts.map { v -> SIMD3<Float> in
                        let w = simd_mul(parentMat, SIMD4<Float>(v.x, v.y, v.z, 1.0))
                        return SIMD3<Float>(w.x, w.y, w.z)
                    }
                    return computeIFCBoxOBB(vertices: worldVerts)
                }
                
            default:
                break
            }
            return nil
        }
        
        func resolveTransformOperator3D(_ id: Int) -> simd_float4x4 {
            guard let ent = entities[id], ent.type.hasPrefix("IFCCARTESIANTRANSFORMATIONOPERATOR") else {
                return matrix_identity_float4x4
            }
            let a1 = (ent.args.count >= 1 ? parseRef(ent.args[0]).flatMap { readDir3D($0) } : nil) ?? SIMD3<Float>(1, 0, 0)
            let a2 = (ent.args.count >= 2 ? parseRef(ent.args[1]).flatMap { readDir3D($0) } : nil) ?? SIMD3<Float>(0, 1, 0)
            let origin = (ent.args.count >= 3 ? parseRef(ent.args[2]).flatMap { readPoint3D($0) } : nil) ?? .zero
            let scale = (ent.args.count >= 4 ? parseFloat(ent.args[3]) : nil) ?? 1.0
            let a3 = safeNormalize(simd_cross(a1, a2), fallback: SIMD3<Float>(0, 0, 1))
            let xAxis = safeNormalize(a1, fallback: SIMD3<Float>(1, 0, 0)) * scale
            let yAxis = safeNormalize(a2, fallback: SIMD3<Float>(0, 1, 0)) * scale
            let zAxis = a3 * scale
            return simd_float4x4(
                SIMD4<Float>(xAxis.x, xAxis.y, xAxis.z, 0),
                SIMD4<Float>(yAxis.x, yAxis.y, yAxis.z, 0),
                SIMD4<Float>(zAxis.x, zAxis.y, zAxis.z, 0),
                SIMD4<Float>(origin.x, origin.y, origin.z, 1)
            )
        }
        
        func collectCurvePoints2D(curveId: Int) -> [SIMD2<Float>] {
            guard let ent = entities[curveId], !ent.args.isEmpty else { return [] }
            if ent.type == "IFCPOLYLINE", let listStr = ent.args.first {
                return parseRefList(listStr).compactMap { readPoint2D($0) }
            } else if ent.type == "IFCINDEXEDPOLYCURVE", let ptListRef = parseRef(ent.args[0]),
                      let ptList = entities[ptListRef], let rawCoords = ptList.args.first {
                return parseNestedFloatPairs(rawCoords).map { SIMD2<Float>($0.0 * lengthScale, $0.1 * lengthScale) }
            }
            return []
        }
        
        func collectBRepVertices(itemId: Int) -> [SIMD3<Float>] {
            guard let ent = entities[itemId], !ent.args.isEmpty else { return [] }
            if ent.type == "IFCTRIANGULATEDFACESET", let coordRef = parseRef(ent.args[0]),
               let coordEnt = entities[coordRef], let rawCoords = coordEnt.args.first {
                return parseNestedFloatTriples(rawCoords).map {
                    SIMD3<Float>($0.0 * lengthScale, $0.1 * lengthScale, $0.2 * lengthScale)
                }
            } else if ent.type == "IFCFACETEDBREP", let shellRef = parseRef(ent.args[0]),
                      let shell = entities[shellRef], let faceListStr = shell.args.first {
                var pts: [SIMD3<Float>] = []
                for fId in parseRefList(faceListStr).prefix(48) {
                    guard let face = entities[fId], let boundListStr = face.args.first else { continue }
                    for bId in parseRefList(boundListStr) {
                        guard let bound = entities[bId], !bound.args.isEmpty, let loopId = parseRef(bound.args[0]),
                              let loop = entities[loopId], let ptListStr = loop.args.first else { continue }
                        for pId in parseRefList(ptListStr) {
                            if let p = readPoint3D(pId) { pts.append(p) }
                        }
                    }
                }
                return pts
            }
            return []
        }
        
        // 3. Extract Architectural & Furnishing Entities into RoomMaquette Space
        var walls: [WallSurface] = []
        var doors: [DoorSurface] = []
        var windows: [WindowSurface] = []
        var openings: [OpeningSurface] = []
        var objects: [FurnitureObject] = []
        
        func ifcBoxToRoomTransform(_ box: ExtractedBox) -> (dims: SIMD3<Float>, transform: simd_float4x4) {
            // IFC (ifcX, ifcY, ifcZ_up) -> RoomMaquette (roomX = ifcX, roomY = ifcZ_up, roomZ = -ifcY)
            let roomCenter = SIMD3<Float>(box.centerIFC.x, box.centerIFC.z, -box.centerIFC.y)
            let yaw = atan2(-box.axisXIFC.y, box.axisXIFC.x)
            let c = cos(yaw)
            let s = sin(yaw)
            let mat = simd_float4x4(
                SIMD4<Float>(c, 0, s, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-s, 0, c, 0),
                SIMD4<Float>(roomCenter.x, roomCenter.y, roomCenter.z, 1.0)
            )
            return (SIMD3<Float>(box.length, box.height, box.thickness), mat)
        }
        
        for (eid, ent) in entities {
            switch ent.type {
            case "IFCWALL", "IFCWALLSTANDARDCASE", "IFCWALLELEMENTEDCASE":
                let placeMat = (ent.args.count >= 6 ? parseRef(ent.args[5]).map { resolvePlacement($0) } : nil) ?? matrix_identity_float4x4
                if ent.args.count >= 7, let shapeId = parseRef(ent.args[6]),
                   let box = extractGeometryBox(shapeRef: shapeId, placementMat: placeMat),
                   box.length >= 0.25 {
                    let (dims, mat) = ifcBoxToRoomTransform(box)
                    walls.append(WallSurface(id: UUID(), dimensions: dims, transform: mat))
                }
                
            case "IFCDOOR", "IFCDOORSTANDARDCASE":
                let placeMat = (ent.args.count >= 6 ? parseRef(ent.args[5]).map { resolvePlacement($0) } : nil) ?? matrix_identity_float4x4
                let overallH = ent.args.count >= 9 ? (parseFloat(ent.args[8]).map { $0 * lengthScale }) : nil
                let overallW = ent.args.count >= 10 ? (parseFloat(ent.args[9]).map { $0 * lengthScale }) : nil
                
                if ent.args.count >= 7, let shapeId = parseRef(ent.args[6]),
                   var box = extractGeometryBox(shapeRef: shapeId, placementMat: placeMat) {
                    if let w = overallW, w > 0.3 { box.length = max(box.length, w) }
                    if let h = overallH, h > 1.0 { box.height = max(box.height, h) }
                    let (dims, mat) = ifcBoxToRoomTransform(box)
                    doors.append(DoorSurface(id: UUID(), dimensions: dims, transform: mat, isOpen: true))
                } else if let w = overallW, let h = overallH {
                    let loc = SIMD3<Float>(placeMat.columns.3.x, placeMat.columns.3.y, placeMat.columns.3.z + h * 0.5)
                    let axis = SIMD2<Float>(placeMat.columns.0.x, placeMat.columns.0.y)
                    let box = ExtractedBox(centerIFC: loc, length: w, thickness: 0.08, height: h, axisXIFC: safeNormalize2D(axis))
                    let (dims, mat) = ifcBoxToRoomTransform(box)
                    doors.append(DoorSurface(id: UUID(), dimensions: dims, transform: mat, isOpen: true))
                }
                
            case "IFCWINDOW", "IFCWINDOWSTANDARDCASE":
                let placeMat = (ent.args.count >= 6 ? parseRef(ent.args[5]).map { resolvePlacement($0) } : nil) ?? matrix_identity_float4x4
                let overallH = ent.args.count >= 9 ? (parseFloat(ent.args[8]).map { $0 * lengthScale }) : nil
                let overallW = ent.args.count >= 10 ? (parseFloat(ent.args[9]).map { $0 * lengthScale }) : nil
                
                if ent.args.count >= 7, let shapeId = parseRef(ent.args[6]),
                   var box = extractGeometryBox(shapeRef: shapeId, placementMat: placeMat) {
                    if let w = overallW, w > 0.3 { box.length = max(box.length, w) }
                    if let h = overallH, h > 0.3 { box.height = max(box.height, h) }
                    let (dims, mat) = ifcBoxToRoomTransform(box)
                    windows.append(WindowSurface(id: UUID(), dimensions: dims, transform: mat))
                } else if let w = overallW, let h = overallH {
                    let loc = SIMD3<Float>(placeMat.columns.3.x, placeMat.columns.3.y, placeMat.columns.3.z + h * 0.5)
                    let axis = SIMD2<Float>(placeMat.columns.0.x, placeMat.columns.0.y)
                    let box = ExtractedBox(centerIFC: loc, length: w, thickness: 0.08, height: h, axisXIFC: safeNormalize2D(axis))
                    let (dims, mat) = ifcBoxToRoomTransform(box)
                    windows.append(WindowSurface(id: UUID(), dimensions: dims, transform: mat))
                }
                
            case "IFCOPENINGELEMENT":
                guard !filledOpeningIds.contains(eid) else { continue }
                let placeMat = (ent.args.count >= 6 ? parseRef(ent.args[5]).map { resolvePlacement($0) } : nil) ?? matrix_identity_float4x4
                if ent.args.count >= 7, let shapeId = parseRef(ent.args[6]),
                   let box = extractGeometryBox(shapeRef: shapeId, placementMat: placeMat) {
                    let (dims, mat) = ifcBoxToRoomTransform(box)
                    openings.append(OpeningSurface(id: UUID(), dimensions: dims, transform: mat))
                }
                
            case "IFCFURNITURE", "IFCFURNISHINGELEMENT", "IFCSANITARYTERMINAL", "IFCELECTRICAPPLIANCE", "IFCAPPLIANCE":
                let placeMat = (ent.args.count >= 6 ? parseRef(ent.args[5]).map { resolvePlacement($0) } : nil) ?? matrix_identity_float4x4
                if ent.args.count >= 7, let shapeId = parseRef(ent.args[6]),
                   let box = extractGeometryBox(shapeRef: shapeId, placementMat: placeMat) {
                    let rawName = (ent.args.count >= 3 ? parseString(ent.args[2]) : nil) ?? ""
                    let objType = (ent.args.count >= 5 ? parseString(ent.args[4]) : nil) ?? ""
                    let predef = (ent.args.count >= 9 ? ent.args[8] : "")
                    let cat = mapIFCFurnitureCategory(name: rawName, objectType: objType, predef: predef, entityType: ent.type)
                    let (dims, mat) = ifcBoxToRoomTransform(box)
                    objects.append(FurnitureObject(
                        id: UUID(),
                        category: cat,
                        customName: rawName.isEmpty ? cat.displayName : rawName,
                        dimensions: dims,
                        transform: mat
                    ))
                }
                
            default:
                break
            }
        }
        
        guard !walls.isEmpty || !objects.isEmpty || !doors.isEmpty || !windows.isEmpty else {
            throw ScanImportError.emptyScan
        }
        
        // Normalize faraway BIM site coordinates so the room is centered cleanly around (0, 0)
        var room = MaquetteRoom(
            id: UUID(),
            name: resolvedName,
            createdAt: Date(),
            modifiedAt: Date(),
            notes: "Imported from IFC BIM file (\(walls.count) walls, \(objects.count) items)",
            walls: walls,
            doors: doors,
            windows: windows,
            openings: openings,
            objects: objects
        )
        
        let bounds = room.boundingBox
        let cx = (bounds.min.x + bounds.max.x) * 0.5
        let cz = (bounds.min.z + bounds.max.z) * 0.5
        let minY = bounds.min.y
        if abs(cx) > 25.0 || abs(cz) > 25.0 || abs(minY) > 0.25 {
            room = shiftRoomOrigin(room, dx: -cx, dy: -minY, dz: -cz)
        }
        
        return room
    }
    
    // MARK: - STEP Parser & Units
    
    private static func parseStepEntities(from content: String) -> [Int: StepEntity] {
        var result: [Int: StepEntity] = [:]
        
        // Locate DATA; ... ENDSEC;
        let upperContent = content
        let dataBody: Substring
        if let dataRange = upperContent.range(of: "DATA;", options: .caseInsensitive) {
            let afterData = upperContent[dataRange.upperBound...]
            if let endRange = afterData.range(of: "ENDSEC;", options: .caseInsensitive) {
                dataBody = afterData[..<endRange.lowerBound]
            } else {
                dataBody = afterData
            }
        } else {
            dataBody = Substring(content)
        }
        
        // Split statements on ';' outside single-quoted literals
        var statements: [String] = []
        var current = ""
        current.reserveCapacity(128)
        var inQuotes = false
        var prevChar: Character? = nil
        
        for ch in dataBody {
            if ch == "'" {
                if inQuotes && prevChar == "'" {
                    // STEP escaped quote ('') keeps quote mode? Wait: toggle cleanly pair-wise
                }
                inQuotes.toggle()
                current.append(ch)
            } else if ch == ";" && !inQuotes {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    statements.append(trimmed)
                }
                current.removeAll(keepingCapacity: true)
            } else if ch != "\r" && ch != "\n" {
                current.append(ch)
            }
            prevChar = ch
        }
        
        for stmt in statements {
            guard stmt.hasPrefix("#"),
                  let eqIdx = stmt.firstIndex(of: "="),
                  let id = Int(stmt[stmt.index(after: stmt.startIndex)..<eqIdx].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            let rhs = stmt[stmt.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
            guard let openParen = rhs.firstIndex(of: "("),
                  let closeParen = rhs.lastIndex(of: ")"),
                  openParen < closeParen else {
                continue
            }
            let typeName = rhs[..<openParen].trimmingCharacters(in: .whitespaces).uppercased()
            let argsContent = String(rhs[rhs.index(after: openParen)..<closeParen])
            let args = parseTopLevelArgs(argsContent)
            result[id] = StepEntity(id: id, type: typeName, args: args)
        }
        
        return result
    }
    
    private static func parseTopLevelArgs(_ raw: String) -> [String] {
        var args: [String] = []
        var current = ""
        var depth = 0
        var inQuotes = false
        
        for ch in raw {
            if ch == "'" {
                inQuotes.toggle()
                current.append(ch)
            } else if !inQuotes && ch == "(" {
                depth += 1
                current.append(ch)
            } else if !inQuotes && ch == ")" {
                depth = max(0, depth - 1)
                current.append(ch)
            } else if !inQuotes && depth == 0 && ch == "," {
                args.append(current.trimmingCharacters(in: .whitespaces))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(ch)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty || !args.isEmpty {
            args.append(tail)
        }
        return args
    }
    
    private static func detectLengthUnitScale(entities: [Int: StepEntity]) -> Float {
        for (_, ent) in entities where ent.type == "IFCSIUNIT" {
            if ent.args.count >= 4 && ent.args[1].uppercased().contains(".LENGTHUNIT.") {
                let prefix = ent.args[2].uppercased()
                if prefix.contains(".MILLI.") { return 0.001 }
                if prefix.contains(".CENTI.") { return 0.01 }
                if prefix.contains(".DECI.") { return 0.1 }
                return 1.0
            }
        }
        for (_, ent) in entities where ent.type == "IFCCONVERSIONBASEDUNIT" {
            if ent.args.count >= 3 && ent.args[1].uppercased().contains(".LENGTHUNIT.") {
                let unitName = (parseString(ent.args[2]) ?? "").uppercased()
                if unitName.contains("FOOT") || unitName.contains("FEET") { return 0.3048 }
                if unitName.contains("INCH") { return 0.0254 }
            }
        }
        return 1.0
    }
    
    // MARK: - Primitive Argument Parsers
    
    private static func parseRef(_ arg: String) -> Int? {
        let t = arg.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("#") else { return nil }
        return Int(t.dropFirst())
    }
    
    private static func parseRefList(_ arg: String) -> [Int] {
        let inner = stripParens(arg)
        return inner.split(separator: ",").compactMap { parseRef(String($0)) }
    }
    
    private static func parseFloat(_ arg: String) -> Float? {
        let t = arg.trimmingCharacters(in: .whitespaces)
        if t == "$" || t == "*" { return nil }
        return Float(t)
    }
    
    private static func parseFloatList(_ arg: String) -> [Float] {
        stripParens(arg).split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
    }
    
    private static func parseNestedFloatPairs(_ arg: String) -> [(Float, Float)] {
        let outer = stripParens(arg)
        var pairs: [(Float, Float)] = []
        var buf = ""
        var inside = false
        for ch in outer {
            if ch == "(" { inside = true; buf.removeAll() }
            else if ch == ")" {
                inside = false
                let vals = buf.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
                if vals.count >= 2 { pairs.append((vals[0], vals[1])) }
            } else if inside {
                buf.append(ch)
            }
        }
        return pairs
    }
    
    private static func parseNestedFloatTriples(_ arg: String) -> [(Float, Float, Float)] {
        let outer = stripParens(arg)
        var triples: [(Float, Float, Float)] = []
        var buf = ""
        var inside = false
        for ch in outer {
            if ch == "(" { inside = true; buf.removeAll() }
            else if ch == ")" {
                inside = false
                let vals = buf.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
                if vals.count >= 3 { triples.append((vals[0], vals[1], vals[2])) }
            } else if inside {
                buf.append(ch)
            }
        }
        return triples
    }
    
    private static func parseString(_ arg: String) -> String? {
        let t = arg.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("'"), t.hasSuffix("'"), t.count >= 2 else { return nil }
        return String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
    
    private static func stripParens(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("(") && t.hasSuffix(")") && t.count >= 2 {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }
    
    // MARK: - Geometry & Coordinate Helpers
    
    private static func safeNormalize(_ v: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let l = simd_length(v)
        return l > 1e-5 ? (v / l) : fallback
    }
    
    private static func safeNormalize2D(_ v: SIMD2<Float>) -> SIMD2<Float> {
        let l = simd_length(v)
        return l > 1e-5 ? (v / l) : SIMD2<Float>(1, 0)
    }
    
    private static func computeIFCBoxOBB(vertices: [SIMD3<Float>]) -> ExtractedBox? {
        guard !vertices.isEmpty else { return nil }
        var minZ: Float = .greatestFiniteMagnitude
        var maxZ: Float = -.greatestFiniteMagnitude
        var meanX: Double = 0, meanY: Double = 0
        for v in vertices {
            minZ = min(minZ, v.z)
            maxZ = max(maxZ, v.z)
            meanX += Double(v.x)
            meanY += Double(v.y)
        }
        meanX /= Double(vertices.count)
        meanY /= Double(vertices.count)
        
        var cxx: Double = 0, cyy: Double = 0, cxy: Double = 0
        for v in vertices {
            let dx = Double(v.x) - meanX
            let dy = Double(v.y) - meanY
            cxx += dx * dx
            cyy += dy * dy
            cxy += dx * dy
        }
        let pcaYaw = Float(0.5 * atan2(2.0 * cxy, cxx - cyy))
        
        var bestArea: Float = .greatestFiniteMagnitude
        var bestYaw: Float = pcaYaw
        var bMinU: Float = 0, bMaxU: Float = 0, bMinV: Float = 0, bMaxV: Float = 0
        var cands: [Float] = [0.0, .pi * 0.5]
        for deg in stride(from: -15, through: 15, by: 3) {
            cands.append(pcaYaw + Float(deg) * .pi / 180.0)
        }
        for ang in cands {
            let cu = cos(ang), su = sin(ang)
            var minU: Float = .greatestFiniteMagnitude, maxU: Float = -.greatestFiniteMagnitude
            var minV: Float = .greatestFiniteMagnitude, maxV: Float = -.greatestFiniteMagnitude
            for v in vertices {
                let u = v.x * cu + v.y * su
                let w = -v.x * su + v.y * cu
                minU = min(minU, u); maxU = max(maxU, u)
                minV = min(minV, w); maxV = max(maxV, w)
            }
            let area = (maxU - minU) * (maxV - minV)
            if area < bestArea {
                bestArea = area; bestYaw = ang
                bMinU = minU; bMaxU = maxU; bMinV = minV; bMaxV = maxV
            }
        }
        let spanU = bMaxU - bMinU
        let spanV = bMaxV - bMinV
        let midU = (bMinU + bMaxU) * 0.5
        let midV = (bMinV + bMaxV) * 0.5
        let cu = cos(bestYaw), su = sin(bestYaw)
        let cx = midU * cu - midV * su
        let cy = midU * su + midV * cu
        let cz = (minZ + maxZ) * 0.5
        let h = max(maxZ - minZ, 0.3)
        
        if spanU >= spanV {
            return ExtractedBox(centerIFC: SIMD3<Float>(cx, cy, cz), length: spanU, thickness: spanV, height: h, axisXIFC: SIMD2<Float>(cu, su))
        } else {
            return ExtractedBox(centerIFC: SIMD3<Float>(cx, cy, cz), length: spanV, thickness: spanU, height: h, axisXIFC: SIMD2<Float>(-su, cu))
        }
    }
    
    private static func mapIFCFurnitureCategory(name: String, objectType: String, predef: String, entityType: String) -> ObjectCategory {
        let combined = "\(name) \(objectType) \(predef) \(entityType)".lowercased()
        if combined.contains("sofa") || combined.contains("couch") { return .sofa }
        if combined.contains("bed") { return .bed }
        if combined.contains("desk") { return .desk }
        if combined.contains("table") { return .table }
        if combined.contains("chair") || combined.contains("seat") { return .chair }
        if combined.contains("shelf") || combined.contains("cabinet") || combined.contains("storage") || combined.contains("closet") { return .storage }
        if combined.contains("toilet") || combined.contains("wc") { return .toilet }
        if combined.contains("sink") || combined.contains("basin") || combined.contains("lavatory") { return .sink }
        if combined.contains("bath") || combined.contains("tub") { return .bathtub }
        if combined.contains("fridge") || combined.contains("refrigerator") { return .refrigerator }
        if combined.contains("stove") || combined.contains("cooktop") { return .stove }
        if combined.contains("oven") { return .oven }
        if combined.contains("washer") || combined.contains("dryer") { return .washerDryer }
        if combined.contains("tv") || combined.contains("television") { return .television }
        if combined.contains("plant") { return .plant }
        return .generic
    }
    
    private static func shiftRoomOrigin(_ room: MaquetteRoom, dx: Float, dy: Float, dz: Float) -> MaquetteRoom {
        func shifted(_ tm: TransformMatrix) -> simd_float4x4 {
            var m = tm.matrix
            m.columns.3.x += dx
            m.columns.3.y += dy
            m.columns.3.z += dz
            return m
        }
        var r = room
        r.walls = room.walls.map { WallSurface(id: $0.id, dimensions: $0.dimensions, transform: shifted($0.transform), confidence: $0.confidence) }
        r.doors = room.doors.map { DoorSurface(id: $0.id, dimensions: $0.dimensions, transform: shifted($0.transform), isOpen: $0.isOpen, parentWallId: $0.parentWallId) }
        r.windows = room.windows.map { WindowSurface(id: $0.id, dimensions: $0.dimensions, transform: shifted($0.transform), parentWallId: $0.parentWallId) }
        r.openings = room.openings.map { OpeningSurface(id: $0.id, dimensions: $0.dimensions, transform: shifted($0.transform), parentWallId: $0.parentWallId) }
        r.objects = room.objects.map { FurnitureObject(id: $0.id, category: $0.category, customName: $0.customName, dimensions: $0.dimensions, transform: shifted($0.transform), confidence: $0.confidence) }
        return r
    }
}
