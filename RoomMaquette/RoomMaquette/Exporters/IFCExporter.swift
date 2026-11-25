import Foundation
import simd

public class IFCExporter {
    
    private static let ifcBase64Chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_$")
    
    public static func export(room: MaquetteRoom) throws -> URL {
        let safeName = ExportManager.sanitizedFileName(from: room.name)
        let baseName = "\(safeName)_\(Int(Date().timeIntervalSince1970))"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName).ifc")
        
        var nextId = 1
        var lines: [String] = []
        
        @discardableResult
        func emit(_ entity: String) -> Int {
            let id = nextId
            nextId += 1
            lines.append("#\(id)=\(entity);")
            return id
        }
        
        func fmt(_ v: Float) -> String {
            // Ensure STEP real literals always contain a decimal point (or scientific notation)
            let s = String(format: "%.4f", v)
            return s.contains(".") ? s : "\(s).0"
        }
        
        func esc(_ text: String) -> String {
            text.replacingOccurrences(of: "'", with: "''")
                .replacingOccurrences(of: "\n", with: " ")
        }
        
        // 1. Metadata, OwnerHistory & Units (Meters)
        let personId = emit("IFCPERSON($,$,'RoomMaquette User',$,$,$,$,$)")
        let orgId = emit("IFCORGANIZATION($,'RoomMaquette',$,$,$)")
        let pAndOId = emit("IFCPERSONANDORGANIZATION(#\(personId),#\(orgId),$)")
        let appId = emit("IFCAPPLICATION(#\(orgId),'2.0','RoomMaquette','RoomMaquette')")
        let timestamp = Int(Date().timeIntervalSince1970)
        let ownerHistoryId = emit("IFCOWNERHISTORY(#\(pAndOId),#\(appId),$,.NOCHANGE.,$,#\(pAndOId),#\(appId),\(timestamp))")
        
        let lenUnitId = emit("IFCSIUNIT(*,.LENGTHUNIT.,$,.METRE.)")
        let areaUnitId = emit("IFCSIUNIT(*,.AREAUNIT.,$,.SQUARE_METRE.)")
        let volUnitId = emit("IFCSIUNIT(*,.VOLUMEUNIT.,$,.CUBIC_METRE.)")
        let angUnitId = emit("IFCSIUNIT(*,.PLANEANGLEUNIT.,$,.RADIAN.)")
        let unitAssignId = emit("IFCUNITASSIGNMENT((#\(lenUnitId),#\(areaUnitId),#\(volUnitId),#\(angUnitId)))")
        
        // 2. Global Context (Z-up right-handed BIM coordinate system)
        let originPtId = emit("IFCCARTESIANPOINT((0.,0.,0.))")
        let dirZId = emit("IFCDIRECTION((0.,0.,1.))")
        let dirXId = emit("IFCDIRECTION((1.,0.,0.))")
        let worldAxisId = emit("IFCAXIS2PLACEMENT3D(#\(originPtId),#\(dirZId),#\(dirXId))")
        let contextId = emit("IFCGEOMETRICREPRESENTATIONCONTEXT($,'Model',3,1.E-05,#\(worldAxisId),$)")
        let subContextId = emit("IFCGEOMETRICREPRESENTATIONSUBCONTEXT('Body','Model',*,*,*,*,#\(contextId),$,.MODEL_VIEW.,$)")
        
