import Foundation
import simd

public class SVGExporter {
    
    public static func export(room: MaquetteRoom) throws -> URL {
        let baseName = "\(room.name.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).svg"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(baseName)
        
        let b = room.boundingBox
        let roomW = max(b.max.x - b.min.x, 1.0)
        let roomD = max(b.max.z - b.min.z, 1.0)
        
        // Scale meters to SVG pixels (1 meter = 100 pixels)
        let ppm: Float = 100.0
        let padM: Float = 1.0
        let svgW = (roomW + padM * 2) * ppm
        let svgH = (roomD + padM * 2) * ppm
        
        let minX = b.min.x - padM
        let minZ = b.min.z - padM
        
        func toSVG(_ rx: Float, _ rz: Float) -> (x: Float, y: Float) {
            let x = (rx - minX) * ppm
            let y = (rz - minZ) * ppm
            return (x, y)
        }
        
        var svg = ""
        svg += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        svg += "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(Int(svgW)) \(Int(svgH))\" width=\"\(Int(svgW))\" height=\"\(Int(svgH))\">\n"
        
        // Embedded CSS styles
        svg += """
        <defs>
          <style>
            .grid { stroke: #E2E8F0; stroke-width: 1; }
            .floor { fill: #F8FAFC; }
            .wall { stroke: #0F172A; stroke-width: 14; stroke-linecap: square; fill: none; }
            .door-leaf { stroke: #2563EB; stroke-width: 3; fill: none; }
            .door-arc { stroke: #3B82F6; stroke-width: 1.5; stroke-dasharray: 4,4; fill: none; }
            .window { stroke: #0284C7; stroke-width: 6; fill: none; }
            .furniture { fill: #EFF6FF; stroke: #3B82F6; stroke-width: 1.5; rx: 4px; }
            .dimension-line { stroke: #64748B; stroke-width: 1.5; fill: none; }
            .dimension-text { font-family: -apple-system, system-ui, sans-serif; font-size: 13px; font-weight: bold; fill: #475569; text-anchor: middle; }
            .title-text { font-family: -apple-system, system-ui, sans-serif; font-size: 18px; font-weight: bold; fill: #0F172A; }
            .subtitle-text { font-family: -apple-system, system-ui, sans-serif; font-size: 12px; fill: #64748B; }
          </style>
        </defs>
        
        """
        
        // 1. Background Grid & Floor
        svg += "<g id=\"background\">\n"
        svg += "  <rect width=\"\(Int(svgW))\" height=\"\(Int(svgH))\" fill=\"#FFFFFF\"/>\n"
        // 1m grid
        for gx in stride(from: 0, to: svgW, by: ppm) {
            svg += "  <line x1=\"\(gx)\" y1=\"0\" x2=\"\(gx)\" y2=\"\(svgH)\" class=\"grid\"/>\n"
        }
        for gy in stride(from: 0, to: svgH, by: ppm) {
            svg += "  <line x1=\"0\" y1=\"\(gy)\" x2=\"\(svgW)\" y2=\"\(gy)\" class=\"grid\"/>\n"
        }
        svg += "</g>\n\n"
        
        // 2. Furniture Layer
        svg += "<g id=\"furniture\">\n"
        for obj in room.objects {
            let center = toSVG(obj.position.x, obj.position.z)
            let w = obj.width * ppm
            let d = obj.depth * ppm
            let rotDeg = obj.rotationY * (180.0 / .pi)
            
            svg += "  <g transform=\"translate(\(center.x), \(center.y)) rotate(\(rotDeg))\">\n"
            svg += "    <rect x=\"\(-w/2)\" y=\"\(-d/2)\" width=\"\(w)\" height=\"\(d)\" class=\"furniture\"/>\n"
            svg += "    <text x=\"0\" y=\"4\" font-family=\"sans-serif\" font-size=\"10\" fill=\"#3B82F6\" text-anchor=\"middle\">\(obj.displayName)</text>\n"
            svg += "  </g>\n"
        }
        svg += "</g>\n\n"
        
        // 3. Walls Layer
        svg += "<g id=\"walls\">\n"
        for wall in room.walls {
            let p1 = toSVG(Float(wall.startPoint2D.x), Float(wall.startPoint2D.y))
            let p2 = toSVG(Float(wall.endPoint2D.x), Float(wall.endPoint2D.y))
            svg += "  <line x1=\"\(p1.x)\" y1=\"\(p1.y)\" x2=\"\(p2.x)\" y2=\"\(p2.y)\" class=\"wall\"/>\n"
        }
        svg += "</g>\n\n"
        
        // 4. Windows Layer
        svg += "<g id=\"windows\">\n"
        for win in room.windows {
            let halfW = win.width / 2.0
            let rot = win.transform.rotationY
            let p1 = toSVG(win.position.x - halfW*cos(rot), win.position.z - halfW*sin(rot))
            let p2 = toSVG(win.position.x + halfW*cos(rot), win.position.z + halfW*sin(rot))
            svg += "  <line x1=\"\(p1.x)\" y1=\"\(p1.y)\" x2=\"\(p2.x)\" y2=\"\(p2.y)\" class=\"window\"/>\n"
        }
        svg += "</g>\n\n"
        
        // 5. Doors Layer
        svg += "<g id=\"doors\">\n"
        for door in room.doors {
            let pos = door.position
            let rot = door.transform.rotationY
            let w = door.width * ppm
            let h = toSVG(pos.x - (door.width/2)*cos(rot), pos.z - (door.width/2)*sin(rot))
            
            // Swing arc (90 degrees)
            let arcEndX = h.x + w * cos(rot + .pi/2)
            let arcEndY = h.y + w * sin(rot + .pi/2)
            
            svg += "  <line x1=\"\(h.x)\" y1=\"\(h.y)\" x2=\"\(arcEndX)\" y2=\"\(arcEndY)\" class=\"door-leaf\"/>\n"
            svg += "  <path d=\"M \(h.x + w * cos(rot)) \(h.y + w * sin(rot)) A \(w) \(w) 0 0 1 \(arcEndX) \(arcEndY)\" class=\"door-arc\"/>\n"
        }
        svg += "</g>\n\n"
        
        // 6. Dimensions Layer
        svg += "<g id=\"dimensions\">\n"
        let dTop = toSVG(b.min.x, b.min.z - 0.4)
        let dTopEnd = toSVG(b.max.x, b.min.z - 0.4)
        svg += "  <line x1=\"\(dTop.x)\" y1=\"\(dTop.y)\" x2=\"\(dTopEnd.x)\" y2=\"\(dTopEnd.y)\" class=\"dimension-line\"/>\n"
        svg += "  <line x1=\"\(dTop.x)\" y1=\"\(dTop.y - 6)\" x2=\"\(dTop.x)\" y2=\"\(dTop.y + 6)\" class=\"dimension-line\"/>\n"
        svg += "  <line x1=\"\(dTopEnd.x)\" y1=\"\(dTopEnd.y - 6)\" x2=\"\(dTopEnd.x)\" y2=\"\(dTopEnd.y + 6)\" class=\"dimension-line\"/>\n"
        svg += "  <text x=\"\((dTop.x + dTopEnd.x)/2)\" y=\"\(dTop.y - 10)\" class=\"dimension-text\">\(String(format: "%.2f m", room.roomWidth))</text>\n"
        
        let dRight = toSVG(b.max.x + 0.4, b.min.z)
        let dRightEnd = toSVG(b.max.x + 0.4, b.max.z)
        svg += "  <line x1=\"\(dRight.x)\" y1=\"\(dRight.y)\" x2=\"\(dRightEnd.x)\" y2=\"\(dRightEnd.y)\" class=\"dimension-line\"/>\n"
        svg += "  <line x1=\"\(dRight.x - 6)\" y1=\"\(dRight.y)\" x2=\"\(dRight.x + 6)\" y2=\"\(dRight.y)\" class=\"dimension-line\"/>\n"
        svg += "  <line x1=\"\(dRightEnd.x - 6)\" y1=\"\(dRightEnd.y)\" x2=\"\(dRightEnd.x + 6)\" y2=\"\(dRightEnd.y)\" class=\"dimension-line\"/>\n"
        svg += "  <text x=\"\(dRight.x + 25)\" y=\"\((dRight.y + dRightEnd.y)/2)\" class=\"dimension-text\" transform=\"rotate(90, \(dRight.x + 25), \((dRight.y + dRightEnd.y)/2))\">\(String(format: "%.2f m", room.roomDepth))</text>\n"
        svg += "</g>\n\n"
        
        // 7. Title Block
        svg += "<g id=\"title-block\" transform=\"translate(30, 40)\">\n"
        svg += "  <text x=\"0\" y=\"0\" class=\"title-text\">\(room.name)</text>\n"
        svg += "  <text x=\"0\" y=\"20\" class=\"subtitle-text\">Area: \(room.formattedAreaMetric) (\(room.formattedAreaImperial)) • Generated by RoomMaquette iOS</text>\n"
        svg += "</g>\n"
        
        svg += "</svg>\n"
        
        try svg.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }
}
