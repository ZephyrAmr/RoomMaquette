import UIKit
import CoreGraphics

public enum PNGRenderType {
    case perspective3D
    case floorPlan2D
}

public class PNGExporter {
    
    public static func export(
        room: MaquetteRoom,
        style: MaquetteStyle = .architecturalClay,
        size: CGSize = CGSize(width: 2560, height: 1800),
        isMetric: Bool = true,
        renderType: PNGRenderType = .floorPlan2D
    ) throws -> URL {
        let baseName = "\(room.name.replacingOccurrences(of: " ", with: "_"))_2DPlan_\(Int(Date().timeIntervalSince1970)).png"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(baseName)
        
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            
            // 1. Background Paper
            cg.setFillColor(UIColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1.0).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            
            let bounds = room.boundingBox
            let roomW = max(bounds.max.x - bounds.min.x, 1.0)
            let roomD = max(bounds.max.z - bounds.min.z, 1.0)
            
            // Margins for title block and dimensions
            let marginX: CGFloat = 120.0
            let marginTop: CGFloat = 160.0
            let marginBottom: CGFloat = 120.0
            let drawArea = CGRect(
                x: marginX,
                y: marginTop,
                width: size.width - marginX * 2,
                height: size.height - marginTop - marginBottom
            )
            
            let scale = min(drawArea.width / CGFloat(roomW), drawArea.height / CGFloat(roomD))
            let centerX = CGFloat(bounds.min.x + bounds.max.x) / 2.0
            let centerZ = CGFloat(bounds.min.z + bounds.max.z) / 2.0
            let midX = drawArea.midX
            let midY = drawArea.midY
            
            func toCanvas(_ rx: Float, _ rz: Float) -> CGPoint {
                let dx = CGFloat(rx) - centerX
                let dz = CGFloat(rz) - centerZ
                return CGPoint(x: midX + dx * scale, y: midY + dz * scale)
            }
            
            // 2. Subtle 1-Meter Architectural Grid
            let gridSpacing = scale * 1.0
            if gridSpacing > 15 {
                cg.setStrokeColor(UIColor(white: 0.92, alpha: 1.0).cgColor)
                cg.setLineWidth(1.0)
                let startX = midX.truncatingRemainder(dividingBy: gridSpacing) - gridSpacing
                var x = startX
                while x <= size.width + gridSpacing {
                    cg.move(to: CGPoint(x: x, y: 0))
                    cg.addLine(to: CGPoint(x: x, y: size.height))
                    x += gridSpacing
                }
                let startY = midY.truncatingRemainder(dividingBy: gridSpacing) - gridSpacing
                var y = startY
                while y <= size.height + gridSpacing {
                    cg.move(to: CGPoint(x: 0, y: y))
                    cg.addLine(to: CGPoint(x: size.width, y: y))
                    y += gridSpacing
                }
                cg.strokePath()
            }
            
            // 3. Floor Polygon Fill
            let padM: Float = 0.05
            let fp1 = toCanvas(bounds.min.x - padM, bounds.min.z - padM)
            let fp2 = toCanvas(bounds.max.x + padM, bounds.min.z - padM)
            let fp3 = toCanvas(bounds.max.x + padM, bounds.max.z + padM)
            let fp4 = toCanvas(bounds.min.x - padM, bounds.max.z + padM)
            
            cg.setFillColor(UIColor(white: 0.94, alpha: 1.0).cgColor)
            cg.move(to: fp1)
            cg.addLine(to: fp2)
            cg.addLine(to: fp3)
            cg.addLine(to: fp4)
            cg.closePath()
            cg.fillPath()
            
            // 4. Furniture Objects
            for obj in room.objects {
                let center = toCanvas(obj.position.x, obj.position.z)
                let w = CGFloat(obj.width) * scale
                let d = CGFloat(obj.depth) * scale
                let rot = CGFloat(obj.rotationY)
                
                cg.saveGState()
                cg.translateBy(x: center.x, y: center.y)
                cg.rotate(by: rot)
                
                let rect = CGRect(x: -w/2, y: -d/2, width: w, height: d)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 4.0)
                
                cg.setFillColor(UIColor.systemBlue.withAlphaComponent(0.15).cgColor)
                cg.addPath(path.cgPath)
                cg.fillPath()
                
                cg.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.85).cgColor)
                cg.setLineWidth(2.0)
                cg.addPath(path.cgPath)
                cg.strokePath()
                
                // Label
                let nameAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: max(10, min(14, w * 0.16)), weight: .semibold),
                    .foregroundColor: UIColor.systemBlue
                ]
                let nameStr = NSAttributedString(string: obj.displayName, attributes: nameAttrs)
                let strSize = nameStr.size()
                if strSize.width <= w && strSize.height <= d {
                    nameStr.draw(at: CGPoint(x: -strSize.width / 2, y: -strSize.height / 2))
                }
                
                cg.restoreGState()
            }
            
            // 5. Walls with Architectural Solid Line & Per-Wall Dimensions
            cg.setStrokeColor(UIColor(red: 0.1, green: 0.12, blue: 0.18, alpha: 1.0).cgColor)
            cg.setLineWidth(max(6.0, scale * 0.15))
            cg.setLineCap(.square)
            cg.setLineJoin(.miter)
            
            for wall in room.walls {
                let p1 = toCanvas(Float(wall.startPoint2D.x), Float(wall.startPoint2D.y))
                let p2 = toCanvas(Float(wall.endPoint2D.x), Float(wall.endPoint2D.y))
                cg.move(to: p1)
                cg.addLine(to: p2)
                cg.strokePath()
                
                // Draw per-wall measurement label along wall
                let wallLen = wall.length
                let midP = CGPoint(x: (p1.x + p2.x)/2.0, y: (p1.y + p2.y)/2.0)
                let dx = p2.x - p1.x
                let dy = p2.y - p1.y
                let segLen = sqrt(dx*dx + dy*dy)
                
                if segLen > 40 {
                    let normalX = -dy / segLen
                    let normalY = dx / segLen
                    let offsetDist: CGFloat = 16.0
                    let labelPos = CGPoint(x: midP.x + normalX * offsetDist, y: midP.y + normalY * offsetDist)
                    
                    let distText = isMetric ? String(format: "%.2f m", wallLen) : String(format: "%.1f ft", wallLen * 3.28084)
                    let textAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                        .foregroundColor: UIColor(white: 0.25, alpha: 1.0)
                    ]
                    let str = NSAttributedString(string: distText, attributes: textAttrs)
                    let tSize = str.size()
                    
                    // Background pill for label
                    let pillRect = CGRect(x: labelPos.x - tSize.width/2 - 4, y: labelPos.y - tSize.height/2 - 2, width: tSize.width + 8, height: tSize.height + 4)
                    cg.setFillColor(UIColor(white: 1.0, alpha: 0.90).cgColor)
                    cg.setStrokeColor(UIColor(white: 0.85, alpha: 1.0).cgColor)
                    cg.setLineWidth(1.0)
                    let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: 4.0)
                    cg.addPath(pillPath.cgPath)
                    cg.drawPath(using: .fillStroke)
                    
                    str.draw(at: CGPoint(x: labelPos.x - tSize.width/2, y: labelPos.y - tSize.height/2))
                }
            }
            
            // 6. Windows
            cg.setStrokeColor(UIColor.systemTeal.cgColor)
            cg.setLineWidth(5.0)
            for win in room.windows {
                let halfW = win.width / 2.0
                let rot = win.transform.rotationY
                let p1 = toCanvas(win.position.x - halfW*cos(rot), win.position.z - halfW*sin(rot))
                let p2 = toCanvas(win.position.x + halfW*cos(rot), win.position.z + halfW*sin(rot))
                cg.move(to: p1)
                cg.addLine(to: p2)
                cg.strokePath()
            }
            
            // 7. Doors with 90° Swing Arc
            for door in room.doors {
                let pos = door.position
                let rot = door.transform.rotationY
                let w = door.width
                let hinge = toCanvas(pos.x - (w/2)*cos(rot), pos.z - (w/2)*sin(rot))
                let radius = CGFloat(w) * scale
                
                // Leaf line
                let leafEnd = CGPoint(
                    x: hinge.x + radius * CGFloat(cos(rot + .pi/2)),
                    y: hinge.y + radius * CGFloat(sin(rot + .pi/2))
                )
                cg.setStrokeColor(UIColor.systemBlue.cgColor)
                cg.setLineWidth(2.5)
                cg.move(to: hinge)
                cg.addLine(to: leafEnd)
                cg.strokePath()
                
                // Swing arc
                cg.setLineWidth(1.5)
                cg.setLineDash(phase: 0, lengths: [4, 4])
                cg.addArc(
                    center: hinge,
                    radius: radius,
                    startAngle: CGFloat(rot),
                    endAngle: CGFloat(rot + .pi/2),
                    clockwise: false
                )
                cg.strokePath()
                cg.setLineDash(phase: 0, lengths: []) // reset dash
            }
            
            // 8. Overall Bounding Dimensions
            let offsetM: Float = 0.5
            let topStart = toCanvas(bounds.min.x, bounds.min.z - offsetM)
            let topEnd = toCanvas(bounds.max.x, bounds.min.z - offsetM)
            cg.setStrokeColor(UIColor.darkGray.cgColor)
            cg.setLineWidth(1.5)
            cg.move(to: topStart)
            cg.addLine(to: topEnd)
            cg.move(to: CGPoint(x: topStart.x, y: topStart.y - 8))
            cg.addLine(to: CGPoint(x: topStart.x, y: topStart.y + 8))
            cg.move(to: CGPoint(x: topEnd.x, y: topEnd.y - 8))
            cg.addLine(to: CGPoint(x: topEnd.x, y: topEnd.y + 8))
            cg.strokePath()
            
            let wStr = NSAttributedString(
                string: String(format: "OVERALL WIDTH: %.2f m", room.roomWidth),
                attributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .bold), .foregroundColor: UIColor.darkGray]
            )
            wStr.draw(at: CGPoint(x: (topStart.x + topEnd.x)/2 - wStr.size().width/2, y: topStart.y - 20))
            
            // 9. Architectural Title Block (Top-Left)
            let titleRect = CGRect(x: 60, y: 50, width: 600, height: 80)
            let titleStr = NSAttributedString(
                string: room.name.uppercased(),
                attributes: [.font: UIFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: UIColor(white: 0.1, alpha: 1.0)]
            )
            titleStr.draw(at: CGPoint(x: titleRect.minX, y: titleRect.minY))
            
            let metaStr = NSAttributedString(
                string: "Floor Area: \(room.formattedAreaMetric) (\(room.formattedAreaImperial))   •   Ceiling: \(String(format: "%.2fm", room.ceilingHeight))   •   Scale: 1:50",
                attributes: [.font: UIFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: UIColor.secondaryLabel]
            )
            metaStr.draw(at: CGPoint(x: titleRect.minX, y: titleRect.minY + 34))
        }
        
        guard let data = image.pngData() else {
            throw NSError(domain: "PNGExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate PNG data"])
        }
        
        try data.write(to: outputURL)
        return outputURL
    }
}