        // Helper: create placement + extruded rectangular solid in IFC (Z-up: ifcX = roomX, ifcY = -roomZ, ifcZ = roomY)
        func createBoxProductShape(
            roomCenter: SIMD3<Float>,
            length: Float,
            thickness: Float,
            height: Float,
            roomYaw: Float,
            parentPlacementId: Int
        ) -> (placementId: Int, shapeId: Int) {
            let baseZ = roomCenter.y - height * 0.5
            let locPtId = emit("IFCCARTESIANPOINT((\(fmt(roomCenter.x)),\(fmt(-roomCenter.z)),\(fmt(baseZ))))")
            // Room horizontal axis col0 = (cos(rotY), 0, sin(rotY)) -> in IFC (cos(rotY), -sin(rotY), 0)
            let refX = cos(roomYaw)
            let refY = -sin(roomYaw)
            let refDirId = emit("IFCDIRECTION((\(fmt(refX)),\(fmt(refY)),0.))")
            let ax3dId = emit("IFCAXIS2PLACEMENT3D(#\(locPtId),#\(dirZId),#\(refDirId))")
            let placementId = emit("IFCLOCALPLACEMENT(#\(parentPlacementId),#\(ax3dId))")
            
            let p2dPtId = emit("IFCCARTESIANPOINT((0.,0.))")
            let p2dDirId = emit("IFCDIRECTION((1.,0.))")
            let p2dAxId = emit("IFCAXIS2PLACEMENT2D(#\(p2dPtId),#\(p2dDirId))")
            let rectProfId = emit("IFCRECTANGLEPROFILEDEF(.AREA.,$,#\(p2dAxId),\(fmt(max(length, 0.05))),\(fmt(max(thickness, 0.04))))")
            
            let solidAxId = emit("IFCAXIS2PLACEMENT3D(#\(originPtId),#\(dirZId),#\(dirXId))")
            let solidId = emit("IFCEXTRUDEDAREASOLID(#\(rectProfId),#\(solidAxId),#\(dirZId),\(fmt(max(height, 0.05))))")
            let shapeRepId = emit("IFCSHAPEREPRESENTATION(#\(subContextId),'Body','SweptSolid',(#\(solidId)))")
            let prodShapeId = emit("IFCPRODUCTDEFINITIONSHAPE($,$,(#\(shapeRepId)))")
            return (placementId, prodShapeId)
        }
        
        // 3. Project -> Site -> Building -> Storey Hierarchy
        let projectId = emit("IFCPROJECT('\(ifcGuid())',#\(ownerHistoryId),'\(esc(room.name))',$,$,$,$,(#\(contextId)),#\(unitAssignId))")
        
        let sitePlaceId = emit("IFCLOCALPLACEMENT($,#\(worldAxisId))")
        let siteId = emit("IFCSITE('\(ifcGuid())',#\(ownerHistoryId),'Site',$,$,#\(sitePlaceId),$,$,.ELEMENT.,$,$,$,$,$)")
        
        let bldgAxId = emit("IFCAXIS2PLACEMENT3D(#\(originPtId),#\(dirZId),#\(dirXId))")
        let bldgPlaceId = emit("IFCLOCALPLACEMENT(#\(sitePlaceId),#\(bldgAxId))")
        let buildingId = emit("IFCBUILDING('\(ifcGuid())',#\(ownerHistoryId),'Building',$,$,#\(bldgPlaceId),$,$,.ELEMENT.,$,$,$)")
        
        let storeyAxId = emit("IFCAXIS2PLACEMENT3D(#\(originPtId),#\(dirZId),#\(dirXId))")
        let storeyPlaceId = emit("IFCLOCALPLACEMENT(#\(bldgPlaceId),#\(storeyAxId))")
        let storeyId = emit("IFCBUILDINGSTOREY('\(ifcGuid())',#\(ownerHistoryId),'Ground Floor',$,$,#\(storeyPlaceId),$,$,.ELEMENT.,0.)")
        
        emit("IFCRELAGGREGATES('\(ifcGuid())',#\(ownerHistoryId),$,$,#\(projectId),(#\(siteId)))")
        emit("IFCRELAGGREGATES('\(ifcGuid())',#\(ownerHistoryId),$,$,#\(siteId),(#\(buildingId)))")
        emit("IFCRELAGGREGATES('\(ifcGuid())',#\(ownerHistoryId),$,$,#\(buildingId),(#\(storeyId)))")
        
        var containedElementIds: [Int] = []
        
