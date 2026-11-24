import UIKit
import PDFKit

public class PDFExporter {
    
    public static func export(room: MaquetteRoom) throws -> URL {
        let baseName = "\(room.name.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).pdf"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(baseName)
        
        // Standard A4 Landscape: 842 x 595 points
        let pageWidth: CGFloat = 842.0
        let pageHeight: CGFloat = 595.0
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        
        let pdfData = renderer.pdfData { context in
            context.beginPage()
            let cg = context.cgContext
            
            // 1. Drawing Sheet Border & Frame
            let margin: CGFloat = 20.0
            let frameRect = pageRect.insetBy(dx: margin, dy: margin)
            cg.setStrokeColor(UIColor(red: 0.15, green: 0.18, blue: 0.25, alpha: 1.0).cgColor)
            cg.setLineWidth(2.0)
            cg.stroke(frameRect)
            
            // Inner fine border
            let innerRect = frameRect.insetBy(dx: 4.0, dy: 4.0)
            cg.setLineWidth(0.75)
            cg.stroke(innerRect)
            
            // 2. Title Block (Header)
            let headerHeight: CGFloat = 52.0
            let headerRect = CGRect(x: innerRect.minX, y: innerRect.minY, width: innerRect.width, height: headerHeight)
            cg.setFillColor(UIColor(white: 0.96, alpha: 1.0).cgColor)
            cg.fill(headerRect)
            cg.stroke(headerRect)
            
            let titleFont = UIFont.boldSystemFont(ofSize: 18)
            let subtitleFont = UIFont.systemFont(ofSize: 10.5)
            
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: UIColor(red: 0.1, green: 0.12, blue: 0.2, alpha: 1.0)
            ]
            let subtitleAttrs: [NSAttributedString.Key: Any] = [
                .font: subtitleFont,
                .foregroundColor: UIColor.darkGray
            ]
            
            let titleStr = NSAttributedString(
                string: "ARCHITECTURAL FLOOR PLAN & SPECIFICATION: \(room.name.uppercased())",
                attributes: titleAttrs
            )
            titleStr.draw(at: CGPoint(x: headerRect.minX + 14, y: headerRect.minY + 9))
            
            let dateStr = DateFormatter.localizedString(from: room.createdAt, dateStyle: .medium, timeStyle: .short)
            let subStr = NSAttributedString(
                string: "Captured with iPhone Pro LiDAR • Date: \(dateStr) • Floor Area: \(room.formattedAreaMetric) (\(room.formattedAreaImperial)) • Scale: 1:50",
                attributes: subtitleAttrs
            )
            subStr.draw(at: CGPoint(x: headerRect.minX + 14, y: headerRect.minY + 31))
            
            // Right-aligned header badge
            let badgeText = "\(room.walls.count) Walls  |  \(room.doors.count) Doors  |  \(room.windows.count) Windows  |  \(room.objects.count) Items"
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: UIColor.systemBlue
            ]
            let badgeStr = NSAttributedString(string: badgeText, attributes: badgeAttrs)
            let badgeSize = badgeStr.size()
            badgeStr.draw(at: CGPoint(x: headerRect.maxX - badgeSize.width - 14, y: headerRect.minY + 20))
            
            // Layout Columns: Left (Floor Plan Canvas 62%), Right (Schedules 38%)
            let contentTop = headerRect.maxY + 8
            let contentHeight = innerRect.maxY - contentTop - 8
            let splitRatio: CGFloat = 0.62
            let leftColWidth = (innerRect.width - 12) * splitRatio
            let rightColX = innerRect.minX + leftColWidth + 12
            let rightColWidth = innerRect.width - leftColWidth - 12
            
            // 3. 2D Floor Plan Drawing Box
            let floorPlanBox = CGRect(x: innerRect.minX, y: contentTop, width: leftColWidth, height: contentHeight)
            cg.setStrokeColor(UIColor(white: 0.82, alpha: 1.0).cgColor)
            cg.setLineWidth(1.0)
            cg.stroke(floorPlanBox)
            
