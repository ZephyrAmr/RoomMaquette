import Foundation
import simd

public class GLTFExporter {
    
    public static func export(room: MaquetteRoom) throws -> URL {
        let safeName = ExportManager.sanitizedFileName(from: room.name)
        let baseName = "\(safeName)_\(Int(Date().timeIntervalSince1970))"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName).gltf")
        
        var binaryBuffer = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var meshes: [[String: Any]] = []
        var nodes: [[String: Any]] = []
        var materials: [[String: Any]] = []
        
        // Material 0: Wall
        materials.append([
            "name": "WallMaterial",
            "pbrMetallicRoughness": [
                "baseColorFactor": [0.92, 0.91, 0.89, 1.0],
                "roughnessFactor": 0.85,
                "metallicFactor": 0.05
            ]
        ])
        
        // Material 1: Floor
        materials.append([
            "name": "FloorMaterial",
            "pbrMetallicRoughness": [
                "baseColorFactor": [0.85, 0.84, 0.82, 1.0],
                "roughnessFactor": 0.9,
                "metallicFactor": 0.0
            ]
        ])
        
        // Material 2: Furniture
        materials.append([
            "name": "FurnitureMaterial",
            "pbrMetallicRoughness": [
                "baseColorFactor": [0.80, 0.76, 0.70, 1.0],
                "roughnessFactor": 0.6,
                "metallicFactor": 0.1
            ]
        ])
        
        // Unit Box definition (1x1x1 cube centered at origin)
        let unitPositions: [Float] = [
            // Front face
            -0.5, -0.5,  0.5,   0.5, -0.5,  0.5,   0.5,  0.5,  0.5,  -0.5,  0.5,  0.5,
            // Back face
            -0.5, -0.5, -0.5,  -0.5,  0.5, -0.5,   0.5,  0.5, -0.5,   0.5, -0.5, -0.5,
            // Top face
            -0.5,  0.5, -0.5,  -0.5,  0.5,  0.5,   0.5,  0.5,  0.5,   0.5,  0.5, -0.5,
            // Bottom face
            -0.5, -0.5, -0.5,   0.5, -0.5, -0.5,   0.5, -0.5,  0.5,  -0.5, -0.5,  0.5,
            // Right face
             0.5, -0.5, -0.5,   0.5,  0.5, -0.5,   0.5,  0.5,  0.5,   0.5, -0.5,  0.5,
            // Left face
            -0.5, -0.5, -0.5,  -0.5, -0.5,  0.5,  -0.5,  0.5,  0.5,  -0.5,  0.5, -0.5
        ]
        
        let unitNormals: [Float] = [
             0,  0,  1,   0,  0,  1,   0,  0,  1,   0,  0,  1,
             0,  0, -1,   0,  0, -1,   0,  0, -1,   0,  0, -1,
             0,  1,  0,   0,  1,  0,   0,  1,  0,   0,  1,  0,
             0, -1,  0,   0, -1,  0,   0, -1,  0,   0, -1,  0,
             1,  0,  0,   1,  0,  0,   1,  0,  0,   1,  0,  0,
            -1,  0,  0,  -1,  0,  0,  -1,  0,  0,  -1,  0,  0
        ]
        
        let unitIndices: [UInt16] = [
             0,  1,  2,   0,  2,  3, // Front
             4,  5,  6,   4,  6,  7, // Back
             8,  9, 10,   8, 10, 11, // Top
            12, 13, 14,  12, 14, 15, // Bottom
            16, 17, 18,  16, 18, 19, // Right
            20, 21, 22,  20, 22, 23  // Left
        ]
        
        // Write Box Geometry to Buffer
        // 1. Position BufferView & Accessor
        let posOffset = binaryBuffer.count
        unitPositions.withUnsafeBytes { binaryBuffer.append(contentsOf: $0) }
        let posLength = unitPositions.count * 4
        
        bufferViews.append([
            "buffer": 0,
            "byteOffset": posOffset,
            "byteLength": posLength,
            "target": 34962 // ARRAY_BUFFER
        ])
        accessors.append([
            "bufferView": 0,
            "byteOffset": 0,
            "componentType": 5126, // FLOAT
            "count": 24,
            "type": "VEC3",
            "max": [0.5, 0.5, 0.5],
            "min": [-0.5, -0.5, -0.5]
        ])
        
        // 2. Normal BufferView & Accessor
        let normOffset = binaryBuffer.count
        unitNormals.withUnsafeBytes { binaryBuffer.append(contentsOf: $0) }
        let normLength = unitNormals.count * 4
        