        // 4. Floor Slab
        let b = room.boundingBox
        let slabW = max(b.max.x - b.min.x, 1.0)
        let slabD = max(b.max.z - b.min.z, 1.0)
        let slabThick: Float = 0.15
        let slabCenter = SIMD3<Float>((b.min.x + b.max.x) * 0.5, b.min.y - slabThick * 0.5, (b.min.z + b.max.z) * 0.5)
        let slabGeom = createBoxProductShape(
            roomCenter: slabCenter,
            length: slabW,
            thickness: slabD,
            height: slabThick,
            roomYaw: 0,
            parentPlacementId: storeyPlaceId
        )
        let slabId = emit("IFCSLAB('\(ifcGuid())',#\(ownerHistoryId),'Floor Slab',$,$,#\(slabGeom.placementId),#\(slabGeom.shapeId),$,.FLOOR.)")
        containedElementIds.append(slabId)
        
        // 5. Walls
        var wallRecords: [(wall: WallSurface, ifcId: Int)] = []
        for (idx, wall) in room.walls.enumerated() {
            let geom = createBoxProductShape(
                roomCenter: wall.position,
                length: wall.length,
                thickness: wall.thickness,
                height: wall.height,
                roomYaw: wall.transform.rotationY,
                parentPlacementId: storeyPlaceId
            )
            let wallName = esc("\(wall.displayName) \(idx + 1)")
            let wallId = emit("IFCWALL('\(ifcGuid())',#\(ownerHistoryId),'\(wallName)',$,$,#\(geom.placementId),#\(geom.shapeId),$,.STANDARD.)")
            wallRecords.append((wall: wall, ifcId: wallId))
            containedElementIds.append(wallId)
        }
        
        // Helper to locate nearest host wall for door/window/opening voiding
        func findHostWallId(at pos: SIMD3<Float>, parentId: UUID?) -> Int? {
            if let pid = parentId, let match = wallRecords.first(where: { $0.wall.id == pid }) {
                return match.ifcId
            }
            let p2 = SIMD2<Float>(pos.x, pos.z)
            var bestId: Int? = nil
            var bestDist: Float = 0.45
            for rec in wallRecords {
                let s = rec.wall.startPoint2D
                let e = rec.wall.endPoint2D
                let d = pointToSegmentDistance(p: p2, a: SIMD2<Float>(Float(s.x), Float(s.y)), b: SIMD2<Float>(Float(e.x), Float(e.y)))
                if d < bestDist {
                    bestDist = d
                    bestId = rec.ifcId
                }
            }
            return bestId
        }
        
        // 6. Doors (with Opening Void + RelFillsElement when hosted in a wall)
        for (idx, door) in room.doors.enumerated() {
            let geom = createBoxProductShape(
                roomCenter: door.position,
                length: door.width,
                thickness: max(door.dimensions.z, 0.08),
                height: door.height,
                roomYaw: door.transform.rotationY,
                parentPlacementId: storeyPlaceId
            )
            let doorId = emit("IFCDOOR('\(ifcGuid())',#\(ownerHistoryId),'Door \(idx + 1)',$,$,#\(geom.placementId),#\(geom.shapeId),$,\(fmt(door.height)),\(fmt(door.width)),.DOOR.,.SINGLE_SWING_LEFT.,$)")
            containedElementIds.append(doorId)
            
            if let hostWallId = findHostWallId(at: door.position, parentId: door.parentWallId) {
                let voidGeom = createBoxProductShape(
                    roomCenter: door.position,
                    length: door.width,
                    thickness: 0.35,
                    height: door.height,
                    roomYaw: door.transform.rotationY,
                    parentPlacementId: storeyPlaceId
                )
                let openingId = emit("IFCOPENINGELEMENT('\(ifcGuid())',#\(ownerHistoryId),'Door Opening \(idx + 1)',$,$,#\(voidGeom.placementId),#\(voidGeom.shapeId),$,.OPENING.)")
                emit("IFCRELVOIDSELEMENT('\(ifcGuid())',#\(ownerHistoryId),$,$,#\(hostWallId),#\(openingId))")
                emit("IFCRELFILLSELEMENT('\(ifcGuid())',#\(ownerHistoryId),$,$,#\(openingId),#\(doorId))")
            }
        }
        