            let fpHeaderRect = CGRect(x: floorPlanBox.minX, y: floorPlanBox.minY, width: floorPlanBox.width, height: 24)
            cg.setFillColor(UIColor(white: 0.94, alpha: 1.0).cgColor)
            cg.fill(fpHeaderRect)
            cg.stroke(fpHeaderRect)
            
            let fpTitle = NSAttributedString(
                string: "2D SCHEMATIC PLAN WITH PER-WALL MEASUREMENTS",
                attributes: [.font: UIFont.boldSystemFont(ofSize: 10), .foregroundColor: UIColor.black]
            )
            fpTitle.draw(at: CGPoint(x: fpHeaderRect.minX + 10, y: fpHeaderRect.minY + 6))
            
            // Render 2D floor plan inside floorPlanBox
            drawFloorPlanToPDF(cg: cg, rect: floorPlanBox.insetBy(dx: 0, dy: 16), room: room)
            
            // 4. Right Column: Schedules & Metrics Box
            let scheduleBox = CGRect(x: rightColX, y: contentTop, width: rightColWidth, height: contentHeight)
            cg.stroke(scheduleBox)
            
            let schedHeaderRect = CGRect(x: scheduleBox.minX, y: scheduleBox.minY, width: scheduleBox.width, height: 24)
            cg.setFillColor(UIColor(white: 0.94, alpha: 1.0).cgColor)
            cg.fill(schedHeaderRect)
            cg.stroke(schedHeaderRect)
            
            let schedTitle = NSAttributedString(
                string: "ROOM SPECIFICATIONS & SCHEDULES",
                attributes: [.font: UIFont.boldSystemFont(ofSize: 10), .foregroundColor: UIColor.black]
            )
            schedTitle.draw(at: CGPoint(x: schedHeaderRect.minX + 10, y: schedHeaderRect.minY + 6))
            
