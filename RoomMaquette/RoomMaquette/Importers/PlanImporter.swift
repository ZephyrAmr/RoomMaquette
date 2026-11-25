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
                vectorLines: lines
            )
        default:
            // Fallback: Attempt image load or raw import
            if let imagePlan = try? importRasterImage(from: url, name: planName) {
                return imagePlan
            }
            throw NSError(domain: "PlanImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported plan format (.\(ext)). Use PDF, PNG, JPG, DXF, or SVG."])
        }
    }
    
    /// Converts an ImportedPlan directly into a playable MaquetteRoom with synthesized walls & boundaries
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
            doors: [],
            windows: [],
            objects: [],
            importedPlan: plan
        )
    }
    
    /// Synthesizes 3D WallSurfaces matching the plan's metric vectorLines
    public static func synthesizeWalls(from plan: ImportedPlan, ceilingH: Float = 2.60) -> [WallSurface] {
        var walls: [WallSurface] = []
        for line in plan.vectorLines {
            let wallLen = line.length
            guard wallLen >= 0.4 else { continue }
            let midX = (line.startX + line.endX) / 2.0
            let midZ = (line.startZ + line.endZ) / 2.0
            let ang = line.angle
            
            let cosA = cos(ang)
            let sinA = sin(ang)
            let rotMat = simd_float4x4(
                SIMD4<Float>(cosA, 0, sinA, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-sinA, 0, cosA, 0),
                SIMD4<Float>(midX, ceilingH / 2.0, midZ, 1)
            )
            walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(wallLen, ceilingH, 0.15), transform: rotMat))
        }
        
        // If plan has no lines, synthesize perimeter box
        if walls.isEmpty {
            let hw = plan.originalWidthMeters / 2.0
            let hd = plan.originalDepthMeters / 2.0
            let perimLines = [
                PlanLine(startX: -hw, startZ: -hd, endX: hw, endZ: -hd),
                PlanLine(startX: hw, startZ: -hd, endX: hw, endZ: hd),
                PlanLine(startX: hw, startZ: hd, endX: -hw, endZ: hd),
                PlanLine(startX: -hw, startZ: hd, endX: -hw, endZ: -hd)
            ]
            for l in perimLines {
                let mx = (l.startX + l.endX)/2.0
                let mz = (l.startZ + l.endZ)/2.0
                let ang = l.angle
                let rotMat = simd_float4x4(
                    SIMD4<Float>(cos(ang), 0, sin(ang), 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(-sin(ang), 0, cos(ang), 0),
                    SIMD4<Float>(mx, ceilingH / 2.0, mz, 1)
                )
                walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(l.length, ceilingH, 0.15), transform: rotMat))
            }
        }
        return walls
    }
    
    /// Uniformly rescales an ImportedPlan's physical metric dimensions and vector lines
    public static func rescaledPlan(_ plan: ImportedPlan, by factor: Float) -> ImportedPlan {
        let clampedFactor = max(0.1, min(factor, 10.0))
        var copy = plan
        copy.originalWidthMeters *= clampedFactor
        copy.originalDepthMeters *= clampedFactor
        copy.vectorLines = plan.vectorLines.map { line in
            PlanLine(
                startX: line.startX * clampedFactor,
                startZ: line.startZ * clampedFactor,
                endX: line.endX * clampedFactor,
                endZ: line.endZ * clampedFactor
            )
        }
        return copy
    }
    
    // MARK: - PDF Blueprint Importer with Vision Vectorization
    
    private static func importPDF(from url: URL, name: String) throws -> ImportedPlan {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            throw NSError(domain: "PlanImporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not open PDF blueprint document."])
        }
        
        let bounds = page.bounds(for: .mediaBox)
        let width = bounds.width
        let height = bounds.height
        
        // Render 2048px high-resolution raster image of the blueprint page
        let targetWidth: CGFloat = 2048.0
        let targetHeight = targetWidth * (height / max(width, 1.0))
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        
        UIGraphicsBeginImageContextWithOptions(targetSize, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            throw NSError(domain: "PlanImporter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Graphics context failure."])
        }
        
        // Fill white architectural background
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: targetSize))
        
        // Draw PDF Page scaled
        ctx.saveGState()
        ctx.translateBy(x: 0, y: targetHeight)
        ctx.scaleBy(x: targetWidth / width, y: -targetHeight / height)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        
        let rendered = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        guard let image = rendered, let pngData = image.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "PlanImporter", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to rasterize PDF page."])
        }
        
        // Run AI / Vision line extraction & scale detection
        let vectorized = PlanImageVectorizer.vectorize(image: image)
        
        return ImportedPlan(
            name: name,
            fileType: .pdf,
            originalWidthMeters: vectorized.originalWidthMeters,
            originalDepthMeters: vectorized.originalDepthMeters,
            renderedImageData: pngData,
            vectorLines: vectorized.vectorLines
        )
    }
    
    // MARK: - Raster Image Importer with Vision Vectorization (PNG, JPG, HEIC)
    
    private static func importRasterImage(from url: URL, name: String) throws -> ImportedPlan {
        let data = try Data(contentsOf: url)
        guard let image = UIImage(data: data) else {
            throw NSError(domain: "PlanImporter", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid image file."])
        }
        
        // Vectorize image: extract walls and detect metric scale with Vision OCR
        let vectorized = PlanImageVectorizer.vectorize(image: image)
        let compressed = image.jpegData(compressionQuality: 0.85) ?? data
        
        return ImportedPlan(
            name: name,
            fileType: .image,
            originalWidthMeters: vectorized.originalWidthMeters,
            originalDepthMeters: vectorized.originalDepthMeters,
            renderedImageData: compressed,
            vectorLines: vectorized.vectorLines
        )
    }
    
    // MARK: - CAD DXF Importer
    
    private static func importDXF(from url: URL, name: String) throws -> ImportedPlan {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        
        var extractedLines: [PlanLine] = []
        var i = 0
        
        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        var minZ: Float = .greatestFiniteMagnitude
        var maxZ: Float = -.greatestFiniteMagnitude
        
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line == "LINE" {
                var x1: Float?
                var y1: Float?
                var x2: Float?
                var y2: Float?
                
                while i < lines.count - 1 {
                    i += 1
                    let code = lines[i].trimmingCharacters(in: .whitespaces)
                    if code == "0" {
                        i -= 1
                        break
                    }
                    if i < lines.count - 1 {
                        i += 1
                        let val = Float(lines[i].trimmingCharacters(in: .whitespaces))
                        if code == "10" { x1 = val }
                        else if code == "20" { y1 = val }
                        else if code == "11" { x2 = val }
                        else if code == "21" { y2 = val }
                    }
                }
                
                if let x1 = x1, let y1 = y1, let x2 = x2, let y2 = y2 {
                    extractedLines.append(PlanLine(startX: x1, startZ: y1, endX: x2, endZ: y2))
                    minX = min(minX, x1, x2)
                    maxX = max(maxX, x1, x2)
                    minZ = min(minZ, y1, y2)
                    maxZ = max(maxZ, y1, y2)
                }
            }
            i += 1
        }
        
        if extractedLines.isEmpty {
            minX = -5; maxX = 5; minZ = -5; maxZ = 5
        }
        
        let spanX = max(maxX - minX, 1.0)
        let spanZ = max(maxZ - minZ, 1.0)
        
        // Render CAD blueprint image from extracted lines
        let imgSize = CGSize(width: 1600, height: 1600 * CGFloat(spanZ / spanX))
        UIGraphicsBeginImageContextWithOptions(imgSize, true, 1.0)
        let ctx = UIGraphicsGetCurrentContext()!
        
        ctx.setFillColor(UIColor(red: 0.05, green: 0.12, blue: 0.28, alpha: 1.0).cgColor)
        ctx.fill(CGRect(origin: .zero, size: imgSize))
        
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2.0)
        
        for pl in extractedLines {
            let px1 = CGFloat((pl.startX - minX) / spanX) * (imgSize.width - 80) + 40
            let pz1 = CGFloat((pl.startZ - minZ) / spanZ) * (imgSize.height - 80) + 40
            let px2 = CGFloat((pl.endX - minX) / spanX) * (imgSize.width - 80) + 40
            let pz2 = CGFloat((pl.endZ - minZ) / spanZ) * (imgSize.height - 80) + 40
            
            ctx.move(to: CGPoint(x: px1, y: pz1))
            ctx.addLine(to: CGPoint(x: px2, y: pz2))
        }
        ctx.strokePath()
        
        let cadImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        let imgData = cadImage?.pngData()
        
        return ImportedPlan(
            name: name,
            fileType: .dxf,
            originalWidthMeters: spanX,
            originalDepthMeters: spanZ,
            renderedImageData: imgData,
            vectorLines: extractedLines,
            sourceText: content
        )
    }
    
    // MARK: - SVG Vector Importer with XML Parsing & Visual Rendering
    
    private static func importSVG(from url: URL, name: String) throws -> ImportedPlan {
        let content = try String(contentsOf: url, encoding: .utf8)
        var parsedLines: [PlanLine] = []
        
        // 1. Detect SVG viewBox or width/height
        var vbW: Float = 1000.0
        var vbH: Float = 1000.0
        if let vbMatch = content.range(of: #"viewBox\s*=\s*\"([^\"]+)\""#, options: .regularExpression) {
            let vbStr = content[vbMatch]
                .replacingOccurrences(of: "viewBox=", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces)
            let parts = vbStr.split(separator: " ").compactMap { Float($0) }
            if parts.count >= 4 {
                vbW = max(parts[2], 10.0)
                vbH = max(parts[3], 10.0)
            }
        }
        
        // 2. Parse <line> elements: x1, y1, x2, y2
        let linePattern = #"<line\s+[^>]*x1\s*=\s*\"([0-9.]+)\"[^>]*y1\s*=\s*\"([0-9.]+)\"[^>]*x2\s*=\s*\"([0-9.]+)\"[^>]*y2\s*=\s*\"([0-9.]+)\""#
        if let regex = try? NSRegularExpression(pattern: linePattern, options: .caseInsensitive) {
            let nsContent = content as NSString
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            for m in matches {
                if m.numberOfRanges >= 5,
                   let x1 = Float(nsContent.substring(with: m.range(at: 1))),
                   let y1 = Float(nsContent.substring(with: m.range(at: 2))),
                   let x2 = Float(nsContent.substring(with: m.range(at: 3))),
                   let y2 = Float(nsContent.substring(with: m.range(at: 4))) {
                    parsedLines.append(PlanLine(startX: x1, startZ: y1, endX: x2, endZ: y2))
                }
            }
        }
        
        // 3. Parse <rect> elements: x, y, width, height
        let rectPattern = #"<rect\s+[^>]*x\s*=\s*\"([0-9.]+)\"[^>]*y\s*=\s*\"([0-9.]+)\"[^>]*width\s*=\s*\"([0-9.]+)\"[^>]*height\s*=\s*\"([0-9.]+)\""#
        if let regex = try? NSRegularExpression(pattern: rectPattern, options: .caseInsensitive) {
            let nsContent = content as NSString
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            for m in matches {
                if m.numberOfRanges >= 5,
                   let rx = Float(nsContent.substring(with: m.range(at: 1))),
                   let ry = Float(nsContent.substring(with: m.range(at: 2))),
                   let rw = Float(nsContent.substring(with: m.range(at: 3))),
                   let rh = Float(nsContent.substring(with: m.range(at: 4))) {
                    // Skip canvas-sized background rects
                    if rw < vbW * 0.96 || rh < vbH * 0.96 {
                        parsedLines.append(PlanLine(startX: rx, startZ: ry, endX: rx + rw, endZ: ry))
                        parsedLines.append(PlanLine(startX: rx + rw, startZ: ry, endX: rx + rw, endZ: ry + rh))
                        parsedLines.append(PlanLine(startX: rx + rw, startZ: ry + rh, endX: rx, endZ: ry + rh))
                        parsedLines.append(PlanLine(startX: rx, startZ: ry + rh, endX: rx, endZ: ry))
                    }
                }
            }
        }
        
        // 4. Render SVG into a high-contrast architectural blueprint image for underlay
        let renderW: CGFloat = 1600.0
        let renderH = renderW * CGFloat(vbH / max(vbW, 1.0))
        let renderSize = CGSize(width: renderW, height: renderH)
        
        UIGraphicsBeginImageContextWithOptions(renderSize, true, 1.0)
        let ctx = UIGraphicsGetCurrentContext()!
        ctx.setFillColor(UIColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1.0).cgColor)
        ctx.fill(CGRect(origin: .zero, size: renderSize))
        
        let scaleX = renderW / CGFloat(vbW)
        let scaleY = renderH / CGFloat(vbH)
        
        ctx.setStrokeColor(UIColor(red: 0.1, green: 0.12, blue: 0.2, alpha: 1.0).cgColor)
        ctx.setLineWidth(3.0)
        for line in parsedLines {
            ctx.move(to: CGPoint(x: CGFloat(line.startX) * scaleX, y: CGFloat(line.startZ) * scaleY))
            ctx.addLine(to: CGPoint(x: CGFloat(line.endX) * scaleX, y: CGFloat(line.endZ) * scaleY))
        }
        ctx.strokePath()
        
        let renderedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        let renderedPngData = renderedImage?.pngData()
        
        // 5. Convert parsed lines to centered metric space (~14m span)
        let estWidthMeters: Float = 14.0
        let mpp = estWidthMeters / vbW
        let estDepthMeters = vbH * mpp
        let midX = vbW / 2.0
        let midZ = vbH / 2.0
        
        var metricLines: [PlanLine] = []
        for l in parsedLines {
            let x1 = (l.startX - midX) * mpp
            let z1 = (l.startZ - midZ) * mpp
            let x2 = (l.endX - midX) * mpp
            let z2 = (l.endZ - midZ) * mpp
            let mLine = PlanLine(startX: x1, startZ: z1, endX: x2, endZ: z2)
            if mLine.length > 0.3 {
                metricLines.append(mLine)
            }
        }
        
        // If parsed lines were sparse (e.g. paths), vectorize the rendered bitmap
        if metricLines.count < 4, let img = renderedImage {
            let vectorized = PlanImageVectorizer.vectorize(image: img)
            metricLines = vectorized.vectorLines
        }
        
        return ImportedPlan(
            name: name,
            fileType: .svg,
            originalWidthMeters: estWidthMeters,
            originalDepthMeters: estDepthMeters,
            renderedImageData: renderedPngData,
            vectorLines: metricLines,
            sourceText: content
        )
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
                vectorLines: lines
            )
        }
        throw NSError(domain: "PlanImporter", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON room format."])
    }
}