        // 7. Windows (with Opening Void + RelFillsElement when hosted in a wall)
        for (idx, win) in room.windows.enumerated() {
            let geom = createBoxProductShape(
                roomCenter: win.position,
                length: win.width,
                thickness: max(win.dimensions.z, 0.08),
                height: win.height,
                roomYaw: win.transform.rotationY,
                parentPlacementId: storeyPlaceId
            )
            let winId = emit("IFCWINDOW('\(ifcGuid())',#\(ownerHistoryId),'Window \(idx + 1)',$,$,#\(geom.placementId),#\(geom.shapeId),$,\(fmt(win.height)),\(fmt(win.width)),.WINDOW.,.SINGLE_PANEL.,$)")
            containedElementIds.append(winId)
            
            if let hostWallId = findHostWallId(at: win.position, parentId: win.parentWallId) {
                let voidGeom = createBoxProductShape(
                    roomCenter: win.position,
                    length: win.width,
                    thickness: 0.35,
                    height: win.height,
                    roomYaw: win.transform.rotationY,
                    parentPlacementId: storeyPlaceId
                )
                let openingId = emit("IFCOPENINGELEMENT('\(ifcGuid())',#\(ownerHistoryId),'Window Opening \(idx + 1)',$,$,#\(voidGeom.placementId),#\(voidGeom.shapeId),$,.OPENING.)")
                emit("IFCRELVOIDSELEMENT('\(ifcGuid())',#\(ownerHistoryId),$,$,#\(hostWallId),#\(openingId))")
                emit("IFCRELFILLSELEMENT('\(ifcGuid())',#\(ownerHistoryId),$,$,#\(openingId),#\(winId))")
            }
        }
        
        // 8. Pass-Through Openings
        for (idx, op) in room.openings.enumerated() {
            if let hostWallId = findHostWallId(at: op.position, parentId: op.parentWallId) {
                let voidGeom = createBoxProductShape(
                    roomCenter: op.position,
                    length: op.width,
                    thickness: 0.35,
                    height: op.height,
                    roomYaw: op.transform.rotationY,
                    parentPlacementId: storeyPlaceId
                )
                let openingId = emit("IFCOPENINGELEMENT('\(ifcGuid())',#\(ownerHistoryId),'Wall Opening \(idx + 1)',$,$,#\(voidGeom.placementId),#\(voidGeom.shapeId),$,.OPENING.)")
                emit("IFCRELVOIDSELEMENT('\(ifcGuid())',#\(ownerHistoryId),$,$,#\(hostWallId),#\(openingId))")
            }
        }
        
        // 9. Furniture & Fixtures
        for obj in room.objects {
            let geom = createBoxProductShape(
                roomCenter: obj.position,
                length: obj.width,
                thickness: obj.depth,
                height: obj.height,
                roomYaw: obj.rotationY,
                parentPlacementId: storeyPlaceId
            )
            let predef = ifcFurnitureType(for: obj.category)
            let objId = emit("IFCFURNITURE('\(ifcGuid())',#\(ownerHistoryId),'\(esc(obj.displayName))',$,'\(esc(obj.category.displayName))',#\(geom.placementId),#\(geom.shapeId),$,\(predef))")
            containedElementIds.append(objId)
        }
        
        // 10. Link all building elements to Storey
        if !containedElementIds.isEmpty {
            let refs = containedElementIds.map { "#\($0)" }.joined(separator: ",")
            emit("IFCRELCONTAINEDINSPATIALSTRUCTURE('\(ifcGuid())',#\(ownerHistoryId),$,$,(\(refs)),#\(storeyId))")
        }
        
