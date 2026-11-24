import UIKit
import Vision
import CoreGraphics
import simd

public struct VectorizedPlanResult {
    public var vectorLines: [PlanLine]
    public var walls: [WallSurface]
    public var originalWidthMeters: Float
    public var originalDepthMeters: Float
    public var recognizedDimensions: [String]
    public var detectedScaleMetersPerPixel: Float
}

public class PlanImageVectorizer {
    
    /// Analyzes an imported floor plan image (PNG, JPG, HEIC, or rasterized PDF/SVG),
    /// normalizes EXIF orientation, extracts geometric wall lines (horizontal, vertical & diagonal),
    /// recognizes dimension text via Vision OCR, computes metric scale, and synthesizes WallSurfaces.
    public static func vectorize(image: UIImage) -> VectorizedPlanResult {
        let targetWidth: Int = 1024
        let aspect = image.size.height / max(image.size.width, 1.0)
        let targetHeight: Int = max(Int(CGFloat(targetWidth) * aspect), 100)
        
        // 1. Render normalized-orientation image & extract grayscale luminance pixels
        guard let (normalizedCG, grayscalePixels) = extractNormalizedGrayscalePixels(
            image: image,
            width: targetWidth,
            height: targetHeight
        ) else {
            return fallbackResult(widthMeters: 14.0, depthMeters: 14.0 * Float(aspect))
        }
        
        // 2. Adaptive background polarity & contrast threshold
        let (isLightBackground, wallThreshold) = computeAdaptiveThreshold(
            pixels: grayscalePixels,
            width: targetWidth,
            height: targetHeight
        )
        
        // 3. Extract horizontal, vertical, and diagonal architectural wall segments
        let rawSegments = extractWallSegments(
            pixels: grayscalePixels,
            width: targetWidth,
            height: targetHeight,
            isLightBackground: isLightBackground,
            threshold: wallThreshold
        )
        
        // 4. Run Vision OCR text recognition to detect metric scale callouts
        let (recognizedDims, ocrScaleMpp) = detectDimensionsAndScaleWithVision(
            cgImage: normalizedCG,
            detectedSegments: rawSegments,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        
        // 5. Determine overall scale (meters per pixel)
        let metersPerPixel: Float
        if let ocrScale = ocrScaleMpp, ocrScale > 0.001 && ocrScale < 0.15 {
            metersPerPixel = ocrScale
        } else {
            var minPxX: Float = .greatestFiniteMagnitude
            var maxPxX: Float = -.greatestFiniteMagnitude
            for seg in rawSegments {
                minPxX = min(minPxX, seg.startX, seg.endX)
                maxPxX = max(maxPxX, seg.startX, seg.endX)
            }
            let pixelSpan = max(maxPxX - minPxX, 120.0)
            metersPerPixel = 12.0 / pixelSpan
        }
        
        // 6. Center coordinates and convert pixel segments to metric space (meters)
        let midPxX = Float(targetWidth) * 0.5
        let midPxY = Float(targetHeight) * 0.5
        
        var planLines: [PlanLine] = []
        var walls: [WallSurface] = []
        let ceilingH: Float = 2.60
        
        for seg in rawSegments {
            let x1 = (seg.startX - midPxX) * metersPerPixel
            let z1 = (seg.startZ - midPxY) * metersPerPixel
            let x2 = (seg.endX - midPxX) * metersPerPixel
            let z2 = (seg.endZ - midPxY) * metersPerPixel
            
            let line = PlanLine(startX: x1, startZ: z1, endX: x2, endZ: z2)
            guard line.length > 0.45 else { continue }
            
            planLines.append(line)
            
            let wallLen = line.length
            let angle = line.angle
            let midX = (x1 + x2) * 0.5
            let midZ = (z1 + z2) * 0.5
            
            let cosA = cos(angle)
            let sinA = sin(angle)
            let rotMat = simd_float4x4(
                SIMD4<Float>(cosA, 0, sinA, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-sinA, 0, cosA, 0),
                SIMD4<Float>(midX, ceilingH * 0.5, midZ, 1)
            )
            
            walls.append(WallSurface(
                id: UUID(),
                dimensions: SIMD3<Float>(wallLen, ceilingH, 0.15),
                transform: rotMat
            ))
        }
        
        let totalWidthMeters = Float(targetWidth) * metersPerPixel
        let totalDepthMeters = Float(targetHeight) * metersPerPixel
        
        if planLines.isEmpty {
            return fallbackResult(widthMeters: totalWidthMeters, depthMeters: totalDepthMeters)
        }
        
        return VectorizedPlanResult(
            vectorLines: planLines,
            walls: walls,
            originalWidthMeters: totalWidthMeters,
            originalDepthMeters: totalDepthMeters,
            recognizedDimensions: recognizedDims,
            detectedScaleMetersPerPixel: metersPerPixel
        )
    }
    
    // MARK: - Orientation-Normalized Grayscale Pixel Extraction
    
    private static func extractNormalizedGrayscalePixels(image: UIImage, width: Int, height: Int) -> (CGImage, [UInt8])? {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let normalizedUI = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cgImage = normalizedUI.cgImage else { return nil }
        
        var pixels = [UInt8](repeating: 255, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (cgImage, pixels)
    }
    
    // MARK: - Adaptive Polarity & Contrast Threshold
    
    private static func computeAdaptiveThreshold(pixels: [UInt8], width: Int, height: Int) -> (isLight: Bool, threshold: UInt8) {
        var borderSum: Int = 0
        var borderCount: Int = 0
        let border = 8
        for y in [border, height - border - 1] where y >= 0 && y < height {
            for x in stride(from: border, to: width - border, by: 8) {
                borderSum += Int(pixels[y * width + x])
                borderCount += 1
            }
        }
        let bgAvg = borderCount > 0 ? borderSum / borderCount : 255
        let isLight = bgAvg > 128
        
        // Sample interior luminance spread to pick adaptive stroke cutoff
        var minLum = 255
        var maxLum = 0
        for y in stride(from: 0, to: height, by: 6) {
            for x in stride(from: 0, to: width, by: 6) {
                let v = Int(pixels[y * width + x])
                minLum = min(minLum, v)
                maxLum = max(maxLum, v)
            }
        }
        let mid = (minLum + maxLum) / 2
        if isLight {
            let cutoff = UInt8(max(70, min(160, (bgAvg + mid) / 2)))
            return (true, cutoff)
        } else {
            let cutoff = UInt8(min(200, max(110, (bgAvg + mid) / 2)))
            return (false, cutoff)
        }
    }
    
    // MARK: - Multi-Angle Wall Segment Extraction
    
    private static func extractWallSegments(
        pixels: [UInt8],
        width: Int,
        height: Int,
        isLightBackground: Bool,
        threshold: UInt8
    ) -> [PlanLine] {
        var segments: [PlanLine] = []
        
        @inline(__always)
        func isWallPixel(_ val: UInt8) -> Bool {
            isLightBackground ? (val < threshold) : (val > threshold)
        }
        
        let minLineLength = 38
        let maxThickness = 22
        let borderMargin = 16
        
        func checkUniformThickness(x: Int, y: Int, horizontal: Bool) -> Bool {
            var thickCount = 0
            if horizontal {
                for cy in max(0, y - maxThickness)...min(height - 1, y + maxThickness) {
                    if isWallPixel(pixels[cy * width + x]) { thickCount += 1 }
                }
            } else {
                for cx in max(0, x - maxThickness)...min(width - 1, x + maxThickness) {
                    if isWallPixel(pixels[y * width + cx]) { thickCount += 1 }
                }
            }
            return thickCount >= 2 && thickCount <= maxThickness
        }
        
        // 1. Horizontal scan (step 3px) with 3-point stroke thickness verification
        for y in stride(from: borderMargin, to: height - borderMargin, by: 3) {
            var startX: Int? = nil
            for x in borderMargin..<(width - borderMargin) {
                if isWallPixel(pixels[y * width + x]) {
                    if startX == nil { startX = x }
                } else if let sx = startX {
                    let len = x - sx
                    // Reject page-spanning outer sheet frames (> 92% width)
                    if len >= minLineLength && len < Int(Float(width) * 0.92) {
                        let q1 = sx + len / 4
                        let q2 = sx + len / 2
                        let q3 = sx + (len * 3) / 4
                        let ok = checkUniformThickness(x: q1, y: y, horizontal: true) &&
                                 checkUniformThickness(x: q2, y: y, horizontal: true) &&
                                 checkUniformThickness(x: q3, y: y, horizontal: true)
                        if ok {
                            segments.append(PlanLine(startX: Float(sx), startZ: Float(y), endX: Float(x), endZ: Float(y)))
                        }
                    }
                    startX = nil
                }
            }
        }
        
        // 2. Vertical scan (step 3px) with 3-point stroke thickness verification
        for x in stride(from: borderMargin, to: width - borderMargin, by: 3) {
            var startY: Int? = nil
            for y in borderMargin..<(height - borderMargin) {
                if isWallPixel(pixels[y * width + x]) {
                    if startY == nil { startY = y }
                } else if let sy = startY {
                    let len = y - sy
                    if len >= minLineLength && len < Int(Float(height) * 0.92) {
                        let q1 = sy + len / 4
                        let q2 = sy + len / 2
                        let q3 = sy + (len * 3) / 4
                        let ok = checkUniformThickness(x: x, y: q1, horizontal: false) &&
                                 checkUniformThickness(x: x, y: q2, horizontal: false) &&
                                 checkUniformThickness(x: x, y: q3, horizontal: false)
                        if ok {
                            segments.append(PlanLine(startX: Float(x), startZ: Float(sy), endX: Float(x), endZ: Float(y)))
                        }
                    }
                    startY = nil
                }
            }
        }
        
        // 3. Diagonal (45 deg & 135 deg) scan for angled architectural walls
        let minDiagSteps = 34
        for offset in stride(from: -(height - 2 * borderMargin), through: (width - 2 * borderMargin), by: 5) {
            var diagStart: (Int, Int)? = nil
            var steps = 0
            for y in borderMargin..<(height - borderMargin) {
                let x = y + offset
                guard x >= borderMargin && x < width - borderMargin else {
                    if let ds = diagStart, steps >= minDiagSteps {
                        segments.append(PlanLine(startX: Float(ds.0), startZ: Float(ds.1), endX: Float(ds.0 + steps), endZ: Float(ds.1 + steps)))
                    }
                    diagStart = nil
                    steps = 0
                    continue
                }
                if isWallPixel(pixels[y * width + x]) {
                    if diagStart == nil { diagStart = (x, y); steps = 1 }
                    else { steps += 1 }
                } else {
                    if let ds = diagStart, steps >= minDiagSteps {
                        segments.append(PlanLine(startX: Float(ds.0), startZ: Float(ds.1), endX: Float(x), endZ: Float(y)))
                    }
                    diagStart = nil
                    steps = 0
                }
            }
        }
        
        // 4. Anti-diagonal (135 deg) scan for angled architectural walls
        for offset in stride(from: borderMargin * 2, through: width + height - borderMargin * 2, by: 5) {
            var diagStart: (Int, Int)? = nil
            var steps = 0
            for y in borderMargin..<(height - borderMargin) {
                let x = offset - y
                guard x >= borderMargin && x < width - borderMargin else {
                    if let ds = diagStart, steps >= minDiagSteps {
                        segments.append(PlanLine(startX: Float(ds.0), startZ: Float(ds.1), endX: Float(ds.0 - steps), endZ: Float(ds.1 + steps)))
                    }
                    diagStart = nil
                    steps = 0
                    continue
                }
                if isWallPixel(pixels[y * width + x]) {
                    if diagStart == nil { diagStart = (x, y); steps = 1 }
                    else { steps += 1 }
                } else {
                    if let ds = diagStart, steps >= minDiagSteps {
                        segments.append(PlanLine(startX: Float(ds.0), startZ: Float(ds.1), endX: Float(x), endZ: Float(y)))
                    }
                    diagStart = nil
                    steps = 0
                }
            }
        }
        
        return mergeCollinearSegments(segments: segments)
    }
    
    private static func mergeCollinearSegments(segments: [PlanLine]) -> [PlanLine] {
        var merged: [PlanLine] = []
        // Merge both collinear segments AND parallel CAD hollow-wall double-lines within 13px
        let perpTolerance: Float = 13.0
        
        for seg in segments {
            let ang = seg.angle
            let tanVec = SIMD2<Float>(cos(ang), sin(ang))
            let normVec = SIMD2<Float>(-tanVec.y, tanVec.x)
            let segMid = SIMD2<Float>((seg.startX + seg.endX) * 0.5, (seg.startZ + seg.endZ) * 0.5)
            
            var didMerge = false
            for i in 0..<merged.count {
                let m = merged[i]
                let mAng = m.angle
                var dAng = abs(ang - mAng)
                if dAng > .pi * 0.5 { dAng = abs(dAng - .pi) }
                guard dAng < (10.0 * .pi / 180.0) else { continue }
                
                let mMid = SIMD2<Float>((m.startX + m.endX) * 0.5, (m.startZ + m.endZ) * 0.5)
                let perpDist = abs(simd_dot(segMid - mMid, normVec))
                guard perpDist <= perpTolerance else { continue }
                
                let mTan = SIMD2<Float>(cos(mAng), sin(mAng))
                let s1 = simd_dot(SIMD2<Float>(seg.startX, seg.startZ) - mMid, mTan)
                let s2 = simd_dot(SIMD2<Float>(seg.endX, seg.endZ) - mMid, mTan)
                let segMinS = min(s1, s2)
                let segMaxS = max(s1, s2)
                let mHalf = m.length * 0.5
                
                if max(-mHalf, segMinS) <= min(mHalf, segMaxS) + 22.0 {
                    let minS = min(-mHalf, segMinS)
                    let maxS = max(mHalf, segMaxS)
                    let avgCenter = (mMid + segMid) * 0.5
                    let avgMidOffset = avgCenter - mTan * simd_dot(avgCenter - mMid, mTan)
                    let pStart = avgMidOffset + mTan * minS
                    let pEnd = avgMidOffset + mTan * maxS
                    merged[i] = PlanLine(startX: pStart.x, startZ: pStart.y, endX: pEnd.x, endZ: pEnd.y)
                    didMerge = true
                    break
                }
            }
            if !didMerge {
                merged.append(seg)
            }
        }
        
        return merged.filter { $0.length >= 38.0 }
    }
    
    // MARK: - Vision OCR Dimension Recognition
    
    private static func detectDimensionsAndScaleWithVision(
        cgImage: CGImage,
        detectedSegments: [PlanLine],
        targetWidth: Int,
        targetHeight: Int
    ) -> (dimensions: [String], scaleMpp: Float?) {
        var recognizedDims: [String] = []
        var scaleEstimates: [Float] = []
        
        let request = VNRecognizeTextRequest { req, error in
            guard let observations = req.results as? [VNRecognizedTextObservation], error == nil else { return }
            
            for obs in observations {
                guard let topCandidate = obs.topCandidates(1).first else { continue }
                let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if let dimMeters = parseDimensionMeters(text: text) {
                    recognizedDims.append(text)
                    
                    let box = obs.boundingBox
                    let textCenterPx = CGPoint(
                        x: CGFloat(box.midX) * CGFloat(targetWidth),
                        y: (1.0 - CGFloat(box.midY)) * CGFloat(targetHeight)
                    )
                    let textIsHorizontal = box.width >= box.height
                    
                    // Pick the longest aligned wall segment within 95px of the dimension label
                    var bestSeg: PlanLine? = nil
                    var bestScore: Float = 0.0
                    for seg in detectedSegments {
                        let segLen = seg.length
                        guard segLen > 65.0 else { continue }
                        let segHoriz = abs(seg.endX - seg.startX) >= abs(seg.endZ - seg.startZ)
                        guard segHoriz == textIsHorizontal else { continue }
                        
                        let segMid = CGPoint(x: CGFloat(seg.startX + seg.endX) * 0.5, y: CGFloat(seg.startZ + seg.endZ) * 0.5)
                        let distToText = Float(hypot(segMid.x - textCenterPx.x, segMid.y - textCenterPx.y))
                        if distToText < 95.0 {
                            let score = segLen - distToText * 0.5
                            if score > bestScore {
                                bestScore = score
                                bestSeg = seg
                            }
                        }
                    }
                    
                    if let matchedSeg = bestSeg {
                        let mpp = dimMeters / matchedSeg.length
                        if mpp > 0.002 && mpp < 0.12 {
                            scaleEstimates.append(mpp)
                        }
                    }
                }
            }
        }
        
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        
        if !scaleEstimates.isEmpty {
            scaleEstimates.sort()
            let medianScale = scaleEstimates[scaleEstimates.count / 2]
            return (recognizedDims, medianScale)
        }
        
        return (recognizedDims, nil)
    }
    
    private static func parseDimensionMeters(text: String) -> Float? {
        let clean = text.lowercased().replacingOccurrences(of: ",", with: ".")
        
        // Match "X.XX m" or "X.XXm"
        if let range = clean.range(of: #"(\d+\.?\d*)\s*(m|meter)"#, options: .regularExpression) {
            let numStr = clean[range].replacingOccurrences(of: "meter", with: "").replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Float(numStr), val >= 0.8 && val <= 30.0 {
                return val
            }
        }
        
        // Match "XXXX mm"
        if let range = clean.range(of: #"(\d{3,5})\s*mm"#, options: .regularExpression) {
            let numStr = clean[range].replacingOccurrences(of: "mm", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Float(numStr), val >= 800 && val <= 30000 {
                return val / 1000.0
            }
        }
        
        // Match "XXX cm"
        if let range = clean.range(of: #"(\d+)\s*cm"#, options: .regularExpression) {
            let numStr = clean[range].replacingOccurrences(of: "cm", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Float(numStr), val >= 80 && val <= 3000 {
                return val / 100.0
            }
        }
        
        // Match feet + inches e.g. 12' 6" or 12'-6"
        if let regex = try? NSRegularExpression(pattern: #"(\d+)\s*'\s*[- ]?\s*(\d+)"#),
           let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
           match.numberOfRanges >= 3 {
            let ns = clean as NSString
            if let ft = Float(ns.substring(with: match.range(at: 1))),
               let inch = Float(ns.substring(with: match.range(at: 2))) {
                let totalM = (ft * 12.0 + inch) * 0.0254
                if totalM >= 0.8 && totalM <= 30.0 { return totalM }
            }
        }
        
        // Match "X' " or "X.X ft"
        if let range = clean.range(of: #"(\d+\.?\d*)\s*(ft|')"#, options: .regularExpression) {
            let numStr = clean[range].replacingOccurrences(of: "ft", with: "").replacingOccurrences(of: "'", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Float(numStr), val >= 3.0 && val <= 100.0 {
                return val * 0.3048
            }
        }
        
        return nil
    }
    
    // MARK: - Fallback Generator
    
    private static func fallbackResult(widthMeters: Float, depthMeters: Float) -> VectorizedPlanResult {
        let w = max(widthMeters, 6.0)
        let d = max(depthMeters, 6.0)
        let hw = w * 0.5
        let hd = d * 0.5
        let h: Float = 2.6
        
        let lines: [PlanLine] = [
            PlanLine(startX: -hw, startZ: -hd, endX: hw, endZ: -hd),
            PlanLine(startX: hw, startZ: -hd, endX: hw, endZ: hd),
            PlanLine(startX: hw, startZ: hd, endX: -hw, endZ: hd),
            PlanLine(startX: -hw, startZ: hd, endX: -hw, endZ: -hd)
        ]
        
        var walls: [WallSurface] = []
        for l in lines {
            let mx = (l.startX + l.endX) * 0.5
            let mz = (l.startZ + l.endZ) * 0.5
            let ang = l.angle
            let rotMat = simd_float4x4(
                SIMD4<Float>(cos(ang), 0, sin(ang), 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-sin(ang), 0, cos(ang), 0),
                SIMD4<Float>(mx, h * 0.5, mz, 1)
            )
            walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(l.length, h, 0.15), transform: rotMat))
        }
        
        return VectorizedPlanResult(
            vectorLines: lines,
            walls: walls,
            originalWidthMeters: w,
            originalDepthMeters: d,
            recognizedDimensions: [],
            detectedScaleMetersPerPixel: w / 1024.0
        )
    }
}