            drawSchedulesToPDF(cg: cg, rect: scheduleBox.insetBy(dx: 10, dy: 30), room: room)
        }
        
        try pdfData.write(to: outputURL)
        return outputURL
    }
    
    // MARK: - 2D Floor Plan Rendering
    
    private static func drawFloorPlanToPDF(cg: CGContext, rect: CGRect, room: MaquetteRoom) {
        let b = room.boundingBox
        let roomW = max(b.max.x - b.min.x, 1.0)
        let roomD = max(b.max.z - b.min.z, 1.0)
        
        let padX: CGFloat = 40.0
        let padY: CGFloat = 40.0
        let drawArea = rect.insetBy(dx: padX, dy: padY)
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
        
        // 1. Grid lines (1 meter)
        let gridM = scale * 1.0
        if gridM > 12 {
            cg.setStrokeColor(UIColor(white: 0.92, alpha: 1.0).cgColor)
            cg.setLineWidth(0.75)
            let startX = midX.truncatingRemainder(dividingBy: gridM) - gridM
            var gx = startX
            while gx <= drawArea.maxX {
                if gx >= drawArea.minX {
                    cg.move(to: CGPoint(x: gx, y: drawArea.minY))
                    cg.addLine(to: CGPoint(x: gx, y: drawArea.maxY))
                }
                gx += gridM
            }
            let startY = midY.truncatingRemainder(dividingBy: gridM) - gridM
            var gy = startY
            while gy <= drawArea.maxY {
                if gy >= drawArea.minY {
                    cg.move(to: CGPoint(x: drawArea.minX, y: gy))
                    cg.addLine(to: CGPoint(x: drawArea.maxX, y: gy))
                }
                gy += gridM
            }
            cg.strokePath()
        }
        
        // 2. Floor polygon fill
        let fp1 = toPDF(b.min.x, b.min.z)
        let fp2 = toPDF(b.max.x, b.min.z)
        let fp3 = toPDF(b.max.x, b.max.z)
        let fp4 = toPDF(b.min.x, b.max.z)
        cg.setFillColor(UIColor(white: 0.97, alpha: 1.0).cgColor)
        cg.move(to: fp1)
        cg.addLine(to: fp2)
        cg.addLine(to: fp3)
        cg.addLine(to: fp4)
        cg.closePath()
        cg.fillPath()
        
        // 3. Furniture / Fixtures
        for obj in room.objects {
            let center = toPDF(obj.position.x, obj.position.z)
            let w = CGFloat(obj.width) * scale
            let d = CGFloat(obj.depth) * scale
            let rot = CGFloat(obj.rotationY)
            
            cg.saveGState()
            cg.translateBy(x: center.x, y: center.y)
            cg.rotate(by: rot)
            
            let objRect = CGRect(x: -w/2, y: -d/2, width: w, height: d)
            cg.setFillColor(UIColor.systemBlue.withAlphaComponent(0.12).cgColor)
            cg.fill(objRect)
            cg.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.75).cgColor)
            cg.setLineWidth(1.2)
            cg.stroke(objRect)
            
            let fFont = UIFont.systemFont(ofSize: max(7, min(10, w * 0.2)), weight: .medium)
            let fStr = NSAttributedString(string: obj.displayName, attributes: [.font: fFont, .foregroundColor: UIColor.systemBlue])
            let fSize = fStr.size()
            if fSize.width <= w + 4 && fSize.height <= d + 4 {
                fStr.draw(at: CGPoint(x: -fSize.width/2, y: -fSize.height/2))
            }
            
            cg.restoreGState()
        }
        
        // 4. Architectural Walls with Per-Wall Measurement Badges
        cg.setStrokeColor(UIColor(red: 0.1, green: 0.12, blue: 0.18, alpha: 1.0).cgColor)
        cg.setLineWidth(max(4.0, scale * 0.12))
        cg.setLineCap(.square)
        cg.setLineJoin(.miter)
        
        for wall in room.walls {
            let p1 = toPDF(Float(wall.startPoint2D.x), Float(wall.startPoint2D.y))
            let p2 = toPDF(Float(wall.endPoint2D.x), Float(wall.endPoint2D.y))
            cg.move(to: p1)
            cg.addLine(to: p2)
            cg.strokePath()
            
            // Wall dimension label
            let wallLen = wall.length
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let segLen = sqrt(dx*dx + dy*dy)
            
            if segLen > 30 {
                let midP = CGPoint(x: (p1.x + p2.x)/2.0, y: (p1.y + p2.y)/2.0)
                let normalX = -dy / segLen
                let normalY = dx / segLen
                let offsetDist: CGFloat = 13.0
                let labelPos = CGPoint(x: midP.x + normalX * offsetDist, y: midP.y + normalY * offsetDist)
                
                let distText = String(format: "%.2f m", wallLen)
                let textAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: 8.5, weight: .bold),
                    .foregroundColor: UIColor(white: 0.2, alpha: 1.0)
                ]
                let str = NSAttributedString(string: distText, attributes: textAttrs)
                let tSize = str.size()
                
                // Pill background
                let pillRect = CGRect(x: labelPos.x - tSize.width/2 - 3, y: labelPos.y - tSize.height/2 - 1.5, width: tSize.width + 6, height: tSize.height + 3)
                cg.setFillColor(UIColor(white: 1.0, alpha: 0.95).cgColor)
                cg.setStrokeColor(UIColor(white: 0.8, alpha: 1.0).cgColor)
                cg.setLineWidth(0.75)
                cg.fill(pillRect)
                cg.stroke(pillRect)
                
                str.draw(at: CGPoint(x: labelPos.x - tSize.width/2, y: labelPos.y - tSize.height/2))
            }
        }
        
        // 5. Windows
        cg.setStrokeColor(UIColor.systemTeal.cgColor)
        cg.setLineWidth(3.5)
        for win in room.windows {
            let halfW = win.width / 2.0
            let rot = win.transform.rotationY
            let p1 = toPDF(win.position.x - halfW*cos(rot), win.position.z - halfW*sin(rot))
            let p2 = toPDF(win.position.x + halfW*cos(rot), win.position.z + halfW*sin(rot))
            cg.move(to: p1)
            cg.addLine(to: p2)
            cg.strokePath()
        }
        
        // 6. Doors with 90° Swing Arc
        for door in room.doors {
            let pos = door.position
            let rot = door.transform.rotationY
            let w = door.width
            let hinge = toPDF(pos.x - (w/2)*cos(rot), pos.z - (w/2)*sin(rot))
            let radius = CGFloat(w) * scale
            
            let leafEnd = CGPoint(
                x: hinge.x + radius * CGFloat(cos(rot + .pi/2)),
                y: hinge.y + radius * CGFloat(sin(rot + .pi/2))
            )
            cg.setStrokeColor(UIColor.systemBlue.cgColor)
            cg.setLineWidth(2.0)
            cg.move(to: hinge)
            cg.addLine(to: leafEnd)
            cg.strokePath()
            
            // Swing arc
            cg.setLineWidth(1.0)
            cg.setLineDash(phase: 0, lengths: [3, 3])
            cg.addArc(
                center: hinge,
                radius: radius,
                startAngle: CGFloat(rot),
                endAngle: CGFloat(rot + .pi/2),
                clockwise: false
            )
            cg.strokePath()
            cg.setLineDash(phase: 0, lengths: [])
        }
        
        // 7. Overall Width & Depth Dimensions
        let offsetM: Float = 0.4
        let topStart = toPDF(b.min.x, b.min.z - offsetM)
        let topEnd = toPDF(b.max.x, b.min.z - offsetM)
        cg.setStrokeColor(UIColor.darkGray.cgColor)
        cg.setLineWidth(1.0)
        cg.move(to: topStart)
        cg.addLine(to: topEnd)
        cg.move(to: CGPoint(x: topStart.x, y: topStart.y - 5))
        cg.addLine(to: CGPoint(x: topStart.x, y: topStart.y + 5))
        cg.move(to: CGPoint(x: topEnd.x, y: topEnd.y - 5))
        cg.addLine(to: CGPoint(x: topEnd.x, y: topEnd.y + 5))
        cg.strokePath()
        
        let wStr = NSAttributedString(
            string: String(format: "%.2f m", room.roomWidth),
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 9, weight: .bold), .foregroundColor: UIColor.darkGray]
        )
        wStr.draw(at: CGPoint(x: (topStart.x + topEnd.x)/2 - wStr.size().width/2, y: topStart.y - 14))
        
        let rightStart = toPDF(b.max.x + offsetM, b.min.z)
        let rightEnd = toPDF(b.max.x + offsetM, b.max.z)
        cg.move(to: rightStart)
        cg.addLine(to: rightEnd)
        cg.move(to: CGPoint(x: rightStart.x - 5, y: rightStart.y))
        cg.addLine(to: CGPoint(x: rightStart.x + 5, y: rightStart.y))
        cg.move(to: CGPoint(x: rightEnd.x - 5, y: rightEnd.y))
        cg.addLine(to: CGPoint(x: rightEnd.x + 5, y: rightEnd.y))
        cg.strokePath()
        
        let dStr = NSAttributedString(
            string: String(format: "%.2f m", room.roomDepth),
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 9, weight: .bold), .foregroundColor: UIColor.darkGray]
        )
        dStr.draw(at: CGPoint(x: rightStart.x + 8, y: (rightStart.y + rightEnd.y)/2 - dStr.size().height/2))
        
        // 8. North Arrow
        let northOrigin = CGPoint(x: drawArea.minX + 16, y: drawArea.minY + 20)
        cg.setStrokeColor(UIColor.darkGray.cgColor)
        cg.setLineWidth(1.5)
        cg.move(to: CGPoint(x: northOrigin.x, y: northOrigin.y + 14))
        cg.addLine(to: CGPoint(x: northOrigin.x, y: northOrigin.y - 14))
        cg.addLine(to: CGPoint(x: northOrigin.x - 4, y: northOrigin.y - 6))
        cg.move(to: CGPoint(x: northOrigin.x, y: northOrigin.y - 14))
        cg.addLine(to: CGPoint(x: northOrigin.x + 4, y: northOrigin.y - 6))
        cg.strokePath()
        let nStr = NSAttributedString(
            string: "N",
            attributes: [.font: UIFont.boldSystemFont(ofSize: 9), .foregroundColor: UIColor.darkGray]
        )
        nStr.draw(at: CGPoint(x: northOrigin.x - 3, y: northOrigin.y - 25))
    }
    
    // MARK: - Architectural Schedules Rendering
    
    private static func drawSchedulesToPDF(cg: CGContext, rect: CGRect, room: MaquetteRoom) {
        var curY = rect.minY
        
        // Section A: Room Metrics Summary
        let boldHeadingAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 10),
            .foregroundColor: UIColor(red: 0.1, green: 0.12, blue: 0.25, alpha: 1.0)
        ]
        let cellTitleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: UIColor.darkGray
        ]
        let cellValAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: UIColor.black
        ]
        
        NSAttributedString(string: "1. ROOM DIMENSIONS & QUANTITIES", attributes: boldHeadingAttrs).draw(at: CGPoint(x: rect.minX, y: curY))
        curY += 16
        
        let metrics: [(String, String)] = [
            ("Floor Area", "\(room.formattedAreaMetric) (\(room.formattedAreaImperial))"),
            ("Perimeter", String(format: "%.2f m (%.1f ft)", room.perimeterMeters, room.perimeterMeters * 3.28084)),
            ("Ceiling Height", String(format: "%.2f m (%.1f ft)", room.ceilingHeight, room.ceilingHeight * 3.28084)),
            ("Estimated Volume", String(format: "%.1f m³ (%.0f ft³)", room.volumeCubicMeters, room.volumeCubicMeters * 35.3147)),
            ("Wall Count", "\(room.walls.count) segments"),
            ("Openings", "\(room.doors.count) doors, \(room.windows.count) windows")
        ]
        
        for (label, val) in metrics {
            NSAttributedString(string: label, attributes: cellTitleAttrs).draw(at: CGPoint(x: rect.minX + 8, y: curY))
            NSAttributedString(string: val, attributes: cellValAttrs).draw(at: CGPoint(x: rect.minX + 110, y: curY))
            curY += 14
        }
        
        curY += 8
        cg.setStrokeColor(UIColor(white: 0.88, alpha: 1.0).cgColor)
        cg.setLineWidth(1.0)
        cg.move(to: CGPoint(x: rect.minX, y: curY))
        cg.addLine(to: CGPoint(x: rect.maxX, y: curY))
        cg.strokePath()
        curY += 10
        
        // Section B: Wall Segments Schedule
        NSAttributedString(string: "2. WALL SEGMENT SCHEDULE", attributes: boldHeadingAttrs).draw(at: CGPoint(x: rect.minX, y: curY))
        curY += 15
        
        // Table header
        NSAttributedString(string: "WALL", attributes: [.font: UIFont.boldSystemFont(ofSize: 8), .foregroundColor: UIColor.darkGray]).draw(at: CGPoint(x: rect.minX + 8, y: curY))
        NSAttributedString(string: "ORIENTATION", attributes: [.font: UIFont.boldSystemFont(ofSize: 8), .foregroundColor: UIColor.darkGray]).draw(at: CGPoint(x: rect.minX + 60, y: curY))
        NSAttributedString(string: "LENGTH", attributes: [.font: UIFont.boldSystemFont(ofSize: 8), .foregroundColor: UIColor.darkGray]).draw(at: CGPoint(x: rect.minX + 140, y: curY))
        NSAttributedString(string: "HEIGHT", attributes: [.font: UIFont.boldSystemFont(ofSize: 8), .foregroundColor: UIColor.darkGray]).draw(at: CGPoint(x: rect.minX + 200, y: curY))
        curY += 12
        
        let wallsToDisplay = room.walls.prefix(8)
        var wIndex = 1
        for wall in wallsToDisplay {
            let rowColor = (wIndex % 2 == 0) ? UIColor(white: 0.97, alpha: 1.0) : UIColor.white
            let rowRect = CGRect(x: rect.minX + 4, y: curY - 2, width: rect.width - 8, height: 13)
            cg.setFillColor(rowColor.cgColor)
            cg.fill(rowRect)
            
            NSAttributedString(string: "W\(wIndex)", attributes: cellValAttrs).draw(at: CGPoint(x: rect.minX + 8, y: curY))
            NSAttributedString(string: wall.displayName, attributes: cellTitleAttrs).draw(at: CGPoint(x: rect.minX + 60, y: curY))
            NSAttributedString(string: String(format: "%.2f m", wall.length), attributes: cellValAttrs).draw(at: CGPoint(x: rect.minX + 140, y: curY))
            NSAttributedString(string: String(format: "%.2f m", wall.height), attributes: cellValAttrs).draw(at: CGPoint(x: rect.minX + 200, y: curY))
            
            curY += 13
            wIndex += 1
        }
        
        if room.walls.count > 8 {
            NSAttributedString(string: "+ \(room.walls.count - 8) additional wall segments...", attributes: cellTitleAttrs).draw(at: CGPoint(x: rect.minX + 8, y: curY))
            curY += 13
        }
        
        curY += 8
        cg.move(to: CGPoint(x: rect.minX, y: curY))
        cg.addLine(to: CGPoint(x: rect.maxX, y: curY))
        cg.strokePath()
        curY += 10
        
        // Section C: Doors & Windows Schedule
        NSAttributedString(string: "3. DOORS & WINDOWS SCHEDULE", attributes: boldHeadingAttrs).draw(at: CGPoint(x: rect.minX, y: curY))
        curY += 15
        
        for (dIdx, door) in room.doors.prefix(3).enumerated() {
            let dText = "• Door #\(dIdx + 1): Width: \(String(format: "%.2fm", door.width))  •  Height: \(String(format: "%.2fm", door.height))  •  Status: \(door.isOpen ? "Open" : "Closed")"
            NSAttributedString(string: dText, attributes: cellTitleAttrs).draw(at: CGPoint(x: rect.minX + 8, y: curY))
            curY += 12
        }
        
        for (wIdx, win) in room.windows.prefix(3).enumerated() {
            let wText = "• Window #\(wIdx + 1): Width: \(String(format: "%.2fm", win.width))  •  Height: \(String(format: "%.2fm", win.height))"
            NSAttributedString(string: wText, attributes: cellTitleAttrs).draw(at: CGPoint(x: rect.minX + 8, y: curY))
            curY += 12
        }
        
        if room.doors.isEmpty && room.windows.isEmpty {
            NSAttributedString(string: "No door or window openings scanned.", attributes: cellTitleAttrs).draw(at: CGPoint(x: rect.minX + 8, y: curY))
            curY += 12
        }
        
        curY += 8
        cg.move(to: CGPoint(x: rect.minX, y: curY))
        cg.addLine(to: CGPoint(x: rect.maxX, y: curY))
        cg.strokePath()
        curY += 10
        
        // Section D: Furniture & Equipment Inventory
        NSAttributedString(string: "4. FIXTURES & FURNITURE INVENTORY (\(room.objects.count) Items)", attributes: boldHeadingAttrs).draw(at: CGPoint(x: rect.minX, y: curY))
        curY += 15
        
        for item in room.objects.prefix(5) {
            let itemDesc = "• \(item.displayName): \(String(format: "%.2fm (W) × %.2fm (D) × %.2fm (H)", item.width, item.depth, item.height))"
            NSAttributedString(string: itemDesc, attributes: cellTitleAttrs).draw(at: CGPoint(x: rect.minX + 8, y: curY))
            curY += 12
        }
        
        if room.objects.isEmpty {
            NSAttributedString(string: "No furniture items detected in scan.", attributes: cellTitleAttrs).draw(at: CGPoint(x: rect.minX + 8, y: curY))
        }
    }
}
