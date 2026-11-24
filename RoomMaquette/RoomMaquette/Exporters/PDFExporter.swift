import UIKit
import PDFKit

public class PDFExporter {
    
    public static func export(room: MaquetteRoom) throws -> URL {
        let baseName = "\(room.name.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).pdf"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(baseName)
        
        // Standard A4 Landscape: 841.89 x 595.28 points
        let pageWidth: CGFloat = 842.0
        let pageHeight: CGFloat = 595.0
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        
        // Offscreen 3D snapshot of the maquette
        let maquetteImage = SceneKitMaquetteRenderer.snapshot(
            room: room,
            style: .architecturalClay,
            size: CGSize(width: 800, height: 600)
        )
        
        let pdfData = renderer.pdfData { context in
            context.beginPage()
            let cg = context.cgContext
            
            // 1. Drawing Border & Sheet Frame
            let margin: CGFloat = 24.0
            let frameRect = pageRect.insetBy(dx: margin, dy: margin)
            cg.setStrokeColor(UIColor.darkGray.cgColor)
            cg.setLineWidth(1.5)
            cg.stroke(frameRect)
            
            // 2. Title Block (Header)
            let headerRect = CGRect(x: margin, y: margin, width: pageWidth - margin * 2, height: 50)
            cg.setFillColor(UIColor(white: 0.96, alpha: 1.0).cgColor)
            cg.fill(headerRect)
            cg.stroke(headerRect)
            
            let titleFont = UIFont.boldSystemFont(ofSize: 18)
            let subtitleFont = UIFont.systemFont(ofSize: 11)
            
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: UIColor.black
            ]
            let subtitleAttrs: [NSAttributedString.Key: Any] = [
                .font: subtitleFont,
                .foregroundColor: UIColor.darkGray
            ]
            
            let titleStr = NSAttributedString(string: "ARCHITECTURAL MAQUETTE REPORT: \(room.name.uppercased())", attributes: titleAttrs)
            titleStr.draw(at: CGPoint(x: margin + 12, y: margin + 10))
            
            let dateStr = DateFormatter.localizedString(from: room.createdAt, dateStyle: .medium, timeStyle: .short)
            let subStr = NSAttributedString(string: "Captured via iPhone Pro LiDAR • Date: \(dateStr) • Area: \(room.formattedAreaMetric) (\(room.formattedAreaImperial))", attributes: subtitleAttrs)
            subStr.draw(at: CGPoint(x: margin + 12, y: margin + 30))
            
            // 3. 2D Floor Plan Area (Left Column)
            let leftColWidth = (pageWidth - margin * 2) * 0.52
            let contentTop: CGFloat = margin + 50 + 12
            let contentHeight: CGFloat = 320.0
            let floorPlanRect = CGRect(x: margin + 12, y: contentTop, width: leftColWidth - 24, height: contentHeight)
            
            // Draw floor plan box
            cg.setStrokeColor(UIColor.lightGray.cgColor)
            cg.setLineWidth(1.0)
            cg.stroke(floorPlanRect)
            
            let fpTitle = NSAttributedString(string: "2D SCHEMATIC FLOOR PLAN (1:50)", attributes: [
                .font: UIFont.boldSystemFont(ofSize: 11),
                .foregroundColor: UIColor.black
            ])
            fpTitle.draw(at: CGPoint(x: floorPlanRect.minX + 8, y: floorPlanRect.minY + 8))
            
            // Render 2D room geometry inside floorPlanRect
            drawFloorPlanToPDF(cg: cg, rect: floorPlanRect, room: room)
            
            // 4. 3D Maquette Perspective Render (Right Column)
            let rightColX = margin + leftColWidth
            let rightColWidth = (pageWidth - margin * 2) - leftColWidth
            let maquetteRect = CGRect(x: rightColX + 8, y: contentTop, width: rightColWidth - 20, height: contentHeight)
            
            cg.stroke(maquetteRect)
            
            let mTitle = NSAttributedString(string: "3D DIGITAL TWIN / MAQUETTE PERSPECTIVE", attributes: [
                .font: UIFont.boldSystemFont(ofSize: 11),
                .foregroundColor: UIColor.black
            ])
            mTitle.draw(at: CGPoint(x: maquetteRect.minX + 8, y: maquetteRect.minY + 8))
            
            let imgRect = maquetteRect.insetBy(dx: 10, dy: 26)
            maquetteImage.draw(in: imgRect)
            
            // 5. Room Schedule & Inventory Table (Bottom Section)
            let tableTop = contentTop + contentHeight + 12
            let tableHeight = pageHeight - margin - tableTop - 10
            let tableRect = CGRect(x: margin + 12, y: tableTop, width: pageWidth - margin * 2 - 24, height: tableHeight)
            
            cg.setFillColor(UIColor(white: 0.97, alpha: 1.0).cgColor)
            cg.fill(tableRect)
            cg.stroke(tableRect)
            
            let tableHeader = NSAttributedString(string: "ROOM SPECIFICATIONS & FURNITURE SCHEDULE", attributes: [
                .font: UIFont.boldSystemFont(ofSize: 10),
                .foregroundColor: UIColor.black
            ])
            tableHeader.draw(at: CGPoint(x: tableRect.minX + 8, y: tableRect.minY + 6))
            
            // Table content rows
            let rowY = tableRect.minY + 22
            let metricsText = "Walls: \(room.walls.count)   •   Doors: \(room.doors.count)   •   Windows: \(room.windows.count)   •   Objects: \(room.objects.count)   •   Ceiling Height: \(String(format: "%.2f m", room.ceilingHeight))   •   Perimeter: \(String(format: "%.1f m", room.perimeterMeters))"
            let metricsAttr = NSAttributedString(string: metricsText, attributes: [
                .font: UIFont.systemFont(ofSize: 9),
                .foregroundColor: UIColor.darkGray
            ])
            metricsAttr.draw(at: CGPoint(x: tableRect.minX + 8, y: rowY))
            
            // Furniture items preview
            var fY = rowY + 16
            let itemsToDisplay = room.objects.prefix(4)
            for item in itemsToDisplay {
                let itemStr = "• \(item.displayName): \(String(format: "%.2fm (W) × %.2fm (D) × %.2fm (H)", item.width, item.depth, item.height))"
                let itemAttr = NSAttributedString(string: itemStr, attributes: [
                    .font: UIFont.systemFont(ofSize: 8.5),
                    .foregroundColor: UIColor.black
                ])
                itemAttr.draw(at: CGPoint(x: tableRect.minX + 16, y: fY))
                fY += 12
            }
        }
        
