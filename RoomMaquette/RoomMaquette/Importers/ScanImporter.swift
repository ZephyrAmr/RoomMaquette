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
    
    private static func importUSDZ(from url: URL, roomName: String) throws -> MaquetteRoom {
        guard let data = try? Data(contentsOf: url) else {
            throw ScanImportError.unreadableData
        }
        
        // Copy to temporary location for SceneKit reading
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("import_\(UUID().uuidString).usdz")
        try? data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        var walls: [WallSurface] = []
        var doors: [DoorSurface] = []
        var windows: [WindowSurface] = []
        var objects: [FurnitureObject] = []
        
        var minPt = SIMD3<Float>(.infinity, .infinity, .infinity)
        var maxPt = SIMD3<Float>(-.infinity, -.infinity, -.infinity)
        
        if let scene = try? SCNScene(url: tempURL, options: nil) {
            let (bMin, bMax) = scene.rootNode.boundingBox
            if bMin.x < bMax.x && bMin.z < bMax.z {
                minPt = SIMD3<Float>(bMin.x, bMin.y, bMin.z)
                maxPt = SIMD3<Float>(bMax.x, bMax.y, bMax.z)
            }
            
            // Search child nodes for architectural features or furniture
            scene.rootNode.enumerateChildNodes { node, _ in
                guard let name = node.name?.lowercased() else { return }
                let pos = SIMD3<Float>(node.position.x, node.position.y, node.position.z)
                let (cMin, cMax) = node.boundingBox
                let w = max(abs(cMax.x - cMin.x), 0.5)
                let h = max(abs(cMax.y - cMin.y), 0.5)
                let d = max(abs(cMax.z - cMin.z), 0.5)
                let dims = SIMD3<Float>(w, h, d)
                
                if name.contains("door") {
                    var mat = matrix_identity_float4x4
                    mat.columns.3 = SIMD4<Float>(pos.x, pos.y, pos.z, 1.0)
                    doors.append(DoorSurface(id: UUID(), dimensions: dims, transform: mat, isOpen: true))
                } else if name.contains("window") {
                    var mat = matrix_identity_float4x4
                    mat.columns.3 = SIMD4<Float>(pos.x, pos.y, pos.z, 1.0)
                    windows.append(WindowSurface(id: UUID(), dimensions: dims, transform: mat))
                } else if name.contains("chair") || name.contains("table") || name.contains("sofa") || name.contains("bed") || name.contains("desk") {
                    let cat: ObjectCategory = name.contains("bed") ? .bed : (name.contains("sofa") ? .sofa : (name.contains("table") ? .table : .chair))
                    var mat = matrix_identity_float4x4
                    mat.columns.3 = SIMD4<Float>(pos.x, pos.y, pos.z, 1.0)
                    objects.append(FurnitureObject(
                        id: UUID(),
                        category: cat,
                        customName: node.name ?? "Furniture",
                        dimensions: dims,
                        transform: mat
                    ))
                }
            }
        }
        
        // If bounding box was invalid or empty, set reasonable defaults
        if minPt.x >= maxPt.x || minPt.z >= maxPt.z {
            minPt = SIMD3<Float>(-2.0, 0.0, -2.5)
            maxPt = SIMD3<Float>(2.0, 2.7, 2.5)
        }
        
        let width = maxPt.x - minPt.x
        let depth = maxPt.z - minPt.z
        let height = max(maxPt.y - minPt.y, 2.5)
        let midX = (minPt.x + maxPt.x) / 2.0
        let midZ = (minPt.z + maxPt.z) / 2.0
        
        // Synthesize 4 enclosing architectural walls if none were extracted
        if walls.isEmpty {
            // North wall (along top, Z min)
            var nMat = matrix_identity_float4x4
            nMat.columns.3 = SIMD4<Float>(midX, height / 2.0, minPt.z, 1.0)
            walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(width, height, 0.15), transform: nMat))
            
            // South wall (along bottom, Z max)
            var sMat = matrix_identity_float4x4
            sMat.columns.3 = SIMD4<Float>(midX, height / 2.0, maxPt.z, 1.0)
            walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(width, height, 0.15), transform: sMat))
            
            // East wall (along right, X max, rotated 90 degrees)
            let rot90 = simd_float4x4(
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-1, 0, 0, 0),
                SIMD4<Float>(maxPt.x, height / 2.0, midZ, 1)
            )
            walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(depth, height, 0.15), transform: rot90))
            
            // West wall (along left, X min, rotated 90 degrees)
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
            notes: "Imported from 3D USDZ scan file",
            walls: walls,
            doors: doors,
            windows: windows,
            objects: objects,
            usdzData: data
        )
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
