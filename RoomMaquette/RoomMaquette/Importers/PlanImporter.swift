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
        default:
            // Fallback: Attempt image load or raw import
            if let imagePlan = try? importRasterImage(from: url, name: planName) {
                return imagePlan
            }
            throw NSError(domain: "PlanImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported plan format (.\(ext)). Use PDF, PNG, JPG, DXF, or SVG."])
        }
    }
    
    // MARK: - PDF Blueprint Importer
    
    private static func importPDF(from url: URL, name: String) throws -> ImportedPlan {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            throw NSError(domain: "PlanImporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not open PDF blueprint document."])
        }
        
        let bounds = page.bounds(for: .mediaBox)
        let width = bounds.width
        let height = bounds.height
        
        // Render 2000px high-resolution raster image of the blueprint page
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
        
        // Assume default architectural sheet scale (e.g. 15m wide plan)
        let estWidthMeters: Float = 16.0
        let estDepthMeters: Float = estWidthMeters * Float(height / max(width, 1.0))
        
        return ImportedPlan(
            name: name,
            fileType: .pdf,
            originalWidthMeters: estWidthMeters,
            originalDepthMeters: estDepthMeters,
            renderedImageData: pngData,
            vectorLines: []
        )
    }
    
    // MARK: - Raster Image Importer (PNG, JPG, HEIC)
    
    private static func importRasterImage(from url: URL, name: String) throws -> ImportedPlan {
        let data = try Data(contentsOf: url)
        guard let image = UIImage(data: data) else {
            throw NSError(domain: "PlanImporter", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid image file."])
        }
        
        let w = image.size.width
        let h = image.size.height
        let estWidthMeters: Float = 14.0
        let estDepthMeters: Float = estWidthMeters * Float(h / max(w, 1.0))
        
        let compressed = image.jpegData(compressionQuality: 0.85) ?? data
        
        return ImportedPlan(
            name: name,
            fileType: .image,
            originalWidthMeters: estWidthMeters,
            originalDepthMeters: estDepthMeters,
            renderedImageData: compressed,
            vectorLines: []
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
                
                // Read following group codes
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
        
        // Render crisp CAD blueprint image from extracted lines
        let imgSize = CGSize(width: 1600, height: 1600 * CGFloat(spanZ / spanX))
        UIGraphicsBeginImageContextWithOptions(imgSize, true, 1.0)
        let ctx = UIGraphicsGetCurrentContext()!
        
        // Deep blueprint background
        ctx.setFillColor(UIColor(red: 0.05, green: 0.12, blue: 0.28, alpha: 1.0).cgColor)
        ctx.fill(CGRect(origin: .zero, size: imgSize))
        
        // White CAD lines
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
    
    // MARK: - SVG Vector Importer
    
    private static func importSVG(from url: URL, name: String) throws -> ImportedPlan {
        let content = try String(contentsOf: url, encoding: .utf8)
        let estWidthMeters: Float = 12.0
        let estDepthMeters: Float = 12.0
        
        return ImportedPlan(
            name: name,
            fileType: .svg,
            originalWidthMeters: estWidthMeters,
            originalDepthMeters: estDepthMeters,
            renderedImageData: nil,
            vectorLines: [],
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
                originalWidthMeters: b.max.x - b.min.x,
                originalDepthMeters: b.max.z - b.min.z,
                renderedImageData: nil,
                vectorLines: lines
            )
        }
        throw NSError(domain: "PlanImporter", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON room format."])
    }
}