        // 11. Spatial Metrics Property Set attached to BuildingStorey
        let pArea = emit("IFCPROPERTYSINGLEVALUE('FloorAreaMeters2',$,IFCAREAMEASURE(\(fmt(room.floorAreaSquareMeters))),$)")
        let pVol = emit("IFCPROPERTYSINGLEVALUE('InternalVolumeMeters3',$,IFCVOLUMEMEASURE(\(fmt(room.volumeCubicMeters))),$)")
        let pPerim = emit("IFCPROPERTYSINGLEVALUE('WallPerimeterMeters',$,IFCLENGTHMEASURE(\(fmt(room.perimeterMeters))),$)")
        let pHeight = emit("IFCPROPERTYSINGLEVALUE('CeilingHeightMeters',$,IFCLENGTHMEASURE(\(fmt(room.ceilingHeight))),$)")
        let psetId = emit("IFCPROPERTYSET('\(ifcGuid())',#\(ownerHistoryId),'Pset_RoomMaquetteMetrics',$,(#\(pArea),#\(pVol),#\(pPerim),#\(pHeight)))")
        emit("IFCRELDEFINESBYPROPERTIES('\(ifcGuid())',#\(ownerHistoryId),$,$,(#\(storeyId)),#\(psetId))")
        
        // Assemble ISO-10303-21 STEP Physical File
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let dateStr = isoFormatter.string(from: Date())
        
        var step = ""
        step += "ISO-10303-21;\n"
        step += "HEADER;\n"
        step += "FILE_DESCRIPTION(('ViewDefinition [CoordinationView_V2.0]'),'2;1');\n"
        step += "FILE_NAME('\(baseName).ifc','\(dateStr)',('RoomMaquette User'),('RoomMaquette App'),'RoomMaquette iOS','RoomMaquette','');\n"
        step += "FILE_SCHEMA(('IFC4'));\n"
        step += "ENDSEC;\n"
        step += "DATA;\n"
        step += lines.joined(separator: "\n")
        step += "\nENDSEC;\n"
        step += "END-ISO-10303-21;\n"
        
        try step.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }
    
    // MARK: - Helpers
    
    private static func ifcFurnitureType(for cat: ObjectCategory) -> String {
        switch cat {
        case .chair: return ".CHAIR."
        case .sofa: return ".SOFA."
        case .table: return ".TABLE."
        case .desk: return ".DESK."
        case .bed: return ".BED."
        case .storage: return ".SHELF."
        default: return ".NOTDEFINED."
        }
    }
    
    private static func pointToSegmentDistance(p: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lenSq = simd_length_squared(ab)
        if lenSq < 1e-6 { return simd_distance(p, a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / lenSq))
        return simd_distance(p, a + t * ab)
    }
    
    /// Generates a valid 22-character IFC Base64 GlobalId from a UUID
    private static func ifcGuid() -> String {
        let uuid = UUID().uuid
        let bytes: [UInt8] = [
            uuid.0, uuid.1, uuid.2, uuid.3,
            uuid.4, uuid.5, uuid.6, uuid.7,
            uuid.8, uuid.9, uuid.10, uuid.11,
            uuid.12, uuid.13, uuid.14, uuid.15
        ]
        
        var num: [UInt32] = Array(repeating: 0, count: 6)
        num[0] = UInt32(bytes[0])
        num[1] = (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        num[2] = (UInt32(bytes[4]) << 16) | (UInt32(bytes[5]) << 8) | UInt32(bytes[6])
        num[3] = (UInt32(bytes[7]) << 16) | (UInt32(bytes[8]) << 8) | UInt32(bytes[9])
        num[4] = (UInt32(bytes[10]) << 16) | (UInt32(bytes[11]) << 8) | UInt32(bytes[12])
        num[5] = (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
        
        var result = ""
        result.reserveCapacity(22)
        
        func appendEncoded(_ value: UInt32, digits: Int) {
            var v = value
            var chars: [Character] = []
            for _ in 0..<digits {
                chars.append(ifcBase64Chars[Int(v & 0x3F)])
                v >>= 6
            }
            for c in chars.reversed() {
                result.append(c)
            }
        }
        
        appendEncoded(num[0], digits: 2)
        for i in 1..<6 {
            appendEncoded(num[i], digits: 4)
        }
        return result
    }
}
