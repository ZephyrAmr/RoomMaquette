import Foundation
import simd

public class OBJExporter {
    
    public static func export(room: MaquetteRoom) throws -> (objURL: URL, mtlURL: URL) {
        let safeName = ExportManager.sanitizedFileName(from: room.name)
        let baseName = "\(safeName)_\(Int(Date().timeIntervalSince1970))"
        let objURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName).obj")
        let mtlURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName).mtl")
        
        var objContent = ""
        var mtlContent = ""
        
        // Header
        objContent += "# RoomMaquette Wavefront OBJ Exporter\n"
        objContent += "# Project: \(room.name)\n"
        objContent += "# Date: \(Date())\n"
        objContent += "mtllib \(mtlURL.lastPathComponent)\n\n"
        
        mtlContent += "# RoomMaquette Material Library\n\n"
        
        // Base materials in MTL
        mtlContent += """
        newmtl WallMaterial
        Kd 0.92 0.91 0.89
        Ka 0.2 0.2 0.2
        Ks 0.1 0.1 0.1
        d 1.0
        illum 2

        newmtl FloorMaterial
        Kd 0.85 0.84 0.82
        Ka 0.2 0.2 0.2
        Ks 0.1 0.1 0.1
        d 1.0
        illum 2

        newmtl GlassMaterial
        Kd 0.7 0.85 0.95
        Ka 0.1 0.2 0.3
        Ks 0.9 0.9 0.9
        Ns 100.0
        d 0.35
        illum 4

        newmtl DoorMaterial
        Kd 0.75 0.58 0.44
        Ka 0.2 0.2 0.2
        Ks 0.1 0.1 0.1
        d 1.0
        illum 2

        """
        
        var vertexOffset = 1
        var normalOffset = 1
        
        // Normals (6 standard cube face normals)
        let normals: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 1),   // Front
            SIMD3<Float>(0, 0, -1),  // Back
            SIMD3<Float>(-1, 0, 0),  // Left
            SIMD3<Float>(1, 0, 0),   // Right
            SIMD3<Float>(0, 1, 0),   // Top
            SIMD3<Float>(0, -1, 0)   // Bottom
        ]
        
        for n in normals {
            objContent += "vn \(n.x) \(n.y) \(n.z)\n"
        }
        normalOffset = 1 // Normals are 1..6
        
        // Helper to append a 3D box
        func appendBox(
            name: String,
            material: String,
            dimensions: SIMD3<Float>,
            transform: simd_float4x4
        ) {
            objContent += "\ng \(name)\n"
            objContent += "usemtl \(material)\n"
            
            let hx = dimensions.x / 2.0
            let hy = dimensions.y / 2.0
            let hz = dimensions.z / 2.0
            
            // 8 local vertices
            let localVertices: [SIMD4<Float>] = [
                SIMD4<Float>(-hx, -hy,  hz, 1), // 0: Front-bottom-left
                SIMD4<Float>( hx, -hy,  hz, 1), // 1: Front-bottom-right
                SIMD4<Float>( hx,  hy,  hz, 1), // 2: Front-top-right
                SIMD4<Float>(-hx,  hy,  hz, 1), // 3: Front-top-left
                SIMD4<Float>(-hx, -hy, -hz, 1), // 4: Back-bottom-left
                SIMD4<Float>( hx, -hy, -hz, 1), // 5: Back-bottom-right
                SIMD4<Float>( hx,  hy, -hz, 1), // 6: Back-top-right
                SIMD4<Float>(-hx,  hy, -hz, 1)  // 7: Back-top-left
            ]
            
            // Transform to world space
            for lv in localVertices {
                let wv = transform * lv
                objContent += "v \(String(format: "%.4f %.4f %.4f", wv.x, wv.y, wv.z))\n"
            }
            
            let base = vertexOffset
            // 12 Triangles (2 per face)
            // Front face (vn 1)
            objContent += "f \(base)//1 \(base+1)//1 \(base+2)//1\n"
            objContent += "f \(base)//1 \(base+2)//1 \(base+3)//1\n"
            // Back face (vn 2)
            objContent += "f \(base+5)//2 \(base+4)//2 \(base+7)//2\n"
            objContent += "f \(base+5)//2 \(base+7)//2 \(base+6)//2\n"
            // Left face (vn 3)
            objContent += "f \(base+4)//3 \(base)//3 \(base+3)//3\n"
            objContent += "f \(base+4)//3 \(base+3)//3 \(base+7)//3\n"
            // Right face (vn 4)
            objContent += "f \(base+1)//4 \(base+5)//4 \(base+6)//4\n"
            objContent += "f \(base+1)//4 \(base+6)//4 \(base+2)//4\n"
            // Top face (vn 5)
            objContent += "f \(base+3)//5 \(base+2)//5 \(base+6)//5\n"
            objContent += "f \(base+3)//5 \(base+6)//5 \(base+7)//5\n"
            // Bottom face (vn 6)
            objContent += "f \(base+4)//6 \(base+5)//6 \(base+1)//6\n"
            objContent += "f \(base+4)//6 \(base+1)//6 \(base)//6\n"
            
            vertexOffset += 8
        }
        
        // 1. Floor Plinth
        let b = room.boundingBox
        let margin: Float = 0.5
        let floorW = (b.max.x - b.min.x) + margin * 2
        let floorD = (b.max.z - b.min.z) + margin * 2
        let floorH: Float = 0.08
        let floorCenter = SIMD3<Float>((b.min.x + b.max.x)/2.0, -floorH/2.0, (b.min.z + b.max.z)/2.0)
        
        var floorMatrix = matrix_identity_float4x4
        floorMatrix.columns.3 = SIMD4<Float>(floorCenter.x, floorCenter.y, floorCenter.z, 1)
        appendBox(name: "FloorPlinth", material: "FloorMaterial", dimensions: SIMD3<Float>(floorW, floorH, floorD), transform: floorMatrix)
        
        // 2. Walls
        for (i, wall) in room.walls.enumerated() {
            appendBox(name: "Wall_\(i+1)", material: "WallMaterial", dimensions: SIMD3<Float>(wall.length, wall.height, wall.thickness), transform: wall.transform.matrix)
        }
        
        // 3. Doors
        for (i, door) in room.doors.enumerated() {
            appendBox(name: "Door_\(i+1)", material: "DoorMaterial", dimensions: SIMD3<Float>(door.width, door.height, 0.04), transform: door.transform.matrix)
        }
        
        // 4. Windows
        for (i, win) in room.windows.enumerated() {
            appendBox(name: "Window_\(i+1)", material: "GlassMaterial", dimensions: SIMD3<Float>(win.width, win.height, 0.05), transform: win.transform.matrix)
        }
        
        // 5. Furniture Objects
        for (i, obj) in room.objects.enumerated() {
            let matName = "Mat_\(obj.category.rawValue)"
            mtlContent += """
            newmtl \(matName)
            Kd 0.8 0.75 0.7
            Ka 0.2 0.2 0.2
            Ks 0.2 0.2 0.2
            d 1.0
            illum 2

            """
            appendBox(name: "Furniture_\(obj.category.rawValue)_\(i+1)", material: matName, dimensions: obj.dimensions, transform: obj.transform.matrix)
        }
        
        try objContent.write(to: objURL, atomically: true, encoding: .utf8)
        try mtlContent.write(to: mtlURL, atomically: true, encoding: .utf8)
        
        return (objURL, mtlURL)
    }
}
