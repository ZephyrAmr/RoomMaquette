import UIKit
import PDFKit
import CoreGraphics
import simd

public class PlanImporter {
    
    public static func `import`(from url: URL) throws -> ImportedPlan {
        let isSecured = url.startAccessingSecurityScopedResource()
        defer {
            if isSecured {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let ext = url.pathExtension.lowercased()
        let planName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        
        switch ext {
        case "pdf":
            return try importPDF(from: url, name: planName)
        case "png", "jpg", "jpeg", "heic":
            return try importRasterImage(from: url, name: planName)
        case "dxf":
            return try importDXF(from: url, name: planName)
        case "svg":
            return try importSVG(from: url, name: planName)
        case "json":
            return try importJSON(from: url, name: planName)
        case "ifc":
            let room = try IFCImporter.importIFC(from: url, roomName: planName)
            let lines = room.walls.map { wall -> PlanLine in
                let s = wall.startPoint2D
                let e = wall.endPoint2D
                return PlanLine(startX: Float(s.x), startZ: Float(s.y), endX: Float(e.x), endZ: Float(e.y))
            }
            let b = room.boundingBox
            return ImportedPlan(
                name: room.name,
                fileType: .dxf,
                originalWidthMeters: max(b.max.x - b.min.x, 6.0),
                originalDepthMeters: max(b.max.z - b.min.z, 6.0),
                renderedImageData: nil,
                vectorLines: lines,
                detectedDoors: room.doors,
                detectedWindows: room.windows,
                detectedOpenings: room.openings,
                isHeuristicScale: false
            )
        default:
            if let imagePlan = try? importRasterImage(from: url, name: planName) {
                return imagePlan
            }
            throw NSError(domain: "PlanImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported plan format (.\(ext)). Use PDF, PNG, JPG, DXF, SVG, or IFC."])
        }
    }
    
    /// Converts an ImportedPlan directly into a playable MaquetteRoom with synthesized walls, doors, windows & openings
    public static func createRoom(from plan: ImportedPlan, name: String? = nil) -> MaquetteRoom {
        let roomName = (name ?? plan.name).trimmingCharacters(in: .whitespaces)
        let walls = synthesizeWalls(from: plan)
        
        return MaquetteRoom(
            id: UUID(),
            name: roomName.isEmpty ? "Imported Plan Room" : roomName,
            createdAt: Date(),
            modifiedAt: Date(),
            notes: "Created from imported plan: \(plan.name)",
            walls: walls,
            doors: plan.detectedDoors ?? [],
            windows: plan.detectedWindows ?? [],
            openings: plan.detectedOpenings ?? [],
            objects: [],
            importedPlan: plan
        )
    }
    
    /// Synthesizes 3D WallSurfaces matching the plan's metric vectorLines
    public static func synthesizeWalls(from plan: ImportedPlan, ceilingH: Float = 2.60) -> [WallSurface] {
        var walls: [WallSurface] = []
        for line in plan.vectorLines {
            let wallLen = line.length
            guard wallLen >= 0.25 else { continue }
            let midX = (line.startX + line.endX) * 0.5
            let midZ = (line.startZ + line.endZ) * 0.5
            let ang = line.angle
            
            let cosA = cos(ang)
            let sinA = sin(ang)
            let rotMat = simd_float4x4(
                SIMD4<Float>(cosA, 0, sinA, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-sinA, 0, cosA, 0),
                SIMD4<Float>(midX, ceilingH * 0.5, midZ, 1)
            )
            walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(wallLen, ceilingH, 0.15), transform: rotMat))
        }
        
