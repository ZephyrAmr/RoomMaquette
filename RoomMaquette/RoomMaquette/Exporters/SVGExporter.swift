import Foundation
import simd

public class SVGExporter {
    
    public static func export(room: MaquetteRoom) throws -> URL {
        let baseName = "\(room.name.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).svg"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(baseName)
        
        let b = room.boundingBox
        let roomW = max(b.max.x - b.min.x, 1.0)
        let roomD = max(b.max.z - b.min.z, 1.0)
        
        // Scale meters to SVG pixels (1 meter = 120 pixels)
        let ppm: Float = 120.0
        let padM: Float = 1.2
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
            .grid { stroke: #F1F5F9; stroke-width: 1; }
            .floor { fill: #F8FAFC; stroke: #E2E8F0; stroke-width: 1; }
            .wall { stroke: #0F172A; stroke-width: 12; stroke-linecap: square; fill: none; }
            .door-leaf { stroke: #2563EB; stroke-width: 2.5; fill: none; }
            .door-arc { stroke: #3B82F6; stroke-width: 1.5; stroke-dasharray: 4,3; fill: none; }
            .window { stroke: #0284C7; stroke-width: 5; fill: none; }
            .furniture { fill: #EFF6FF; stroke: #3B82F6; stroke-width: 1.5; rx: 4px; }
            .dimension-line { stroke: #64748B; stroke-width: 1.2; fill: none; }
            .dimension-tick { stroke: #64748B; stroke-width: 1.2; }
            .dimension-pill { fill: #FFFFFF; stroke: #CBD5E1; stroke-width: 1; rx: 4px; }
            .wall-dim-text { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 11px; font-weight: bold; fill: #1E293B; text-anchor: middle; dominant-baseline: middle; }
            .opening-dim-text { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 9px; font-weight: 600; fill: #2563EB; text-anchor: middle; dominant-baseline: middle; }
            .title-text { font-family: -apple-system, system-ui, sans-serif; font-size: 20px; font-weight: bold; fill: #0F172A; }
            .subtitle-text { font-family: -apple-system, system-ui, sans-serif; font-size: 11px; fill: #64748B; }
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
        
        // Floor fill
        let fl1 = toSVG(b.min.x, b.min.z)
        let fl2 = toSVG(b.max.x, b.min.z)
        let fl3 = toSVG(b.max.x, b.max.z)
        let fl4 = toSVG(b.min.x, b.max.z)
        svg += "  <polygon points=\"\(fl1.x),\(fl1.y) \(fl2.x),\(fl2.y) \(fl3.x),\(fl3.y) \(fl4.x),\(fl4.y)\" class=\"floor\"/>\n"
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
            svg += "    <text x=\"0\" y=\"3\" font-family=\"sans-serif\" font-size=\"10\" font-weight=\"500\" fill=\"#2563EB\" text-anchor=\"middle\">\(obj.displayName)</text>\n"
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
            
            let center = toSVG(win.position.x, win.position.z)
            let winText = String(format: "%.2fm", win.width)
            svg += "  <text x=\"\(center.x)\" y=\"\(center.y - 8)\" class=\"opening-dim-text\">\(winText)</text>\n"
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
            
            let center = toSVG(pos.x, pos.z)
            let doorText = String(format: "Door: %.2fm", door.width)
            svg += "  <text x=\"\(center.x)\" y=\"\(center.y - 12)\" class=\"opening-dim-text\">\(doorText)</text>\n"
        }
        svg += "</g>\n\n"
        
        // 6. Dimensions Layer (Per-Wall Measurements + Overall Bounding Chains)
        svg += "<g id=\"dimensions\">\n"
        
        // A. Per-Wall Measurement Badges
        for wall in room.walls {
            let p1 = toSVG(Float(wall.startPoint2D.x), Float(wall.startPoint2D.y))
            let p2 = toSVG(Float(wall.endPoint2D.x), Float(wall.endPoint2D.y))
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let segLen = sqrt(dx*dx + dy*dy)
            
            if segLen > 30 {
                let midX = (p1.x + p2.x) / 2.0
                let midY = (p1.y + p2.y) / 2.0
                let normalX = -dy / segLen
                let normalY = dx / segLen
                let offsetDist: Float = 18.0
                let lx = midX + normalX * offsetDist
                let ly = midY + normalY * offsetDist
                
                let dimStr = String(format: "%.2f m", wall.length)
                let pillW: Float = 56.0
                let pillH: Float = 18.0
                
                svg += "  <rect x=\"\(lx - pillW/2)\" y=\"\(ly - pillH/2)\" width=\"\(pillW)\" height=\"\(pillH)\" class=\"dimension-pill\"/>\n"
                svg += "  <text x=\"\(lx)\" y=\"\(ly)\" class=\"wall-dim-text\">\(dimStr)</text>\n"
            }
        }
        
        // B. Overall Bounding Dimensions
        let dTop = toSVG(b.min.x, b.min.z - 0.45)
        let dTopEnd = toSVG(b.max.x, b.min.z - 0.45)
        svg += "  <line x1=\"\(dTop.x)\" y1=\"\(dTop.y)\" x2=\"\(dTopEnd.x)\" y2=\"\(dTopEnd.y)\" class=\"dimension-line\"/>\n"
        svg += "  <line x1=\"\(dTop.x)\" y1=\"\(dTop.y - 6)\" x2=\"\(dTop.x)\" y2=\"\(dTop.y + 6)\" class=\"dimension-tick\"/>\n"
        svg += "  <line x1=\"\(dTopEnd.x)\" y1=\"\(dTopEnd.y - 6)\" x2=\"\(dTopEnd.x)\" y2=\"\(dTopEnd.y + 6)\" class=\"dimension-tick\"/>\n"
        svg += "  <text x=\"\((dTop.x + dTopEnd.x)/2)\" y=\"\(dTop.y - 10)\" class=\"wall-dim-text\">OVERALL WIDTH: \(String(format: "%.2f m", room.roomWidth))</text>\n"
        
        let dRight = toSVG(b.max.x + 0.45, b.min.z)
        let dRightEnd = toSVG(b.max.x + 0.45, b.max.z)
        svg += "  <line x1=\"\(dRight.x)\" y1=\"\(dRight.y)\" x2=\"\(dRightEnd.x)\" y2=\"\(dRightEnd.y)\" class=\"dimension-line\"/>\n"
        svg += "  <line x1=\"\(dRight.x - 6)\" y1=\"\(dRight.y)\" x2=\"\(dRight.x + 6)\" y2=\"\(dRight.y)\" class=\"dimension-tick\"/>\n"
        svg += "  <line x1=\"\(dRightEnd.x - 6)\" y1=\"\(dRightEnd.y)\" x2=\"\(dRightEnd.x + 6)\" y2=\"\(dRightEnd.y)\" class=\"dimension-tick\"/>\n"
        svg += "  <text x=\"\(dRight.x + 28)\" y=\"\((dRight.y + dRightEnd.y)/2)\" class=\"wall-dim-text\" transform=\"rotate(90, \(dRight.x + 28), \((dRight.y + dRightEnd.y)/2))\">OVERALL DEPTH: \(String(format: "%.2f m", room.roomDepth))</text>\n"
        svg += "</g>\n\n"
        
        // 7. Title Block
        svg += "<g id=\"title-block\" transform=\"translate(35, 45)\">\n"
        svg += "  <text x=\"0\" y=\"0\" class=\"title-text\">\(room.name.uppercased())</text>\n"
        svg += "  <text x=\"0\" y=\"22\" class=\"subtitle-text\">Floor Area: \(room.formattedAreaMetric) (\(room.formattedAreaImperial)) • Walls: \(room.walls.count) • Scale: 1:50 • Generated by RoomMaquette iOS</text>\n"
        svg += "</g>\n"
        
        svg += "</svg>\n"
        
        try svg.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }
}
