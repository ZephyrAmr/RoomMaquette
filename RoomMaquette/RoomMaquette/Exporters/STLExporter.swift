import Foundation
import simd

public class STLExporter {
    
    public struct Triangle {
        public var normal: SIMD3<Float>
        public var v1: SIMD3<Float>
        public var v2: SIMD3<Float>
        public var v3: SIMD3<Float>
    }
    
    /// Exports the room maquette as an STL file (ideal for 3D printing miniature architectural models)
    public static func export(room: MaquetteRoom, binary: Bool = true) throws -> URL {
        let baseName = "\(room.name.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970))"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName).stl")
        
        var triangles: [Triangle] = []
        
        // Helper to generate triangles for an oriented 3D box
        func addBox(dimensions: SIMD3<Float>, transform: simd_float4x4) {
            let hx = dimensions.x / 2.0
            let hy = dimensions.y / 2.0
            let hz = dimensions.z / 2.0
            
            let localV: [SIMD4<Float>] = [
                SIMD4<Float>(-hx, -hy,  hz, 1), // 0
                SIMD4<Float>( hx, -hy,  hz, 1), // 1
                SIMD4<Float>( hx,  hy,  hz, 1), // 2
                SIMD4<Float>(-hx,  hy,  hz, 1), // 3
                SIMD4<Float>(-hx, -hy, -hz, 1), // 4
                SIMD4<Float>( hx, -hy, -hz, 1), // 5
                SIMD4<Float>( hx,  hy, -hz, 1), // 6
                SIMD4<Float>(-hx,  hy, -hz, 1)  // 7
            ]
            
            // World space vertices
            let wv = localV.map { v -> SIMD3<Float> in
                let w = transform * v
                return SIMD3<Float>(w.x, w.y, w.z)
            }
            
            func addQuad(i0: Int, i1: Int, i2: Int, i3: Int) {
                let v0 = wv[i0]
                let v1 = wv[i1]
                let v2 = wv[i2]
                let v3 = wv[i3]
                
                let norm1 = normalize(cross(v1 - v0, v2 - v0))
                triangles.append(Triangle(normal: norm1, v1: v0, v2: v1, v3: v2))
                
                let norm2 = normalize(cross(v2 - v0, v3 - v0))
                triangles.append(Triangle(normal: norm2, v1: v0, v2: v2, v3: v3))
            }
            
            addQuad(i0: 0, i1: 1, i2: 2, i3: 3) // Front
            addQuad(i0: 5, i1: 4, i2: 7, i3: 6) // Back
            addQuad(i0: 4, i1: 0, i2: 3, i3: 7) // Left
            addQuad(i0: 1, i1: 5, i2: 6, i3: 2) // Right
            addQuad(i0: 3, i1: 2, i2: 6, i3: 7) // Top
            addQuad(i0: 4, i1: 5, i2: 1, i3: 0) // Bottom
        }
        
        // 1. Manifold Floor Plinth
        let b = room.boundingBox
        let margin: Float = 0.4
        let floorW = (b.max.x - b.min.x) + margin * 2
        let floorD = (b.max.z - b.min.z) + margin * 2
        let floorH: Float = 0.1
        let floorCenter = SIMD3<Float>((b.min.x + b.max.x)/2.0, -floorH/2.0, (b.min.z + b.max.z)/2.0)
        
        var floorMat = matrix_identity_float4x4
        floorMat.columns.3 = SIMD4<Float>(floorCenter.x, floorCenter.y, floorCenter.z, 1)
        addBox(dimensions: SIMD3<Float>(floorW, floorH, floorD), transform: floorMat)
        
        // 2. Walls
        for wall in room.walls {
            addBox(dimensions: SIMD3<Float>(wall.length, wall.height, wall.thickness), transform: wall.transform.matrix)
        }
        
        // 3. Furniture
        for obj in room.objects {
            addBox(dimensions: obj.dimensions, transform: obj.transform.matrix)
        }
        
        if binary {
            // Write Binary STL
            var data = Data()
            // 80-byte header
            var header = [UInt8](repeating: 0, count: 80)
            let headerStr = "RoomMaquette 3D Printable STL Model"
            if let strData = headerStr.data(using: .utf8) {
                for (i, b) in strData.enumerated() where i < 80 {
                    header[i] = b
                }
            }
            data.append(contentsOf: header)
            
            // Triangle count (UInt32)
            var count = UInt32(triangles.count)
            data.append(Data(bytes: &count, count: 4))
            
            // Triangles (50 bytes each)
            var zeroAttr: UInt16 = 0
            for tri in triangles {
                var n = tri.normal
                var v1 = tri.v1
                var v2 = tri.v2
                var v3 = tri.v3
                data.append(Data(bytes: &n, count: 12))
                data.append(Data(bytes: &v1, count: 12))
                data.append(Data(bytes: &v2, count: 12))
                data.append(Data(bytes: &v3, count: 12))
                data.append(Data(bytes: &zeroAttr, count: 2))
            }
            
            try data.write(to: outputURL)
        } else {
            // Write ASCII STL
            var content = "solid RoomMaquette\n"
            for tri in triangles {
                content += "  facet normal \(tri.normal.x) \(tri.normal.y) \(tri.normal.z)\n"
                content += "    outer loop\n"
                content += "      vertex \(tri.v1.x) \(tri.v1.y) \(tri.v1.z)\n"
                content += "      vertex \(tri.v2.x) \(tri.v2.y) \(tri.v2.z)\n"
                content += "      vertex \(tri.v3.x) \(tri.v3.y) \(tri.v3.z)\n"
                content += "    endloop\n"
                content += "  endfacet\n"
            }
            content += "endsolid RoomMaquette\n"
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
        }
        
        return outputURL
    }
}