        bufferViews.append([
            "buffer": 0,
            "byteOffset": normOffset,
            "byteLength": normLength,
            "target": 34962
        ])
        accessors.append([
            "bufferView": 1,
            "byteOffset": 0,
            "componentType": 5126,
            "count": 24,
            "type": "VEC3",
            "max": [1.0, 1.0, 1.0],
            "min": [-1.0, -1.0, -1.0]
        ])
        
        // 3. Index BufferView & Accessor
        let idxOffset = binaryBuffer.count
        unitIndices.withUnsafeBytes { binaryBuffer.append(contentsOf: $0) }
        let idxLength = unitIndices.count * 2
        
        bufferViews.append([
            "buffer": 0,
            "byteOffset": idxOffset,
            "byteLength": idxLength,
            "target": 34963 // ELEMENT_ARRAY_BUFFER
        ])
        accessors.append([
            "bufferView": 2,
            "byteOffset": 0,
            "componentType": 5123, // UNSIGNED_SHORT
            "count": 36,
            "type": "SCALAR",
            "max": [23],
            "min": [0]
        ])
        
        // Meshes for each material type
        // Mesh 0: Wall Box
        meshes.append([
            "name": "WallBoxMesh",
            "primitives": [[
                "attributes": ["POSITION": 0, "NORMAL": 1],
                "indices": 2,
                "material": 0
            ]]
        ])
        // Mesh 1: Floor Box
        meshes.append([
            "name": "FloorBoxMesh",
            "primitives": [[
                "attributes": ["POSITION": 0, "NORMAL": 1],
                "indices": 2,
                "material": 1
            ]]
        ])
        // Mesh 2: Furniture Box
        meshes.append([
            "name": "FurnitureBoxMesh",
            "primitives": [[
                "attributes": ["POSITION": 0, "NORMAL": 1],
                "indices": 2,
                "material": 2
            ]]
        ])
        
        var nodeIndices: [Int] = []
        
        // Helper to add node
        func addNode(name: String, meshIndex: Int, dimensions: SIMD3<Float>, transform: simd_float4x4) {
            let nodeIdx = nodes.count
            nodeIndices.append(nodeIdx)
            
            // Extract position, rotation quaternion, scale
            let pos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let rotY = atan2(transform.columns.0.z, transform.columns.0.x)
            let halfAngle = rotY / 2.0
            let q = [0.0, sin(halfAngle), 0.0, cos(halfAngle)]
            
            nodes.append([
                "name": name,
                "mesh": meshIndex,
                "translation": [pos.x, pos.y, pos.z],
                "rotation": q,
                "scale": [dimensions.x, dimensions.y, dimensions.z]
            ])
        }
        
        // Add Floor
        let b = room.boundingBox
        let margin: Float = 0.5
        let floorW = (b.max.x - b.min.x) + margin * 2
        let floorD = (b.max.z - b.min.z) + margin * 2
        let floorH: Float = 0.08
        var floorMatrix = matrix_identity_float4x4
        floorMatrix.columns.3 = SIMD4<Float>((b.min.x + b.max.x)/2.0, -floorH/2.0, (b.min.z + b.max.z)/2.0, 1)
        addNode(name: "FloorPlinth", meshIndex: 1, dimensions: SIMD3<Float>(floorW, floorH, floorD), transform: floorMatrix)
        
        // Add Walls
        for (i, wall) in room.walls.enumerated() {
            addNode(name: "Wall_\(i+1)", meshIndex: 0, dimensions: SIMD3<Float>(wall.length, wall.height, wall.thickness), transform: wall.transform.matrix)
        }
        
        // Add Furniture
        for (i, obj) in room.objects.enumerated() {
            addNode(name: "Furniture_\(obj.category.rawValue)_\(i+1)", meshIndex: 2, dimensions: obj.dimensions, transform: obj.transform.matrix)
        }
        
        // Construct GLTF JSON
        let base64Buffer = binaryBuffer.base64EncodedString()
        let gltfDict: [String: Any] = [
            "asset": [
                "version": "2.0",
                "generator": "RoomMaquette for iOS"
            ],
            "scene": 0,
            "scenes": [[
                "name": room.name,
                "nodes": nodeIndices
            ]],
            "nodes": nodes,
            "meshes": meshes,
            "materials": materials,
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [[
                "byteLength": binaryBuffer.count,
                "uri": "data:application/octet-stream;base64,\(base64Buffer)"
            ]]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: gltfDict, options: [.prettyPrinted])
        try jsonData.write(to: outputURL)
        
        return outputURL
    }
}
