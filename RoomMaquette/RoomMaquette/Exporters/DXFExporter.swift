import Foundation
import simd

public class DXFExporter {
    
    public static func export(room: MaquetteRoom) throws -> URL {
        let baseName = "\(room.name.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970))"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName).dxf")
        
        var dxf = ""
        
        // Header Section
        dxf += "0\nSECTION\n2\nHEADER\n"
        dxf += "9\n$ACADVER\n1\nAC1015\n" // AutoCAD 2000 format, universal compatibility
        dxf += "9\n$INSUNITS\n70\n6\n" // Meters
        dxf += "0\nENDSEC\n"
        
        // Tables Section (Layers)
        dxf += "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n"
        
        func addLayer(name: String, color: Int) {
            dxf += "0\nLAYER\n2\n\(name)\n70\n0\n62\n\(color)\n6\nCONTINUOUS\n"
        }
        
        addLayer(name: "A-WALL", color: 7) // White/Black
        addLayer(name: "A-DOOR", color: 5) // Blue
        addLayer(name: "A-GLAZ", color: 4) // Cyan
        addLayer(name: "A-FURN", color: 30) // Orange/Wood
        addLayer(name: "A-DIMS", color: 2) // Yellow
        
        dxf += "0\nENDTAB\n0\nENDSEC\n"
        
        // Entities Section
        dxf += "0\nSECTION\n2\nENTITIES\n"
        
        // Helper to add a 2D line
        func addLine(layer: String, x1: Float, y1: Float, x2: Float, y2: Float) {
            dxf += "0\nLINE\n8\n\(layer)\n"
            dxf += "10\n\(String(format: "%.4f", x1))\n20\n\(String(format: "%.4f", y1))\n30\n0.0\n"
            dxf += "11\n\(String(format: "%.4f", x2))\n21\n\(String(format: "%.4f", y2))\n31\n0.0\n"
        }
        
        // Helper to add an oriented 2D box (for walls or furniture in plan)
        func addBox2D(layer: String, center: SIMD3<Float>, width: Float, depth: Float, rotationY: Float) {
            let cosA = cos(rotationY)
            let sinA = sin(rotationY)
            let hw = width / 2.0
            let hd = depth / 2.0
            
            let corners: [(Float, Float)] = [
                (-hw, -hd),
                ( hw, -hd),
                ( hw,  hd),
                (-hw,  hd)
            ]
            
            let rotated = corners.map { (dx, dz) -> (Float, Float) in
                let rx = center.x + (dx * cosA - dz * sinA)
                let rz = center.z + (dx * sinA + dz * cosA)
                return (rx, rz)
            }
            
            for i in 0..<4 {
                let j = (i + 1) % 4
                addLine(layer: layer, x1: rotated[i].0, y1: -rotated[i].1, x2: rotated[j].0, y2: -rotated[j].1)
            }
        }
        
        // 1. Export Walls
        for wall in room.walls {
            addBox2D(
                layer: "A-WALL",
                center: wall.position,
                width: wall.length,
                depth: wall.thickness,
                rotationY: wall.transform.rotationY
            )
        }
        
        // 2. Export Doors
        for door in room.doors {
            let p = door.position
            let rot = door.transform.rotationY
            let w = door.width
            let hx = p.x - (w/2.0)*cos(rot)
            let hz = p.z - (w/2.0)*sin(rot)
            let ex = p.x + (w/2.0)*cos(rot)
            let ez = p.z + (w/2.0)*sin(rot)
            addLine(layer: "A-DOOR", x1: hx, y1: -hz, x2: ex, y2: -ez)
        }
        
        // 3. Export Windows
        for win in room.windows {
            let p = win.position
            let rot = win.transform.rotationY
            let w = win.width
            let p1x = p.x - (w/2.0)*cos(rot)
            let p1z = p.z - (w/2.0)*sin(rot)
            let p2x = p.x + (w/2.0)*cos(rot)
            let p2z = p.z + (w/2.0)*sin(rot)
            addLine(layer: "A-GLAZ", x1: p1x, y1: -p1z, x2: p2x, y2: -p2z)
        }
        
        // 4. Export Furniture
        for obj in room.objects {
            addBox2D(
                layer: "A-FURN",
                center: obj.position,
                width: obj.width,
                depth: obj.depth,
                rotationY: obj.rotationY
            )
        }
        
        // 5. Dimensions
        let b = room.boundingBox
        let offset: Float = 0.5
        // Top horizontal dimension line
        addLine(layer: "A-DIMS", x1: b.min.x, y1: -b.min.z + offset, x2: b.max.x, y2: -b.min.z + offset)
        // Right vertical dimension line
        addLine(layer: "A-DIMS", x1: b.max.x + offset, y1: -b.min.z, x2: b.max.x + offset, y2: -b.max.z)
        
        dxf += "0\nENDSEC\n0\nEOF\n"
        
        try dxf.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }
}
