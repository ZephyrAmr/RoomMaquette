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
    /// extracts geometric wall lines, recognizes dimension text via Vision OCR,
    /// computes real-world metric scale, and generates metric PlanLines and WallSurfaces.
    public static func vectorize(image: UIImage) -> VectorizedPlanResult {
        // 1. Standardize processing size for speed & consistent edge detection
        let targetWidth: Int = 1024
        let aspect = image.size.height / max(image.size.width, 1.0)
        let targetHeight: Int = max(Int(CGFloat(targetWidth) * aspect), 100)
        
        guard let grayscalePixels = extractGrayscalePixels(image: image, width: targetWidth, height: targetHeight) else {
            return fallbackResult(widthMeters: 14.0, depthMeters: 14.0 * Float(aspect))
        }
        
        // 2. Determine background polarity (light background vs dark blueprint)
        let isLightBackground = detectBackgroundPolarity(pixels: grayscalePixels, width: targetWidth, height: targetHeight)
        
        // 3. Extract horizontal and vertical architectural wall line segments
        let rawSegments = extractWallSegments(
            pixels: grayscalePixels,
            width: targetWidth,
            height: targetHeight,
            isLightBackground: isLightBackground
        )
        
        // 4. Run Vision OCR text recognition to detect metric scale callouts
        let (recognizedDims, ocrScaleMpp) = detectDimensionsAndScaleWithVision(
            image: image,
            detectedSegments: rawSegments,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        
        // 5. Determine overall scale (meters per pixel)
        let metersPerPixel: Float
        if let ocrScale = ocrScaleMpp, ocrScale > 0.001 && ocrScale < 0.20 {
            metersPerPixel = ocrScale
        } else {
            // Architectural prior: typical residential floor plan width is ~14 meters
            var minPxX: Float = .greatestFiniteMagnitude
            var maxPxX: Float = -.greatestFiniteMagnitude
            for seg in rawSegments {
                minPxX = min(minPxX, seg.startX, seg.endX)
                maxPxX = max(maxPxX, seg.startX, seg.endX)
            }
            let pixelSpan = max(maxPxX - minPxX, 100.0)
            metersPerPixel = 14.0 / pixelSpan
        }
        
        // 6. Center coordinates and convert pixel segments to metric space (meters)
        let midPxX = Float(targetWidth) / 2.0
        let midPxY = Float(targetHeight) / 2.0
        
        var planLines: [PlanLine] = []
        var walls: [WallSurface] = []
        let ceilingH: Float = 2.60
        
        for seg in rawSegments {
            let x1 = (seg.startX - midPxX) * metersPerPixel
            let z1 = (seg.startZ - midPxY) * metersPerPixel
            let x2 = (seg.endX - midPxX) * metersPerPixel
            let z2 = (seg.endZ - midPxY) * metersPerPixel
            
            let line = PlanLine(startX: x1, startZ: z1, endX: x2, endZ: z2)
            guard line.length > 0.40 else { continue } // Filter micro-segments
            
            planLines.append(line)
            
            // Synthesize 3D WallSurface for this line segment
            let wallLen = line.length
            let angle = line.angle
            let midX = (x1 + x2) / 2.0
            let midZ = (z1 + z2) / 2.0
            
            let cosA = cos(angle)
            let sinA = sin(angle)
            let rotMat = simd_float4x4(
                SIMD4<Float>(cosA, 0, sinA, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-sinA, 0, cosA, 0),
                SIMD4<Float>(midX, ceilingH / 2.0, midZ, 1)
            )
            
            walls.append(WallSurface(
                id: UUID(),
                dimensions: SIMD3<Float>(wallLen, ceilingH, 0.15),
                transform: rotMat
            ))
        }
        
        // If no structural segments were extracted (e.g. blank canvas or faint image),
        // synthesize standard 4 enclosing perimeter walls
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
    
    // MARK: - Pixel Extraction
    
    private static func extractGrayscalePixels(image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
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
        return pixels
    }
    
    // MARK: - Background Polarity Detection
    
    private static func detectBackgroundPolarity(pixels: [UInt8], width: Int, height: Int) -> Bool {
        // Sample corners and borders (which are almost always background)
        var sum: Int = 0
        var count: Int = 0
        let border = 10
        for y in [border, height - border - 1] where y >= 0 && y < height {
            for x in stride(from: border, to: width - border, by: 10) {
                sum += Int(pixels[y * width + x])
                count += 1
            }
        }
        let avg = count > 0 ? sum / count : 255
        return avg > 128 // True if white/light background, false if dark blueprint
    }
    
    // MARK: - Wall Line Segment Extraction
    
    private static func extractWallSegments(
        pixels: [UInt8],
        width: Int,
        height: Int,
        isLightBackground: Bool
    ) -> [PlanLine] {
        var segments: [PlanLine] = []
        
        // Wall pixel criterion: contrast against background
        func isWallPixel(_ val: UInt8) -> Bool {
            if isLightBackground {
                return val < 100 // Dark stroke on light paper
            } else {
                return val > 160 // Light stroke on dark blueprint
            }
        }
        
        let minLineLength = 30
        let maxThickness = 22
        
        // 1. Horizontal Scan for horizontal wall lines
        for y in stride(from: 8, to: height - 8, by: 4) {
            var startX: Int? = nil
            for x in 0..<width {
                let p = pixels[y * width + x]
                if isWallPixel(p) {
                    if startX == nil { startX = x }
                } else {
                    if let sx = startX {
                        let len = x - sx
                        if len >= minLineLength {
                            // Verify this is a thin architectural stroke vertically (not a solid shaded room)
                            var thickCount = 0
                            for checkY in max(0, y - maxThickness)...min(height - 1, y + maxThickness) {
                                if isWallPixel(pixels[checkY * width + (sx + x) / 2]) {
                                    thickCount += 1
                                }
                            }
                            if thickCount >= 2 && thickCount <= maxThickness {
                                segments.append(PlanLine(
                                    startX: Float(sx),
                                    startZ: Float(y),
                                    endX: Float(x),
                                    endZ: Float(y)
                                ))
                            }
                        }
                        startX = nil
                    }
                }
            }
        }
        
        // 2. Vertical Scan for vertical wall lines
        for x in stride(from: 8, to: width - 8, by: 4) {
            var startY: Int? = nil
            for y in 0..<height {
                let p = pixels[y * width + x]
                if isWallPixel(p) {
                    if startY == nil { startY = y }
                } else {
                    if let sy = startY {
                        let len = y - sy
                        if len >= minLineLength {
                            var thickCount = 0
                            for checkX in max(0, x - maxThickness)...min(width - 1, x + maxThickness) {
                                if isWallPixel(pixels[((sy + y) / 2) * width + checkX]) {
                                    thickCount += 1
                                }
                            }
                            if thickCount >= 2 && thickCount <= maxThickness {
                                segments.append(PlanLine(
                                    startX: Float(x),
                                    startZ: Float(sy),
                                    endX: Float(x),
                                    endZ: Float(y)
                                ))
                            }
                        }
                        startY = nil
                    }
                }
            }
        }
        
        // 3. Merge collinear segments and eliminate near-duplicates
        return mergeCollinearSegments(segments: segments)
    }
    
    private static func mergeCollinearSegments(segments: [PlanLine]) -> [PlanLine] {
        var merged: [PlanLine] = []
        let tolerance: Float = 10.0 // pixel tolerance for collinear grouping
        
        for seg in segments {
            let isHoriz = abs(seg.startZ - seg.endZ) < 3.0
            var didMerge = false
            
            for i in 0..<merged.count {
                let m = merged[i]
                let mHoriz = abs(m.startZ - m.endZ) < 3.0
                
                if isHoriz && mHoriz && abs(seg.startZ - m.startZ) <= tolerance {
                    // Check if x-ranges overlap or are close (< 25px gap)
                    let minX = min(seg.startX, m.startX)
                    let maxX = max(seg.endX, m.endX)
                    let combinedSpan = (seg.endX - seg.startX) + (m.endX - m.startX)
                    if (maxX - minX) <= combinedSpan + 25.0 {
                        merged[i] = PlanLine(startX: minX, startZ: (seg.startZ + m.startZ) / 2.0, endX: maxX, endZ: (seg.startZ + m.startZ) / 2.0)
                        didMerge = true
                        break
                    }
                } else if !isHoriz && !mHoriz && abs(seg.startX - m.startX) <= tolerance {
                    let minZ = min(seg.startZ, m.startZ)
                    let maxZ = max(seg.endZ, m.endZ)
                    let combinedSpan = (seg.endZ - seg.startZ) + (m.endZ - m.startZ)
                    if (maxZ - minZ) <= combinedSpan + 25.0 {
                        merged[i] = PlanLine(startX: (seg.startX + m.startX) / 2.0, startZ: minZ, endX: (seg.startX + m.startX) / 2.0, endZ: maxZ)
                        didMerge = true
                        break
                    }
                }
            }
            
            if !didMerge {
                merged.append(seg)
            }
        }
        
        return merged
    }
    
    // MARK: - Vision OCR Dimension Recognition
    
    private static func detectDimensionsAndScaleWithVision(
        image: UIImage,
        detectedSegments: [PlanLine],
        targetWidth: Int,
        targetHeight: Int
    ) -> (dimensions: [String], scaleMpp: Float?) {
        guard let cgImage = image.cgImage else { return ([], nil) }
        
        var recognizedDims: [String] = []
        var scaleEstimates: [Float] = []
        
        let request = VNRecognizeTextRequest { req, error in
            guard let observations = req.results as? [VNRecognizedTextObservation], error == nil else { return }
            
            for obs in observations {
                guard let topCandidate = obs.topCandidates(1).first else { continue }
                let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Regex for dimension: e.g. "3.50m", "4.2 m", "14' 6\"", "280 cm"
                if let dimMeters = parseDimensionMeters(text: text) {
                    recognizedDims.append(text)
                    
                    // Vision bounding box is normalized (0..1) with origin at bottom-left
                    let box = obs.boundingBox
                    let textCenterPx = CGPoint(
                        x: CGFloat(box.midX) * CGFloat(targetWidth),
                        y: (1.0 - CGFloat(box.midY)) * CGFloat(targetHeight)
                    )
                    
                    // Find nearest parallel segment within 120 pixels
                    for seg in detectedSegments {
                        let segMid = CGPoint(x: CGFloat(seg.startX + seg.endX)/2.0, y: CGFloat(seg.startZ + seg.endZ)/2.0)
                        let distToText = hypot(segMid.x - textCenterPx.x, segMid.y - textCenterPx.y)
                        if distToText < 120.0 {
                            let segLenPx = seg.length
                            if segLenPx > 40.0 {
                                let mpp = dimMeters / segLenPx
                                if mpp > 0.002 && mpp < 0.15 {
                                    scaleEstimates.append(mpp)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        
        // Return median scale estimate if available
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
            let numStr = clean[range].replacingOccurrences(of: "m", with: "").replacingOccurrences(of: "eter", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Float(numStr), val >= 0.8 && val <= 30.0 {
                return val
            }
        }
        
        // Match "XXX cm"
        if let range = clean.range(of: #"(\d+)\s*cm"#, options: .regularExpression) {
            let numStr = clean[range].replacingOccurrences(of: "cm", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Float(numStr), val >= 80 && val <= 3000 {
                return val / 100.0
            }
        }
        
        // Match "X' Y\"" or "X ft"
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
        let hw = w / 2.0
        let hd = d / 2.0
        let h: Float = 2.6
        
        let lines: [PlanLine] = [
            PlanLine(startX: -hw, startZ: -hd, endX: hw, endZ: -hd),
            PlanLine(startX: hw, startZ: -hd, endX: hw, endZ: hd),
            PlanLine(startX: hw, startZ: hd, endX: -hw, endZ: hd),
            PlanLine(startX: -hw, startZ: hd, endX: -hw, endZ: -hd)
        ]
        
        var walls: [WallSurface] = []
        for l in lines {
            let mx = (l.startX + l.endX)/2.0
            let mz = (l.startZ + l.endZ)/2.0
            let ang = l.angle
            let rotMat = simd_float4x4(
                SIMD4<Float>(cos(ang), 0, sin(ang), 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-sin(ang), 0, cos(ang), 0),
                SIMD4<Float>(mx, h/2.0, mz, 1)
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