        try pdfData.write(to: outputURL)
        return outputURL
    }
    
    private static func drawFloorPlanToPDF(cg: CGContext, rect: CGRect, room: MaquetteRoom) {
        let b = room.boundingBox
        let roomW = max(b.max.x - b.min.x, 1.0)
        let roomD = max(b.max.z - b.min.z, 1.0)
        
        let pad: CGFloat = 30.0
        let drawArea = rect.insetBy(dx: pad, dy: pad)
        let scale = min(drawArea.width / CGFloat(roomW), drawArea.height / CGFloat(roomD))
        
        let centerX = CGFloat(b.min.x + b.max.x) / 2.0
        let centerZ = CGFloat(b.min.z + b.max.z) / 2.0
        let midX = drawArea.midX
        let midY = drawArea.midY
        
        func toPDF(_ rx: Float, _ rz: Float) -> CGPoint {
            let dx = CGFloat(rx) - centerX
            let dz = CGFloat(rz) - centerZ
            return CGPoint(x: midX + dx * scale, y: midY + dz * scale)
        }
        
        // Draw Walls
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(4.0)
        cg.setLineCap(.square)
        for wall in room.walls {
            let p1 = toPDF(Float(wall.startPoint2D.x), Float(wall.startPoint2D.y))
            let p2 = toPDF(Float(wall.endPoint2D.x), Float(wall.endPoint2D.y))
            cg.move(to: p1)
            cg.addLine(to: p2)
            cg.strokePath()
        }
        
        // Draw Windows
        cg.setStrokeColor(UIColor.systemTeal.cgColor)
        cg.setLineWidth(2.5)
        for win in room.windows {
            let halfW = win.width / 2.0
            let rot = win.transform.rotationY
            let p1 = toPDF(win.position.x - halfW*cos(rot), win.position.z - halfW*sin(rot))
            let p2 = toPDF(win.position.x + halfW*cos(rot), win.position.z + halfW*sin(rot))
            cg.move(to: p1)
            cg.addLine(to: p2)
            cg.strokePath()
        }
        
        // Draw Furniture
        cg.setLineWidth(1.0)
        cg.setFillColor(UIColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1.0).cgColor)
        cg.setStrokeColor(UIColor.systemBlue.cgColor)
        for obj in room.objects {
            let c = toPDF(obj.position.x, obj.position.z)
            let w = CGFloat(obj.width) * scale
            let d = CGFloat(obj.depth) * scale
            let objRect = CGRect(x: c.x - w/2, y: c.y - d/2, width: w, height: d)
            cg.fill(objRect)
            cg.stroke(objRect)
        }
    }
}