        if walls.isEmpty {
            let hw = plan.originalWidthMeters * 0.5
            let hd = plan.originalDepthMeters * 0.5
            let perimLines = [
                PlanLine(startX: -hw, startZ: -hd, endX: hw, endZ: -hd),
                PlanLine(startX: hw, startZ: -hd, endX: hw, endZ: hd),
                PlanLine(startX: hw, startZ: hd, endX: -hw, endZ: hd),
                PlanLine(startX: -hw, startZ: hd, endX: -hw, endZ: -hd)
            ]
            for l in perimLines {
                let mx = (l.startX + l.endX) * 0.5
                let mz = (l.startZ + l.endZ) * 0.5
                let ang = l.angle
                let rotMat = simd_float4x4(
                    SIMD4<Float>(cos(ang), 0, sin(ang), 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(-sin(ang), 0, cos(ang), 0),
                    SIMD4<Float>(mx, ceilingH * 0.5, mz, 1)
                )
                walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(l.length, ceilingH, 0.15), transform: rotMat))
            }
        }
        return walls
    }
    
    /// Uniformly rescales an ImportedPlan's physical metric dimensions, vector lines, and detected openings
    public static func rescaledPlan(_ plan: ImportedPlan, by factor: Float) -> ImportedPlan {
        let f = max(0.1, min(factor, 10.0))
        var copy = plan
        copy.originalWidthMeters *= f
        copy.originalDepthMeters *= f
        copy.isHeuristicScale = false
        copy.vectorLines = plan.vectorLines.map { line in
            PlanLine(
                startX: line.startX * f,
                startZ: line.startZ * f,
                endX: line.endX * f,
                endZ: line.endZ * f
            )
        }
        if let ds = plan.detectedDoors {
            copy.detectedDoors = ds.map { d in
                var item = d
                var m = d.transform.matrix
                m.columns.3.x *= f
                m.columns.3.z *= f
                item.transform = TransformMatrix(m)
                item.dimensions.x *= f
                return item
            }
        }
        if let ws = plan.detectedWindows {
            copy.detectedWindows = ws.map { w in
                var item = w
                var m = w.transform.matrix
                m.columns.3.x *= f
                m.columns.3.z *= f
                item.transform = TransformMatrix(m)
                item.dimensions.x *= f
                return item
            }
        }
        if let os = plan.detectedOpenings {
            copy.detectedOpenings = os.map { o in
                var item = o
                var m = o.transform.matrix
                m.columns.3.x *= f
                m.columns.3.z *= f
                item.transform = TransformMatrix(m)
                item.dimensions.x *= f
                return item
            }
        }
        return copy
    }
    
    // MARK: - PDF Blueprint Importer (Vector-First + High-Res Raster Fallback)
    
    private final class PDFVectorExtractContext {
        var currentCTM: CGAffineTransform = .identity
        var ctmStack: [CGAffineTransform] = []
        var subpathStart: CGPoint = .zero
        var currentPt: CGPoint = .zero
        var pendingSegments: [(CGPoint, CGPoint)] = []
        var strokedSegments: [(CGPoint, CGPoint)] = []
        var pageBounds: CGRect = .zero
        
        func commitSubpath() {
            strokedSegments.append(contentsOf: pendingSegments)
            pendingSegments.removeAll(keepingCapacity: true)
        }
    }
    
    private static func importPDF(from url: URL, name: String) throws -> ImportedPlan {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            throw NSError(domain: "PlanImporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not open PDF blueprint document."])
        }
        
        let bounds = page.bounds(for: .mediaBox)
        let width = bounds.width
        let height = bounds.height
        
        // Render 2048px high-resolution raster image of the blueprint page
        let targetWidth: CGFloat = 2048.0
        let targetHeight = max(targetWidth * (height / max(width, 1.0)), 120.0)
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.setFillColor(UIColor.white.cgColor)
            cgCtx.fill(CGRect(origin: .zero, size: targetSize))
            
            cgCtx.saveGState()
            cgCtx.translateBy(x: 0, y: targetHeight)
            cgCtx.scaleBy(x: targetWidth / max(width, 1.0), y: -targetHeight / max(height, 1.0))
            cgCtx.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: cgCtx)
            cgCtx.restoreGState()
        }
        
        guard let pngData = image.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "PlanImporter", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to rasterize PDF page."])
        }
        
        // Attempt true vector path extraction from the PDF stream first
        if let cgPage = page.pageRef {
            let pdfRawSegs = extractVectorSegmentsFromPDFPage(cgPage, bounds: bounds, targetSize: targetSize)
            if pdfRawSegs.count >= 8 {
                let mergedPx = cleanVectorSegmentsPx(pdfRawSegs, canvasW: Float(targetWidth), canvasH: Float(targetHeight))
                if mergedPx.count >= 6 {
                    let (_, ocrMpp) = PlanImageVectorizer.detectScaleFromRenderedImage(
                        image: image,
                        pixelLines: mergedPx,
                        width: Int(targetWidth),
                        height: Int(targetHeight)
                    )
                    
                    let (mpp, heuristic) = computeMetricScale(
                        ocrMpp: ocrMpp,
                        linesPx: mergedPx,
                        canvasW: Float(targetWidth)
                    )
                    let metricLines = centerAndScaleLines(mergedPx, canvasW: Float(targetWidth), canvasH: Float(targetHeight), mpp: mpp)
                    return ImportedPlan(
                        name: name,
                        fileType: .pdf,
                        originalWidthMeters: Float(targetWidth) * mpp,
                        originalDepthMeters: Float(targetHeight) * mpp,
                        renderedImageData: pngData,
                        vectorLines: metricLines,
                        isHeuristicScale: heuristic
                    )
                }
            }
        }
        
        // Fallback for scanned-bitmap PDFs: full Vision OCR + Skeleton Vectorizer
        let vectorized = PlanImageVectorizer.vectorize(image: image)
        return ImportedPlan(
            name: name,
            fileType: .pdf,
            originalWidthMeters: vectorized.originalWidthMeters,
            originalDepthMeters: vectorized.originalDepthMeters,
            renderedImageData: pngData,
            vectorLines: vectorized.vectorLines,
            detectedDoors: vectorized.doors,
            detectedWindows: vectorized.windows,
            detectedOpenings: vectorized.openings,
            isHeuristicScale: vectorized.usedHeuristicScale
        )
    }
    
    private static func extractVectorSegmentsFromPDFPage(_ cgPage: CGPDFPage, bounds: CGRect, targetSize: CGSize) -> [PlanLine] {
        let ctx = PDFVectorExtractContext()
        ctx.pageBounds = bounds
        
        let table = CGPDFOperatorTableCreate()!
        let ptr = Unmanaged.passUnretained(ctx).toOpaque()
        
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let info = info else { return }
            let c = Unmanaged<PDFVectorExtractContext>.fromOpaque(info).takeUnretainedValue()
            c.ctmStack.append(c.currentCTM)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let info = info else { return }
            let c = Unmanaged<PDFVectorExtractContext>.fromOpaque(info).takeUnretainedValue()
            if let last = c.ctmStack.popLast() { c.currentCTM = last }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let info = info else { return }
            let c = Unmanaged<PDFVectorExtractContext>.fromOpaque(info).takeUnretainedValue()
            var f: CGPDFReal = 0, e: CGPDFReal = 0, d: CGPDFReal = 0, cmC: CGPDFReal = 0, b: CGPDFReal = 0, a: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &f),
                  CGPDFScannerPopNumber(scanner, &e),
                  CGPDFScannerPopNumber(scanner, &d),
                  CGPDFScannerPopNumber(scanner, &cmC),
                  CGPDFScannerPopNumber(scanner, &b),
                  CGPDFScannerPopNumber(scanner, &a) else { return }
            let mat = CGAffineTransform(a: a, b: b, c: cmC, d: d, tx: e, ty: f)
            c.currentCTM = mat.concatenating(c.currentCTM)
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let info = info else { return }
            let c = Unmanaged<PDFVectorExtractContext>.fromOpaque(info).takeUnretainedValue()
            var y: CGPDFReal = 0, x: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) else { return }
            let p = CGPoint(x: x, y: y).applying(c.currentCTM)
            c.subpathStart = p
            c.currentPt = p
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let info = info else { return }
            let c = Unmanaged<PDFVectorExtractContext>.fromOpaque(info).takeUnretainedValue()
            var y: CGPDFReal = 0, x: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) else { return }
            let p = CGPoint(x: x, y: y).applying(c.currentCTM)
            c.pendingSegments.append((c.currentPt, p))
            c.currentPt = p
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in
            guard let info = info else { return }
            let c = Unmanaged<PDFVectorExtractContext>.fromOpaque(info).takeUnretainedValue()
            if hypot(c.currentPt.x - c.subpathStart.x, c.currentPt.y - c.subpathStart.y) > 0.5 {
                c.pendingSegments.append((c.currentPt, c.subpathStart))
            }
            c.currentPt = c.subpathStart
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let info = info else { return }
            let c = Unmanaged<PDFVectorExtractContext>.fromOpaque(info).takeUnretainedValue()
            var h: CGPDFReal = 0, w: CGPDFReal = 0, y: CGPDFReal = 0, x: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &h),
                  CGPDFScannerPopNumber(scanner, &w),
                  CGPDFScannerPopNumber(scanner, &y),
                  CGPDFScannerPopNumber(scanner, &x) else { return }
            let p0 = CGPoint(x: x, y: y).applying(c.currentCTM)
            let p1 = CGPoint(x: x + w, y: y).applying(c.currentCTM)
            let p2 = CGPoint(x: x + w, y: y + h).applying(c.currentCTM)
            let p3 = CGPoint(x: x, y: y + h).applying(c.currentCTM)
            c.pendingSegments.append((p0, p1))
            c.pendingSegments.append((p1, p2))
            c.pendingSegments.append((p2, p3))
            c.pendingSegments.append((p3, p0))
        }
        for paintOp in ["S", "s", "B", "b", "B*", "b*", "f", "F", "f*"] {
            CGPDFOperatorTableSetCallback(table, paintOp) { _, info in
                guard let info = info else { return }
                Unmanaged<PDFVectorExtractContext>.fromOpaque(info).takeUnretainedValue().commitSubpath()
            }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in
            guard let info = info else { return }
            Unmanaged<PDFVectorExtractContext>.fromOpaque(info).takeUnretainedValue().pendingSegments.removeAll(keepingCapacity: true)
        }
        
        let stream = CGPDFContentStreamCreateWithPage(cgPage)
        let scanner = CGPDFScannerCreate(stream, table, ptr)
        CGPDFScannerScan(scanner)
        
        let sx = Float(targetSize.width / max(bounds.width, 1.0))
        let sy = Float(targetSize.height / max(bounds.height, 1.0))
        let bx = Float(bounds.minX)
        let by = Float(bounds.minY)
        let hPx = Float(targetSize.height)
        
        return ctx.strokedSegments.compactMap { seg -> PlanLine? in
            let x1 = (Float(seg.0.x) - bx) * sx
            let y1 = hPx - (Float(seg.0.y) - by) * sy
            let x2 = (Float(seg.1.x) - bx) * sx
            let y2 = hPx - (Float(seg.1.y) - by) * sy
            let line = PlanLine(startX: x1, startZ: y1, endX: x2, endZ: y2)
            return line.length >= 22.0 ? line : nil
        }
    }
    
    // MARK: - Raster Image Importer (PNG, JPG, HEIC)
    
    private static func importRasterImage(from url: URL, name: String) throws -> ImportedPlan {
        let data = try Data(contentsOf: url)
        guard let image = UIImage(data: data) else {
            throw NSError(domain: "PlanImporter", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid image file."])
        }
        
        let vectorized = PlanImageVectorizer.vectorize(image: image)
        let compressed = image.jpegData(compressionQuality: 0.85) ?? data
        
        return ImportedPlan(
            name: name,
            fileType: .image,
            originalWidthMeters: vectorized.originalWidthMeters,
            originalDepthMeters: vectorized.originalDepthMeters,
            renderedImageData: compressed,
            vectorLines: vectorized.vectorLines,
            detectedDoors: vectorized.doors,
            detectedWindows: vectorized.windows,
            detectedOpenings: vectorized.openings,
            isHeuristicScale: vectorized.usedHeuristicScale
        )
    }
    
    // MARK: - CAD DXF Importer ($INSUNITS, LINE, LWPOLYLINE, POLYLINE, ARC Doors)
    
    private static func importDXF(from url: URL, name: String) throws -> ImportedPlan {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        
        // 1. Check $INSUNITS header
        var insUnitsCode: Int = 0
        for idx in 0..<max(0, lines.count - 3) {
            if lines[idx].trimmingCharacters(in: .whitespaces) == "$INSUNITS" {
                let code = lines[idx + 1].trimmingCharacters(in: .whitespaces)
                if code == "70", let u = Int(lines[idx + 2].trimmingCharacters(in: .whitespaces)) {
                    insUnitsCode = u
                    break
                }
            }
        }
        
        struct DXFArcRaw {
            var cx: Float
            var cy: Float
            var radius: Float
            var startDeg: Float
            var endDeg: Float
        }
        
        var rawLines: [PlanLine] = []
        var rawArcs: [DXFArcRaw] = []
        
        func shouldSkipLayer(_ layerName: String) -> Bool {
            let l = layerName.lowercased()
            return l.contains("dim") || l.contains("text") || l.contains("anno") || l.contains("grid") || l.contains("hatch") || l.contains("title")
        }
        
        var i = 0
        while i < lines.count {
            let token = lines[i].trimmingCharacters(in: .whitespaces)
            
            if token == "LINE" {
                var x1: Float?, y1: Float?, x2: Float?, y2: Float?
                var layer = ""
                while i + 2 < lines.count {
                    i += 1
                    let code = lines[i].trimmingCharacters(in: .whitespaces)
                    if code == "0" { i -= 1; break }
                    i += 1
                    let valStr = lines[i].trimmingCharacters(in: .whitespaces)
                    if code == "8" { layer = valStr }
                    else if code == "10" { x1 = Float(valStr) }
                    else if code == "20" { y1 = Float(valStr) }
                    else if code == "11" { x2 = Float(valStr) }
                    else if code == "21" { y2 = Float(valStr) }
                }
                if !shouldSkipLayer(layer), let x1 = x1, let y1 = y1, let x2 = x2, let y2 = y2 {
                    rawLines.append(PlanLine(startX: x1, startZ: -y1, endX: x2, endZ: -y2))
                }
            } else if token == "LWPOLYLINE" {
                var layer = ""
                var closedFlag = 0
                var pts: [(Float, Float)] = []
                var curX: Float? = nil
                while i + 2 < lines.count {
                    i += 1
                    let code = lines[i].trimmingCharacters(in: .whitespaces)
                    if code == "0" { i -= 1; break }
                    i += 1
                    let valStr = lines[i].trimmingCharacters(in: .whitespaces)
                    if code == "8" { layer = valStr }
                    else if code == "70" { closedFlag = Int(valStr) ?? 0 }
                    else if code == "10" { curX = Float(valStr) }
                    else if code == "20", let x = curX, let y = Float(valStr) {
                        pts.append((x, -y))
                        curX = nil
                    }
                }
                if !shouldSkipLayer(layer), pts.count >= 2 {
                    for k in 0..<(pts.count - 1) {
                        rawLines.append(PlanLine(startX: pts[k].0, startZ: pts[k].1, endX: pts[k + 1].0, endZ: pts[k + 1].1))
                    }
                    if (closedFlag & 1) != 0, let first = pts.first, let last = pts.last {
                        rawLines.append(PlanLine(startX: last.0, startZ: last.1, endX: first.0, endZ: first.1))
                    }
                }
            } else if token == "POLYLINE" {
                var layer = ""
                var closedFlag = 0
                var pts: [(Float, Float)] = []
                while i < lines.count - 1 {
                    i += 1
                    let c = lines[i].trimmingCharacters(in: .whitespaces)
                    if c == "0" {
                        if i + 1 < lines.count {
                            let nextEntity = lines[i + 1].trimmingCharacters(in: .whitespaces)
                            if nextEntity == "SEQEND" { break }
                            if nextEntity == "VERTEX" {
                                i += 1
                                var vx: Float?, vy: Float?
                                while i + 2 < lines.count {
                                    i += 1
                                    let vc = lines[i].trimmingCharacters(in: .whitespaces)
                                    if vc == "0" { i -= 1; break }
                                    i += 1
                                    let vv = lines[i].trimmingCharacters(in: .whitespaces)
                                    if vc == "10" { vx = Float(vv) }
                                    else if vc == "20" { vy = Float(vv) }
                                }
                                if let vx = vx, let vy = vy { pts.append((vx, -vy)) }
                            }
                        }
                    } else if i + 1 < lines.count {
                        i += 1
                        let vv = lines[i].trimmingCharacters(in: .whitespaces)
                        if c == "8" { layer = vv }
                        else if c == "70" { closedFlag = Int(vv) ?? 0 }
                    }
                }
                if !shouldSkipLayer(layer), pts.count >= 2 {
                    for k in 0..<(pts.count - 1) {
                        rawLines.append(PlanLine(startX: pts[k].0, startZ: pts[k].1, endX: pts[k + 1].0, endZ: pts[k + 1].1))
                    }
                    if (closedFlag & 1) != 0, let first = pts.first, let last = pts.last {
                        rawLines.append(PlanLine(startX: last.0, startZ: last.1, endX: first.0, endZ: first.1))
                    }
                }
            } else if token == "ARC" {
                var layer = ""
                var cx: Float?, cy: Float?, r: Float?, sA: Float?, eA: Float?
                while i + 2 < lines.count {
                    i += 1
                    let code = lines[i].trimmingCharacters(in: .whitespaces)
                    if code == "0" { i -= 1; break }
                    i += 1
                    let valStr = lines[i].trimmingCharacters(in: .whitespaces)
                    if code == "8" { layer = valStr }
                    else if code == "10" { cx = Float(valStr) }
                    else if code == "20" { cy = Float(valStr) }
                    else if code == "40" { r = Float(valStr) }
                    else if code == "50" { sA = Float(valStr) }
                    else if code == "51" { eA = Float(valStr) }
                }
                if !shouldSkipLayer(layer), let cx = cx, let cy = cy, let r = r, let sA = sA, let eA = eA {
                    rawArcs.append(DXFArcRaw(cx: cx, cy: -cy, radius: r, startDeg: sA, endDeg: eA))
                }
            }
            i += 1
        }
        
        // 2. Unit conversion ($INSUNITS -> heuristic fallback)
        var unitScale: Float = 1.0
        var isHeuristic = false
        switch insUnitsCode {
        case 1: unitScale = 0.0254       // Inches
        case 2: unitScale = 0.3048       // Feet
        case 4: unitScale = 0.001        // Millimeters
        case 5: unitScale = 0.01         // Centimeters
        case 6: unitScale = 1.0          // Meters
        default:
            isHeuristic = true
            let lengths = rawLines.map { $0.length }.filter { $0 > 0.01 }.sorted()
            let medLen = lengths.isEmpty ? 4.0 : lengths[lengths.count / 2]
            if medLen > 350.0 { unitScale = 0.001 }
            else if medLen > 45.0 { unitScale = 0.01 }
            else { unitScale = 1.0 }
        }
        
        var minX: Float = .greatestFiniteMagnitude, maxX: Float = -.greatestFiniteMagnitude
        var minZ: Float = .greatestFiniteMagnitude, maxZ: Float = -.greatestFiniteMagnitude
        let scaledLines = rawLines.compactMap { l -> PlanLine? in
            let sl = PlanLine(startX: l.startX * unitScale, startZ: l.startZ * unitScale, endX: l.endX * unitScale, endZ: l.endZ * unitScale)
            guard sl.length >= 0.25 else { return nil }
            minX = min(minX, sl.startX, sl.endX)
            maxX = max(maxX, sl.startX, sl.endX)
            minZ = min(minZ, sl.startZ, sl.endZ)
            maxZ = max(maxZ, sl.startZ, sl.endZ)
            return sl
        }
        
        let cxOff = minX < maxX ? (minX + maxX) * 0.5 : 0.0
        let czOff = minZ < maxZ ? (minZ + maxZ) * 0.5 : 0.0
        let centeredLines = scaledLines.map {
            PlanLine(startX: $0.startX - cxOff, startZ: $0.startZ - czOff, endX: $0.endX - cxOff, endZ: $0.endZ - czOff)
        }
        
        // Extract CAD door swings from quarter-circle arcs
        var detectedDoors: [DoorSurface] = []
        for arc in rawArcs {
            let radM = arc.radius * unitScale
            guard radM >= 0.55 && radM <= 1.35 else { continue }
            var sweep = arc.endDeg - arc.startDeg
            if sweep < 0 { sweep += 360.0 }
            guard sweep >= 68.0 && sweep <= 112.0 else { continue }
            
            let midDeg = (arc.startDeg + sweep * 0.5) * .pi / 180.0
            let hx = arc.cx * unitScale - cxOff
            let hz = arc.cy * unitScale - czOff
            let doorMidX = hx + cos(midDeg) * (radM * 0.45)
            let doorMidZ = hz - sin(midDeg) * (radM * 0.45)
            let rotMat = simd_float4x4(
                SIMD4<Float>(cos(-midDeg), 0, sin(-midDeg), 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-sin(-midDeg), 0, cos(-midDeg), 0),
                SIMD4<Float>(doorMidX, 1.04, doorMidZ, 1)
            )
            detectedDoors.append(DoorSurface(id: UUID(), dimensions: SIMD3<Float>(radM, 2.08, 0.08), transform: rotMat, isOpen: true))
        }
        
        let spanX = minX < maxX ? max(maxX - minX, 2.0) : 10.0
        let spanZ = minZ < maxZ ? max(maxZ - minZ, 2.0) : 10.0
        
        // Render blueprint image
        let imgSize = CGSize(width: 1600, height: max(1600 * CGFloat(spanZ / spanX), 200))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let cadImage = UIGraphicsImageRenderer(size: imgSize, format: format).image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor(red: 0.05, green: 0.12, blue: 0.28, alpha: 1.0).cgColor)
            ctx.fill(CGRect(origin: .zero, size: imgSize))
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(2.0)
            for pl in centeredLines {
                let px1 = CGFloat((pl.startX + spanX * 0.5) / spanX) * (imgSize.width - 80) + 40
                let pz1 = CGFloat((pl.startZ + spanZ * 0.5) / spanZ) * (imgSize.height - 80) + 40
                let px2 = CGFloat((pl.endX + spanX * 0.5) / spanX) * (imgSize.width - 80) + 40
                let pz2 = CGFloat((pl.endZ + spanZ * 0.5) / spanZ) * (imgSize.height - 80) + 40
                ctx.move(to: CGPoint(x: px1, y: pz1))
                ctx.addLine(to: CGPoint(x: px2, y: pz2))
            }
            ctx.strokePath()
        }
        
        return ImportedPlan(
            name: name,
            fileType: .dxf,
            originalWidthMeters: spanX,
            originalDepthMeters: spanZ,
            renderedImageData: cadImage.pngData(),
            vectorLines: centeredLines,
            detectedDoors: detectedDoors.isEmpty ? nil : detectedDoors,
            isHeuristicScale: isHeuristic,
            sourceText: content
        )
    }
    
    // MARK: - SVG XML Importer (<line>, <rect>, <polyline>, <polygon>, <path>, <g transform>)
    
    private final class SVGXMLCollector: NSObject, XMLParserDelegate {
        var viewBox: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var hasViewBox: Bool = false
        var rawLines: [PlanLine] = []
        private var transformStack: [CGAffineTransform] = [.identity]
        
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let tag = elementName.lowercased()
            let curTransform = transformStack.last ?? .identity
            let elemTransform = parseTransform(attributeDict["transform"]).concatenating(curTransform)
            transformStack.append(elemTransform)
            
            if tag == "svg" {
                if let vb = attributeDict["viewbox"] ?? attributeDict["viewBox"] {
                    let nums = vb.replacingOccurrences(of: ",", with: " ")
                        .split(separator: " ")
                        .compactMap { Double($0) }
                    if nums.count >= 4 {
                        viewBox = CGRect(x: nums[0], y: nums[1], width: max(nums[2], 10), height: max(nums[3], 10))
                        hasViewBox = true
                    }
                } else if let wStr = attributeDict["width"], let hStr = attributeDict["height"],
                          let w = Double(wStr.replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)),
                          let h = Double(hStr.replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)),
                          !hasViewBox {
                    viewBox = CGRect(x: 0, y: 0, width: max(w, 10), height: max(h, 10))
                }
            } else if tag == "line" {
                let x1 = Double(attributeDict["x1"] ?? "") ?? 0
                let y1 = Double(attributeDict["y1"] ?? "") ?? 0
                let x2 = Double(attributeDict["x2"] ?? "") ?? 0
                let y2 = Double(attributeDict["y2"] ?? "") ?? 0
                addSeg(CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2), xform: elemTransform)
            } else if tag == "rect" {
                let rx = Double(attributeDict["x"] ?? "0") ?? 0
                let ry = Double(attributeDict["y"] ?? "0") ?? 0
                let rw = Double(attributeDict["width"] ?? "0") ?? 0
                let rh = Double(attributeDict["height"] ?? "0") ?? 0
                if rw > 1 && rh > 1 && (rw < viewBox.width * 0.96 || rh < viewBox.height * 0.96) {
                    let p0 = CGPoint(x: rx, y: ry)
                    let p1 = CGPoint(x: rx + rw, y: ry)
                    let p2 = CGPoint(x: rx + rw, y: ry + rh)
                    let p3 = CGPoint(x: rx, y: ry + rh)
                    addSeg(p0, p1, xform: elemTransform)
                    addSeg(p1, p2, xform: elemTransform)
                    addSeg(p2, p3, xform: elemTransform)
                    addSeg(p3, p0, xform: elemTransform)
                }
            } else if tag == "polyline" || tag == "polygon" {
                if let ptsStr = attributeDict["points"] {
                    let coords = ptsStr.replacingOccurrences(of: ",", with: " ")
                        .split(whereSeparator: { $0.isWhitespace })
                        .compactMap { Double($0) }
                    var pts: [CGPoint] = []
                    for k in stride(from: 0, to: coords.count - 1, by: 2) {
                        pts.append(CGPoint(x: coords[k], y: coords[k + 1]))
                    }
                    for k in 0..<max(0, pts.count - 1) {
                        addSeg(pts[k], pts[k + 1], xform: elemTransform)
                    }
                    if tag == "polygon", let first = pts.first, let last = pts.last {
                        addSeg(last, first, xform: elemTransform)
                    }
                }
            } else if tag == "path" {
                if let d = attributeDict["d"] {
                    parseSVGPath(d, xform: elemTransform)
                }
            }
        }
        
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if transformStack.count > 1 {
                transformStack.removeLast()
            }
        }
        
        private func addSeg(_ p1: CGPoint, _ p2: CGPoint, xform: CGAffineTransform) {
            let t1 = p1.applying(xform)
            let t2 = p2.applying(xform)
            let l = PlanLine(startX: Float(t1.x - viewBox.minX), startZ: Float(t1.y - viewBox.minY), endX: Float(t2.x - viewBox.minX), endZ: Float(t2.y - viewBox.minY))
            if l.length > 0.5 { rawLines.append(l) }
        }
        
        private func parseSVGPath(_ d: String, xform: CGAffineTransform) {
            let pattern = #"([MmLlHhVvZz])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = d as NSString
            let matches = regex.matches(in: d, range: NSRange(location: 0, length: ns.length))
            var tokens: [String] = matches.map { ns.substring(with: $0.range) }
            
            var idx = 0
            var cmd: String = "M"
            var cur = CGPoint.zero
            var subStart = CGPoint.zero
            
            func nextNum() -> Double? {
                guard idx < tokens.count, let v = Double(tokens[idx]) else { return nil }
                idx += 1
                return v
            }
            
            while idx < tokens.count {
                let t = tokens[idx]
                if t.count == 1, let ch = t.first, ch.isLetter {
                    cmd = t
                    idx += 1
                    if cmd == "Z" || cmd == "z" {
                        addSeg(cur, subStart, xform: xform)
                        cur = subStart
                    }
                    continue
                }
                switch cmd {
                case "M":
                    if let x = nextNum(), let y = nextNum() {
                        cur = CGPoint(x: x, y: y); subStart = cur; cmd = "L"
                    } else { idx += 1 }
                case "m":
                    if let dx = nextNum(), let dy = nextNum() {
                        cur = CGPoint(x: cur.x + dx, y: cur.y + dy); subStart = cur; cmd = "l"
                    } else { idx += 1 }
                case "L":
                    if let x = nextNum(), let y = nextNum() {
                        let nxt = CGPoint(x: x, y: y); addSeg(cur, nxt, xform: xform); cur = nxt
                    } else { idx += 1 }
                case "l":
                    if let dx = nextNum(), let dy = nextNum() {
                        let nxt = CGPoint(x: cur.x + dx, y: cur.y + dy); addSeg(cur, nxt, xform: xform); cur = nxt
                    } else { idx += 1 }
                case "H":
                    if let x = nextNum() {
                        let nxt = CGPoint(x: x, y: cur.y); addSeg(cur, nxt, xform: xform); cur = nxt
                    } else { idx += 1 }
                case "h":
                    if let dx = nextNum() {
                        let nxt = CGPoint(x: cur.x + dx, y: cur.y); addSeg(cur, nxt, xform: xform); cur = nxt
                    } else { idx += 1 }
                case "V":
                    if let y = nextNum() {
                        let nxt = CGPoint(x: cur.x, y: y); addSeg(cur, nxt, xform: xform); cur = nxt
                    } else { idx += 1 }
                case "v":
                    if let dy = nextNum() {
                        let nxt = CGPoint(x: cur.x, y: cur.y + dy); addSeg(cur, nxt, xform: xform); cur = nxt
                    } else { idx += 1 }
                default:
                    idx += 1
                }
            }
        }
        
        private func parseTransform(_ str: String?) -> CGAffineTransform {
            guard let s = str else { return .identity }
            var xf = CGAffineTransform.identity
            if let r = s.range(of: #"translate\(([^)]+)\)"#, options: .regularExpression) {
                let inner = s[r].replacingOccurrences(of: "translate(", with: "").replacingOccurrences(of: ")", with: "")
                let parts = inner.replacingOccurrences(of: ",", with: " ").split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
                if parts.count >= 1 {
                    xf = xf.translatedBy(x: parts[0], y: parts.count >= 2 ? parts[1] : 0)
                }
            }
            if let r = s.range(of: #"scale\(([^)]+)\)"#, options: .regularExpression) {
                let inner = s[r].replacingOccurrences(of: "scale(", with: "").replacingOccurrences(of: ")", with: "")
                let parts = inner.replacingOccurrences(of: ",", with: " ").split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
                if parts.count >= 1 {
                    xf = xf.scaledBy(x: parts[0], y: parts.count >= 2 ? parts[1] : parts[0])
                }
            }
            return xf
        }
    }
    
    private static func importSVG(from url: URL, name: String) throws -> ImportedPlan {
        let data = try Data(contentsOf: url)
        let content = String(data: data, encoding: .utf8) ?? ""
        
        let collector = SVGXMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        
        let vbW = Float(collector.viewBox.width)
        let vbH = Float(collector.viewBox.height)
        
        // Render SVG into high-contrast blueprint image
        let renderW: CGFloat = 1600.0
        let renderH = max(renderW * CGFloat(vbH / max(vbW, 1.0)), 160.0)
        let renderSize = CGSize(width: renderW, height: renderH)
        let scaleX = Float(renderW) / max(vbW, 1.0)
        let scaleY = Float(renderH) / max(vbH, 1.0)
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderedImage = UIGraphicsImageRenderer(size: renderSize, format: format).image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1.0).cgColor)
            ctx.fill(CGRect(origin: .zero, size: renderSize))
            ctx.setStrokeColor(UIColor(red: 0.1, green: 0.12, blue: 0.2, alpha: 1.0).cgColor)
            ctx.setLineWidth(3.0)
            for line in collector.rawLines {
                ctx.move(to: CGPoint(x: CGFloat(line.startX * scaleX), y: CGFloat(line.startZ * scaleY)))
                ctx.addLine(to: CGPoint(x: CGFloat(line.endX * scaleX), y: CGFloat(line.endZ * scaleY)))
            }
            ctx.strokePath()
        }
        
        let pxLines = collector.rawLines.map {
            PlanLine(startX: $0.startX * scaleX, startZ: $0.startZ * scaleY, endX: $0.endX * scaleX, endZ: $0.endZ * scaleY)
        }
        let cleanedPx = cleanVectorSegmentsPx(pxLines, canvasW: Float(renderW), canvasH: Float(renderH))
        let (_, ocrMpp) = PlanImageVectorizer.detectScaleFromRenderedImage(
            image: renderedImage,
            pixelLines: cleanedPx,
            width: Int(renderW),
            height: Int(renderH)
        )
        let (mpp, heuristic) = computeMetricScale(ocrMpp: ocrMpp, linesPx: cleanedPx, canvasW: Float(renderW))
        let metricLines = centerAndScaleLines(cleanedPx, canvasW: Float(renderW), canvasH: Float(renderH), mpp: mpp)
        
        return ImportedPlan(
            name: name,
            fileType: .svg,
            originalWidthMeters: Float(renderW) * mpp,
            originalDepthMeters: Float(renderH) * mpp,
            renderedImageData: renderedImage.pngData(),
            vectorLines: metricLines,
            isHeuristicScale: heuristic,
            sourceText: content
        )
    }
    
    // MARK: - Vector Cleanup & Metric Scale Helpers
    
    private static func cleanVectorSegmentsPx(_ segs: [PlanLine], canvasW: Float, canvasH: Float) -> [PlanLine] {
        var merged: [PlanLine] = []
        for s in segs.sorted(by: { $0.length > $1.length }) {
            // Skip full-sheet border frames
            let spanW = abs(s.startX - s.endX)
            let spanH = abs(s.startZ - s.endZ)
            let isBorderH = (min(s.startZ, s.endZ) < 18 || max(s.startZ, s.endZ) > canvasH - 18) && spanW > canvasW * 0.90
            let isBorderV = (min(s.startX, s.endX) < 18 || max(s.startX, s.endX) > canvasW - 18) && spanH > canvasH * 0.90
            if isBorderH || isBorderV { continue }
            
            let sDir = SIMD2<Float>(cos(s.angle), sin(s.angle))
            let sNorm = SIMD2<Float>(-sDir.y, sDir.x)
            let sMid = SIMD2<Float>((s.startX + s.endX) * 0.5, (s.startZ + s.endZ) * 0.5)
            
            var didMerge = false
            for i in 0..<merged.count {
                let m = merged[i]
                var dAng = abs(s.angle - m.angle)
                if dAng > .pi * 0.5 { dAng = abs(dAng - .pi) }
                guard dAng < (5.0 * .pi / 180.0) else { continue }
                
                let mMid = SIMD2<Float>((m.startX + m.endX) * 0.5, (m.startZ + m.endZ) * 0.5)
                let perp = abs(simd_dot(sMid - mMid, sNorm))
                guard perp <= 10.0 else { continue }
                
                let mDir = SIMD2<Float>(cos(m.angle), sin(m.angle))
                let t1 = simd_dot(SIMD2<Float>(s.startX, s.startZ) - mMid, mDir)
                let t2 = simd_dot(SIMD2<Float>(s.endX, s.endZ) - mMid, mDir)
                let lo = min(t1, t2)
                let hi = max(t1, t2)
                let mHalf = m.length * 0.5
                if max(-mHalf, lo) <= min(mHalf, hi) + 6.0 {
                    let newLo = min(-mHalf, lo)
                    let newHi = max(mHalf, hi)
                    let p1 = mMid + mDir * newLo
                    let p2 = mMid + mDir * newHi
                    merged[i] = PlanLine(startX: p1.x, startZ: p1.y, endX: p2.x, endZ: p2.y)
                    didMerge = true
                    break
                }
            }
            if !didMerge {
                merged.append(s)
            }
        }
        return merged.filter { $0.length >= 24.0 }
    }
    
    private static func computeMetricScale(ocrMpp: Float?, linesPx: [PlanLine], canvasW: Float) -> (mpp: Float, isHeuristic: Bool) {
        if let m = ocrMpp, m > 0.001 && m < 0.14 {
            return (m, false)
        }
        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        for l in linesPx {
            minX = min(minX, l.startX, l.endX)
            maxX = max(maxX, l.startX, l.endX)
        }
        let span = minX < maxX ? max(maxX - minX, 120.0) : canvasW
        return (12.0 / span, true)
    }
    
    private static func centerAndScaleLines(_ pxLines: [PlanLine], canvasW: Float, canvasH: Float, mpp: Float) -> [PlanLine] {
        let midX = canvasW * 0.5
        let midZ = canvasH * 0.5
        return pxLines.compactMap { l in
            let ml = PlanLine(
                startX: (l.startX - midX) * mpp,
                startZ: (l.startZ - midZ) * mpp,
                endX: (l.endX - midX) * mpp,
                endZ: (l.endZ - midZ) * mpp
            )
            return ml.length >= 0.25 ? ml : nil
        }
    }
    
    // MARK: - JSON Importer
    
    private static func importJSON(from url: URL, name: String) throws -> ImportedPlan {
        let data = try Data(contentsOf: url)
        if let room = try? JSONDecoder().decode(MaquetteRoom.self, from: data) {
            let lines = room.walls.map { wall -> PlanLine in
                let s = wall.startPoint2D
                let e = wall.endPoint2D
                return PlanLine(startX: Float(s.x), startZ: Float(s.y), endX: Float(e.x), endZ: Float(e.y))
            }
            let b = room.boundingBox
            return ImportedPlan(
                name: room.name,
                fileType: .json,
                originalWidthMeters: max(b.max.x - b.min.x, 6.0),
                originalDepthMeters: max(b.max.z - b.min.z, 6.0),
                renderedImageData: nil,
                vectorLines: lines,
                detectedDoors: room.doors,
                detectedWindows: room.windows,
                detectedOpenings: room.openings,
                isHeuristicScale: false
            )
        }
        throw NSError(domain: "PlanImporter", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON room format."])
    }
}
