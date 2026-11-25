import UIKit
import Vision
import CoreGraphics
import simd

public struct VectorizedPlanResult {
    public var vectorLines: [PlanLine]
    public var walls: [WallSurface]
    public var doors: [DoorSurface]
    public var windows: [WindowSurface]
    public var openings: [OpeningSurface]
    public var originalWidthMeters: Float
    public var originalDepthMeters: Float
    public var recognizedDimensions: [String]
    public var detectedScaleMetersPerPixel: Float
    public var usedHeuristicScale: Bool
    
    public init(
        vectorLines: [PlanLine],
        walls: [WallSurface],
        doors: [DoorSurface] = [],
        windows: [WindowSurface] = [],
        openings: [OpeningSurface] = [],
        originalWidthMeters: Float,
        originalDepthMeters: Float,
        recognizedDimensions: [String],
        detectedScaleMetersPerPixel: Float,
        usedHeuristicScale: Bool = false
    ) {
        self.vectorLines = vectorLines
        self.walls = walls
        self.doors = doors
        self.windows = windows
        self.openings = openings
        self.originalWidthMeters = originalWidthMeters
        self.originalDepthMeters = originalDepthMeters
        self.recognizedDimensions = recognizedDimensions
        self.detectedScaleMetersPerPixel = detectedScaleMetersPerPixel
        self.usedHeuristicScale = usedHeuristicScale
    }
}

public class PlanImageVectorizer {
    
    private struct RawWallSeg {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var thicknessPx: Float
        
        var length: Float { simd_distance(a, b) }
        var dir: SIMD2<Float> {
            let l = max(length, 1e-4)
            return (b - a) / l
        }
        var angle: Float { atan2(b.y - a.y, b.x - a.x) }
        var mid: SIMD2<Float> { (a + b) * 0.5 }
    }
    
    private enum PortalCandidateKind {
        case door(swingSide: Float)
        case window
        case opening
    }
    
    private struct PortalCandidatePx {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var kind: PortalCandidateKind
        
        var widthPx: Float { simd_distance(a, b) }
        var mid: SIMD2<Float> { (a + b) * 0.5 }
        var angle: Float { atan2(b.y - a.y, b.x - a.x) }
    }
    
    private struct OCRToken {
        var rawText: String
        var boxPx: CGRect
        var explicitMeters: Float?
        var bareNumber: Float?
        var hasDecimal: Bool
    }
    
    /// Analyzes an imported floor plan image (PNG, JPG, HEIC, or rasterized PDF/SVG):
    /// 1. High-res grayscale normalization + integral-image local adaptive binarization
    /// 2. Vision OCR text detection & masking (prevents labels/numbers from polluting geometry)
    /// 3. Distance-transform thin-stroke filtering + hollow double-line CAD wall filling
    /// 4. Zhang-Suen skeletonization + Douglas-Peucker arbitrary-angle wall extraction + corner snapping
    /// 5. Door swing arc, opening, and window detection across collinear gaps & wall sections
    /// 6. Explicit + unitless OCR metric scale inference, with median-door-width fallback
    public static func vectorize(image: UIImage) -> VectorizedPlanResult {
        let maxDim: CGFloat = 1440.0
        let rawW = max(image.size.width, 1.0)
        let rawH = max(image.size.height, 1.0)
        let scaleDown = min(maxDim / max(rawW, rawH), 1.5)
        let targetWidth = max(Int((rawW * scaleDown).rounded()), 256)
        let targetHeight = max(Int((rawH * scaleDown).rounded()), 256)
        
        guard let (normalizedCG, pixels) = extractNormalizedGrayscalePixels(
            image: image,
            width: targetWidth,
            height: targetHeight
        ) else {
            return fallbackResult(widthMeters: 12.0, depthMeters: 12.0 * Float(rawH / rawW))
        }
        
        // 1. Adaptive foreground ink extraction
        let (isLightBg, fgRawMask) = buildAdaptiveForegroundMask(pixels: pixels, width: targetWidth, height: targetHeight)
        
        // 2. Run Vision OCR first so dimension/room text is masked out before vectorizing lines
        let ocrTokens = recognizeTextTokens(cgImage: normalizedCG, width: targetWidth, height: targetHeight)
        var fgCleanMask = fgRawMask
        maskTextRegions(tokens: ocrTokens, in: &fgCleanMask, width: targetWidth, height: targetHeight)
        
        // 3. Isolate architectural walls (solid thick walls + hollow double-line CAD walls)
        let distMap = computeManhattanDistanceTransform(mask: fgCleanMask, width: targetWidth, height: targetHeight)
        var wallMask = buildArchitecturalWallMask(
            fgMask: fgCleanMask,
            distMap: distMap,
            width: targetWidth,
            height: targetHeight
        )
        
        // If thick/hollow isolation yielded almost nothing, fall back to clean foreground (single-line CAD plans)
        let wallInkCount = wallMask.reduce(0) { $0 + Int($1) }
        if wallInkCount < (targetWidth * targetHeight) / 450 {
            wallMask = fgCleanMask
        }
        morphologicalClose3x3(&wallMask, width: targetWidth, height: targetHeight)
        
        // 4. Zhang-Suen topological thinning -> 1px skeleton at all angles
        let skeleton = zhangSuenThin(wallMask, width: targetWidth, height: targetHeight)
        
        // 5. Trace skeleton chains -> Douglas-Peucker -> collinear & corner snapping
        var rawWalls = traceAndSimplifySkeleton(
            skeleton: skeleton,
            distMap: distMap,
            width: targetWidth,
            height: targetHeight
        )
        rawWalls = cleanupAndSnapSegments(rawWalls, width: targetWidth, height: targetHeight)
        
        if rawWalls.isEmpty {
            return fallbackResult(widthMeters: 12.0, depthMeters: 12.0 * Float(rawH / rawW))
        }
        
        // 6. Detect Doors (swing arcs), Openings, and Windows between wall segments
        let portalsPx = detectPortals(
            segments: rawWalls,
            fgMask: fgRawMask,
            pixels: pixels,
            isLightBg: isLightBg,
            width: targetWidth,
            height: targetHeight
        )
        
        // 7. Compute metric scale (Explicit OCR -> Unitless OCR -> Door-width heuristic -> Bounding span heuristic)
        let (recognizedDims, ocrMpp) = inferMetricScaleFromOCR(tokens: ocrTokens, walls: rawWalls)
        let metersPerPixel: Float
        let usedHeuristicScale: Bool
        
        if let mpp = ocrMpp, mpp > 0.001 && mpp < 0.15 {
            metersPerPixel = mpp
            usedHeuristicScale = false
        } else {
            let doorWidths = portalsPx.compactMap { p -> Float? in
                if case .door = p.kind { return p.widthPx }
                return nil
            }.sorted()
            
            if !doorWidths.isEmpty {
                let medDoorPx = max(doorWidths[doorWidths.count / 2], 16.0)
                let estMpp = 0.88 / medDoorPx
                let spanPx = boundingWidthPx(walls: rawWalls, fallback: Float(targetWidth))
                let totalSpanM = spanPx * estMpp
                if totalSpanM >= 3.5 && totalSpanM <= 55.0 {
                    metersPerPixel = estMpp
                } else {
                    metersPerPixel = 12.0 / max(spanPx, 120.0)
                }
            } else {
                let spanPx = boundingWidthPx(walls: rawWalls, fallback: Float(targetWidth))
                metersPerPixel = 12.0 / max(spanPx, 120.0)
            }
            usedHeuristicScale = true
        }
        
        // 8. Convert pixels -> centered metric 3D WallSurfaces, Doors, Windows, Openings
        let midPxX = Float(targetWidth) * 0.5
        let midPxY = Float(targetHeight) * 0.5
        let ceilingH: Float = 2.60
        
        var planLines: [PlanLine] = []
        var walls: [WallSurface] = []
        
        for seg in rawWalls {
            let x1 = (seg.a.x - midPxX) * metersPerPixel
            let z1 = (seg.a.y - midPxY) * metersPerPixel
            let x2 = (seg.b.x - midPxX) * metersPerPixel
            let z2 = (seg.b.y - midPxY) * metersPerPixel
            
            let line = PlanLine(startX: x1, startZ: z1, endX: x2, endZ: z2)
            guard line.length >= 0.28 else { continue }
            planLines.append(line)
            
            let estThickM = max(0.10, min(0.35, seg.thicknessPx * metersPerPixel))
            let midX = (x1 + x2) * 0.5
            let midZ = (z1 + z2) * 0.5
            let rotMat = yRotationTransform(angle: line.angle, x: midX, y: ceilingH * 0.5, z: midZ)
            
            walls.append(WallSurface(
                id: UUID(),
                dimensions: SIMD3<Float>(line.length, ceilingH, estThickM),
                transform: rotMat
            ))
        }
        
        var doors: [DoorSurface] = []
        var windows: [WindowSurface] = []
        var openings: [OpeningSurface] = []
        
        for p in portalsPx {
            let x1 = (p.a.x - midPxX) * metersPerPixel
            let z1 = (p.a.y - midPxY) * metersPerPixel
            let x2 = (p.b.x - midPxX) * metersPerPixel
            let z2 = (p.b.y - midPxY) * metersPerPixel
            let wM = hypot(x2 - x1, z2 - z1)
            let midX = (x1 + x2) * 0.5
            let midZ = (z1 + z2) * 0.5
            let ang = atan2(z2 - z1, x2 - x1)
            
            switch p.kind {
            case .door:
                guard wM >= 0.45 && wM <= 2.20 else { continue }
                let h: Float = 2.08
                let mat = yRotationTransform(angle: ang, x: midX, y: h * 0.5, z: midZ)
                doors.append(DoorSurface(id: UUID(), dimensions: SIMD3<Float>(wM, h, 0.08), transform: mat, isOpen: true))
            case .window:
                guard wM >= 0.40 && wM <= 4.50 else { continue }
                let h: Float = 1.25
                let mat = yRotationTransform(angle: ang, x: midX, y: 1.45, z: midZ)
                windows.append(WindowSurface(id: UUID(), dimensions: SIMD3<Float>(wM, h, 0.10), transform: mat))
            case .opening:
                guard wM >= 0.55 && wM <= 4.00 else { continue }
                let h: Float = 2.20
                let mat = yRotationTransform(angle: ang, x: midX, y: h * 0.5, z: midZ)
                openings.append(OpeningSurface(id: UUID(), dimensions: SIMD3<Float>(wM, h, 0.12), transform: mat))
            }
        }
        
        let totalWidthMeters = Float(targetWidth) * metersPerPixel
        let totalDepthMeters = Float(targetHeight) * metersPerPixel
        
        if planLines.isEmpty {
            return fallbackResult(widthMeters: totalWidthMeters, depthMeters: totalDepthMeters)
        }
        
        return VectorizedPlanResult(
            vectorLines: planLines,
            walls: walls,
            doors: doors,
            windows: windows,
            openings: openings,
            originalWidthMeters: totalWidthMeters,
            originalDepthMeters: totalDepthMeters,
            recognizedDimensions: recognizedDims,
            detectedScaleMetersPerPixel: metersPerPixel,
            usedHeuristicScale: usedHeuristicScale
        )
    }
    
    /// Helper exposed for DXF / SVG / PDF vector scale calibration via Vision OCR
    public static func detectScaleFromRenderedImage(
        image: UIImage,
        pixelLines: [PlanLine],
        width: Int,
        height: Int
    ) -> (dimensions: [String], scaleMpp: Float?) {
        guard let (cgImg, _) = extractNormalizedGrayscalePixels(image: image, width: width, height: height) else {
            return ([], nil)
        }
        let tokens = recognizeTextTokens(cgImage: cgImg, width: width, height: height)
        let walls = pixelLines.map {
            RawWallSeg(a: SIMD2<Float>($0.startX, $0.startZ), b: SIMD2<Float>($0.endX, $0.endZ), thicknessPx: 6.0)
        }
        return inferMetricScaleFromOCR(tokens: tokens, walls: walls)
    }
    
    private static func yRotationTransform(angle: Float, x: Float, y: Float, z: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(c, 0, s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(-s, 0, c, 0),
            SIMD4<Float>(x, y, z, 1)
        )
    }
    
    private static func boundingWidthPx(walls: [RawWallSeg], fallback: Float) -> Float {
        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        for s in walls {
            minX = min(minX, s.a.x, s.b.x)
            maxX = max(maxX, s.a.x, s.b.x)
        }
        return minX < maxX ? max(maxX - minX, 80.0) : fallback
    }
    
    // MARK: - 1. Orientation-Normalized Grayscale & Adaptive Mask
    
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
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (cgImage, pixels)
    }
    
    private static func buildAdaptiveForegroundMask(pixels: [UInt8], width: Int, height: Int) -> (isLightBg: Bool, mask: [UInt8]) {
        // Sample border luminance to determine background polarity
        var hist = [Int](repeating: 0, count: 256)
        var borderSum = 0
        var borderCount = 0
        let bOff = min(8, height / 4)
        for y in [bOff, max(0, height - bOff - 1)] {
            for x in stride(from: 4, to: width - 4, by: 4) {
                borderSum += Int(pixels[y * width + x])
                borderCount += 1
            }
        }
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                hist[Int(pixels[y * width + x])] += 1
            }
        }
        let totalSamples = max(hist.reduce(0, +), 1)
        let bgAvg = borderCount > 0 ? borderSum / borderCount : 255
        let isLightBg = bgAvg >= 120
        
        // Find extreme ink percentiles (handles dark black walls inside large fills)
        var acc = 0
        var p5 = 0
        var p95 = 255
        for i in 0..<256 {
            acc += hist[i]
            if acc * 100 >= totalSamples * 5 && p5 == 0 { p5 = i }
            if acc * 100 >= totalSamples * 95 && p95 == 255 { p95 = i }
        }
        
        // Build Integral Image (Int) for fast O(1) 41x41 local luminance box average
        let strideW = width + 1
        var sat = [Int](repeating: 0, count: strideW * (height + 1))
        for y in 0..<height {
            var rowSum = 0
            let rowBase = y * width
            let satCur = (y + 1) * strideW
            let satPrev = y * strideW
            for x in 0..<width {
                rowSum += Int(pixels[rowBase + x])
                sat[satCur + x + 1] = sat[satPrev + x + 1] + rowSum
            }
        }
        
        var mask = [UInt8](repeating: 0, count: width * height)
        let radius = 20
        let hardDarkCutoff = min(105, p5 + 40)
        let hardBrightCutoff = max(165, p95 - 35)
        
        for y in 0..<height {
            let y0 = max(0, y - radius)
            let y1 = min(height, y + radius + 1)
            let dy = y1 - y0
            let rowIdx = y * width
            for x in 0..<width {
                let x0 = max(0, x - radius)
                let x1 = min(width, x + radius + 1)
                let count = (x1 - x0) * dy
                let sum = sat[y1 * strideW + x1] - sat[y0 * strideW + x1] - sat[y1 * strideW + x0] + sat[y0 * strideW + x0]
                let localMean = sum / max(count, 1)
                let val = Int(pixels[rowIdx + x])
                
                if isLightBg {
                    // Captures both solid black fills and uneven-lit strokes, rejects pale tint fills
                    if val <= hardDarkCutoff || (val < localMean - 18 && val < 192) {
                        mask[rowIdx + x] = 1
                    }
                } else {
                    if val >= hardBrightCutoff || (val > localMean + 18 && val > 70) {
                        mask[rowIdx + x] = 1
                    }
                }
            }
        }
        
        return (isLightBg, mask)
    }
    
    // MARK: - 2. Vision OCR Text Recognition & Masking
    
    private static func recognizeTextTokens(cgImage: CGImage, width: Int, height: Int) -> [OCRToken] {
        var tokens: [OCRToken] = []
        let req = VNRecognizeTextRequest { request, error in
            guard error == nil, let obsList = request.results as? [VNRecognizedTextObservation] else { return }
            for obs in obsList {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let b = obs.boundingBox
                let boxPx = CGRect(
                    x: b.minX * CGFloat(width),
                    y: (1.0 - b.maxY) * CGFloat(height),
                    width: b.width * CGFloat(width),
                    height: b.height * CGFloat(height)
                )
                let expM = parseExplicitMeters(text: text)
                let (bareNum, hasDec) = parseBareDimensionNumber(text: text)
                tokens.append(OCRToken(
                    rawText: text,
                    boxPx: boxPx,
                    explicitMeters: expM,
                    bareNumber: bareNum,
                    hasDecimal: hasDec
                ))
            }
        }
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([req])
        return tokens
    }
    
    private static func maskTextRegions(tokens: [OCRToken], in mask: inout [UInt8], width: Int, height: Int) {
        for tok in tokens {
            let box = tok.boxPx
            // Skip suspicious huge boxes covering full rooms
            guard box.height <= 68 && box.width <= CGFloat(width) * 0.45 else { continue }
            let x0 = max(0, Int(floor(box.minX)) - 2)
            let x1 = min(width - 1, Int(ceil(box.maxX)) + 2)
            let y0 = max(0, Int(floor(box.minY)) - 2)
            let y1 = min(height - 1, Int(ceil(box.maxY)) + 2)
            guard x0 <= x1 && y0 <= y1 else { continue }
            for y in y0...y1 {
                let r = y * width
                for x in x0...x1 {
                    mask[r + x] = 0
                }
            }
        }
    }
    
    // MARK: - 3. Distance Transform & Wall Mask Isolation
    
    private static func computeManhattanDistanceTransform(mask: [UInt8], width: Int, height: Int) -> [UInt16] {
        let inf: UInt16 = 9999
        var dist = [UInt16](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            dist[i] = mask[i] == 1 ? inf : 0
        }
        // Forward pass
        for y in 0..<height {
            let r = y * width
            for x in 0..<width {
                let idx = r + x
                if dist[idx] == 0 { continue }
                var d = dist[idx]
                if x > 0 { d = min(d, dist[idx - 1] &+ 1) }
                if y > 0 { d = min(d, dist[idx - width] &+ 1) }
                dist[idx] = d
            }
        }
        // Backward pass
        for y in stride(from: height - 1, through: 0, by: -1) {
            let r = y * width
            for x in stride(from: width - 1, through: 0, by: -1) {
                let idx = r + x
                if dist[idx] == 0 { continue }
                var d = dist[idx]
                if x < width - 1 { d = min(d, dist[idx + 1] &+ 1) }
                if y < height - 1 { d = min(d, dist[idx + width] &+ 1) }
                dist[idx] = d
            }
        }
        return dist
    }
    
    private static func buildArchitecturalWallMask(
        fgMask: [UInt8],
        distMap: [UInt16],
        width: Int,
        height: Int
    ) -> [UInt8] {
        // A. Keep thick solid strokes (core dist >= 2 -> stroke >= 4px wide) and expand back to edges
        var wallMask = [UInt8](repeating: 0, count: width * height)
        var coreSeeds: [(Int, Int, Int)] = []
        for y in 2..<(height - 2) {
            let r = y * width
            for x in 2..<(width - 2) {
                let d = Int(distMap[r + x])
                if d >= 2 {
                    wallMask[r + x] = 1
                    coreSeeds.append((x, y, min(d + 1, 18)))
                }
            }
        }
        // Reconstruct dilated solid wall bodies bounded strictly inside fgMask
        for (cx, cy, rad) in coreSeeds where (cx + cy) % 2 == 0 {
            let x0 = max(0, cx - rad)
            let x1 = min(width - 1, cx + rad)
            let y0 = max(0, cy - rad)
            let y1 = min(height - 1, cy + rad)
            for y in y0...y1 {
                let r = y * width
                for x in x0...x1 where fgMask[r + x] == 1 {
                    wallMask[r + x] = 1
                }
            }
        }
        
        // B. Fill hollow double-line CAD walls (two dark strokes 4..20px apart enclosing white cavity)
        let minGap = 3
        let maxGap = 20
        // Horizontal cross-section scan (captures vertical double-line walls)
        for y in stride(from: 6, to: height - 6, by: 2) {
            let r = y * width
            var x = 2
            while x < width - 3 {
                if fgMask[r + x] == 1 && fgMask[r + x + 1] == 0 {
                    let leftEdge = x
                    var gapEnd = x + 1
                    while gapEnd < min(width - 2, x + maxGap + 1) && fgMask[r + gapEnd] == 0 {
                        gapEnd += 1
                    }
                    let gapW = gapEnd - (x + 1)
                    if gapW >= minGap && gapW <= maxGap && fgMask[r + gapEnd] == 1 {
                        // Verify parallel vertical continuity at y +/- 8
                        let yPrev = max(0, y - 8) * width
                        let yNext = min(height - 1, y + 8) * width
                        let prevOk = fgMask[yPrev + leftEdge] == 1 || fgMask[yPrev + leftEdge - 1] == 1 || fgMask[yPrev + leftEdge + 1] == 1
                        let prevRightOk = fgMask[yPrev + gapEnd] == 1 || fgMask[yPrev + gapEnd - 1] == 1 || fgMask[yPrev + gapEnd + 1] == 1
                        let nextOk = fgMask[yNext + leftEdge] == 1 || fgMask[yNext + leftEdge - 1] == 1 || fgMask[yNext + leftEdge + 1] == 1
                        let nextRightOk = fgMask[yNext + gapEnd] == 1 || fgMask[yNext + gapEnd - 1] == 1 || fgMask[yNext + gapEnd + 1] == 1
                        if (prevOk && prevRightOk) && (nextOk && nextRightOk) {
                            for fy in max(0, y - 1)...min(height - 1, y + 1) {
                                let fr = fy * width
                                for fx in max(0, leftEdge - 1)...min(width - 1, gapEnd + 1) {
                                    wallMask[fr + fx] = 1
                                }
                            }
                        }
                    }
                    x = gapEnd
                } else {
                    x += 1
                }
            }
        }
        
        // Vertical cross-section scan (captures horizontal double-line walls)
        for x in stride(from: 6, to: width - 6, by: 2) {
            var y = 2
            while y < height - 3 {
                if fgMask[y * width + x] == 1 && fgMask[(y + 1) * width + x] == 0 {
                    let topEdge = y
                    var gapEnd = y + 1
                    while gapEnd < min(height - 2, y + maxGap + 1) && fgMask[gapEnd * width + x] == 0 {
                        gapEnd += 1
                    }
                    let gapH = gapEnd - (y + 1)
                    if gapH >= minGap && gapH <= maxGap && fgMask[gapEnd * width + x] == 1 {
                        let xPrev = max(0, x - 8)
                        let xNext = min(width - 1, x + 8)
                        let prevOk = fgMask[topEdge * width + xPrev] == 1 || fgMask[max(0, topEdge - 1) * width + xPrev] == 1
                        let prevBotOk = fgMask[gapEnd * width + xPrev] == 1 || fgMask[min(height - 1, gapEnd + 1) * width + xPrev] == 1
                        let nextOk = fgMask[topEdge * width + xNext] == 1 || fgMask[max(0, topEdge - 1) * width + xNext] == 1
                        let nextBotOk = fgMask[gapEnd * width + xNext] == 1 || fgMask[min(height - 1, gapEnd + 1) * width + xNext] == 1
                        if (prevOk && prevBotOk) && (nextOk && nextBotOk) {
                            for fy in max(0, topEdge - 1)...min(height - 1, gapEnd + 1) {
                                let fr = fy * width
                                for fx in max(0, x - 1)...min(width - 1, x + 1) {
                                    wallMask[fr + fx] = 1
                                }
                            }
                        }
                    }
                    y = gapEnd
                } else {
                    y += 1
                }
            }
        }
        
        return wallMask
    }
    
    private static func morphologicalClose3x3(_ mask: inout [UInt8], width: Int, height: Int) {
        var dilated = mask
        for y in 1..<(height - 1) {
            let r = y * width
            for x in 1..<(width - 1) where mask[r + x] == 0 {
                if mask[r + x - 1] == 1 && mask[r + x + 1] == 1 { dilated[r + x] = 1; continue }
                if mask[r - width + x] == 1 && mask[r + width + x] == 1 { dilated[r + x] = 1; continue }
            }
        }
        var eroded = dilated
        for y in 1..<(height - 1) {
            let r = y * width
            for x in 1..<(width - 1) where dilated[r + x] == 1 {
                let n = Int(dilated[r + x - 1]) + Int(dilated[r + x + 1]) + Int(dilated[r - width + x]) + Int(dilated[r + width + x])
                if n == 0 { eroded[r + x] = 0 }
            }
        }
        mask = eroded
    }
    
    // MARK: - 4. Zhang-Suen Thinning (Skeletonization)
    
    private static func zhangSuenThin(_ input: [UInt8], width: Int, height: Int) -> [UInt8] {
        var img = input
        // Zero outer 1-pixel border for safe neighbor indexing
        for x in 0..<width { img[x] = 0; img[(height - 1) * width + x] = 0 }
        for y in 0..<height { img[y * width] = 0; img[y * width + width - 1] = 0 }
        
        var active: [Int] = []
        active.reserveCapacity((width * height) / 12)
        for y in 1..<(height - 1) {
            let r = y * width
            for x in 1..<(width - 1) where img[r + x] == 1 {
                active.append(r + x)
            }
        }
        
        var toRemove: [Int] = []
        toRemove.reserveCapacity(4096)
        
        for _ in 0..<24 {
            var changed = false
            
            // Sub-iteration 1
            toRemove.removeAll(keepingCapacity: true)
            for idx in active where img[idx] == 1 {
                let p2 = img[idx - width]
                let p3 = img[idx - width + 1]
                let p4 = img[idx + 1]
                let p5 = img[idx + width + 1]
                let p6 = img[idx + width]
                let p7 = img[idx + width - 1]
                let p8 = img[idx - 1]
                let p9 = img[idx - width - 1]
                
                let b = p2 &+ p3 &+ p4 &+ p5 &+ p6 &+ p7 &+ p8 &+ p9
                guard b >= 2 && b <= 6 else { continue }
                
                var a = 0
                if p2 == 0 && p3 == 1 { a += 1 }
                if p3 == 0 && p4 == 1 { a += 1 }
                if p4 == 0 && p5 == 1 { a += 1 }
                if p5 == 0 && p6 == 1 { a += 1 }
                if p6 == 0 && p7 == 1 { a += 1 }
                if p7 == 0 && p8 == 1 { a += 1 }
                if p8 == 0 && p9 == 1 { a += 1 }
                if p9 == 0 && p2 == 1 { a += 1 }
                guard a == 1 else { continue }
                
                if (p2 &* p4 &* p6) == 0 && (p4 &* p6 &* p8) == 0 {
                    toRemove.append(idx)
                }
            }
            if !toRemove.isEmpty {
                for idx in toRemove { img[idx] = 0 }
                changed = true
            }
            
            // Sub-iteration 2
            toRemove.removeAll(keepingCapacity: true)
            for idx in active where img[idx] == 1 {
                let p2 = img[idx - width]
                let p3 = img[idx - width + 1]
                let p4 = img[idx + 1]
                let p5 = img[idx + width + 1]
                let p6 = img[idx + width]
                let p7 = img[idx + width - 1]
                let p8 = img[idx - 1]
                let p9 = img[idx - width - 1]
                
                let b = p2 &+ p3 &+ p4 &+ p5 &+ p6 &+ p7 &+ p8 &+ p9
                guard b >= 2 && b <= 6 else { continue }
                
                var a = 0
                if p2 == 0 && p3 == 1 { a += 1 }
                if p3 == 0 && p4 == 1 { a += 1 }
                if p4 == 0 && p5 == 1 { a += 1 }
                if p5 == 0 && p6 == 1 { a += 1 }
                if p6 == 0 && p7 == 1 { a += 1 }
                if p7 == 0 && p8 == 1 { a += 1 }
                if p8 == 0 && p9 == 1 { a += 1 }
                if p9 == 0 && p2 == 1 { a += 1 }
                guard a == 1 else { continue }
                
                if (p2 &* p4 &* p8) == 0 && (p2 &* p6 &* p8) == 0 {
                    toRemove.append(idx)
                }
            }
            if !toRemove.isEmpty {
                for idx in toRemove { img[idx] = 0 }
                changed = true
            }
            
            if !changed { break }
            active.removeAll { img[$0] == 0 }
        }
        return img
    }
    
    // MARK: - 5. Skeleton Chain Tracing, Douglas-Peucker & Snapping
    
    private static func traceAndSimplifySkeleton(
        skeleton: [UInt8],
        distMap: [UInt16],
        width: Int,
        height: Int
    ) -> [RawWallSeg] {
        let neighborOffsets = [
            -width - 1, -width, -width + 1,
            -1,                  1,
             width - 1,  width,  width + 1
        ]
        
        var visitedEdge = Set<Int64>()
        var degMap = [UInt8](repeating: 0, count: width * height)
        var startNodes: [Int] = []
        
        for y in 1..<(height - 1) {
            let r = y * width
            for x in 1..<(width - 1) {
                let idx = r + x
                guard skeleton[idx] == 1 else { continue }
                var deg: UInt8 = 0
                for off in neighborOffsets {
                    if skeleton[idx + off] == 1 { deg += 1 }
                }
                degMap[idx] = deg
                if deg == 1 || deg >= 3 {
                    startNodes.append(idx)
                }
            }
        }
        
        func edgeKey(_ a: Int, _ b: Int) -> Int64 {
            let lo = Int64(min(a, b))
            let hi = Int64(max(a, b))
            return (lo << 32) | hi
        }
        
        var polylines: [[SIMD2<Float>]] = []
        
        func traceFrom(node: Int) {
            for off in neighborOffsets {
                let nxt = node + off
                guard skeleton[nxt] == 1 else { continue }
                let ek = edgeKey(node, nxt)
                guard !visitedEdge.contains(ek) else { continue }
                
                visitedEdge.insert(ek)
                var chain: [Int] = [node, nxt]
                var prev = node
                var cur = nxt
                
                while degMap[cur] == 2 && chain.count < 4000 {
                    var foundNext: Int? = nil
                    for off2 in neighborOffsets {
                        let cand = cur + off2
                        if cand != prev && skeleton[cand] == 1 {
                            let ek2 = edgeKey(cur, cand)
                            if !visitedEdge.contains(ek2) {
                                visitedEdge.insert(ek2)
                                foundNext = cand
                                break
                            }
                        }
                    }
                    guard let fn = foundNext else { break }
                    chain.append(fn)
                    prev = cur
                    cur = fn
                    if degMap[cur] >= 3 || degMap[cur] == 1 { break }
                }
                
                if chain.count >= 12 {
                    let pts = chain.map { SIMD2<Float>(Float($0 % width), Float($0 / width)) }
                    polylines.append(douglasPeucker(pts, epsilon: 2.6))
                }
            }
        }
        
        for node in startNodes {
            traceFrom(node: node)
        }
        // Remaining closed loops (all deg == 2)
        for y in 1..<(height - 1) {
            let r = y * width
            for x in 1..<(width - 1) where degMap[r + x] == 2 {
                traceFrom(node: r + x)
            }
        }
        
        var segs: [RawWallSeg] = []
        for poly in polylines where poly.count >= 2 {
            for i in 0..<(poly.count - 1) {
                let p1 = poly[i]
                let p2 = poly[i + 1]
                let len = simd_distance(p1, p2)
                guard len >= 18.0 else { continue }
                
                let mx = min(max(Int(((p1.x + p2.x) * 0.5).rounded()), 0), width - 1)
                let my = min(max(Int(((p1.y + p2.y) * 0.5).rounded()), 0), height - 1)
                let localRad = Float(distMap[my * width + mx])
                let estThick = max(localRad * 2.0, 5.0)
                segs.append(RawWallSeg(a: p1, b: p2, thicknessPx: estThick))
            }
        }
        
        return segs
    }
    
    private static func douglasPeucker(_ pts: [SIMD2<Float>], epsilon: Float) -> [SIMD2<Float>] {
        guard pts.count >= 3 else { return pts }
        let start = pts.first!
        let end = pts.last!
        var maxDist: Float = 0.0
        var maxIdx = 0
        
        let ab = end - start
        let abLen = simd_length(ab)
        for i in 1..<(pts.count - 1) {
            let d: Float
            if abLen < 1e-4 {
                d = simd_distance(pts[i], start)
            } else {
                let ap = pts[i] - start
                d = abs(ab.x * ap.y - ab.y * ap.x) / abLen
            }
            if d > maxDist {
                maxDist = d
                maxIdx = i
            }
        }
        if maxDist > epsilon {
            let left = douglasPeucker(Array(pts[0...maxIdx]), epsilon: epsilon)
            let right = douglasPeucker(Array(pts[maxIdx..<pts.count]), epsilon: epsilon)
            return left.dropLast() + right
        } else {
            return [start, end]
        }
    }
    
    private static func cleanupAndSnapSegments(_ input: [RawWallSeg], width: Int, height: Int) -> [RawWallSeg] {
        // 1. Reject full-sheet border frames & snap near-orthogonal walls within 3.5 deg
        var segs: [RawWallSeg] = []
        let borderPad: Float = 14.0
        for var s in input {
            let spanW = abs(s.a.x - s.b.x)
            let spanH = abs(s.a.y - s.b.y)
            let isBorderTopBot = (min(s.a.y, s.b.y) < borderPad || max(s.a.y, s.b.y) > Float(height) - borderPad) && spanW > Float(width) * 0.90
            let isBorderLR = (min(s.a.x, s.b.x) < borderPad || max(s.a.x, s.b.x) > Float(width) - borderPad) && spanH > Float(height) * 0.90
            if isBorderTopBot || isBorderLR { continue }
            
            let ang = s.angle
            let absSin = abs(sin(ang))
            let absCos = abs(cos(ang))
            if absSin < sin(3.5 * .pi / 180.0) {
                let avgY = (s.a.y + s.b.y) * 0.5
                s.a.y = avgY
                s.b.y = avgY
            } else if absCos < sin(3.5 * .pi / 180.0) {
                let avgX = (s.a.x + s.b.x) * 0.5
                s.a.x = avgX
                s.b.x = avgX
            }
            segs.append(s)
        }
        
        // 2. Merge near-collinear split segments with tiny gaps (<= 8px), preserving larger door gaps!
        var merged: [RawWallSeg] = []
        let angTol: Float = 6.5 * .pi / 180.0
        for s in segs.sorted(by: { $0.length > $1.length }) {
            let tanS = s.dir
            let normS = SIMD2<Float>(-tanS.y, tanS.x)
            let midS = s.mid
            var fused = false
            
            for i in 0..<merged.count {
                let m = merged[i]
                var dAng = abs(s.angle - m.angle)
                if dAng > .pi * 0.5 { dAng = abs(dAng - .pi) }
                guard dAng < angTol else { continue }
                
                let perp = abs(simd_dot(midS - m.mid, normS))
                guard perp <= 7.0 else { continue }
                
                let mTan = m.dir
                let s1 = simd_dot(s.a - m.mid, mTan)
                let s2 = simd_dot(s.b - m.mid, mTan)
                let segMin = min(s1, s2)
                let segMax = max(s1, s2)
                let mHalf = m.length * 0.5
                
                if max(-mHalf, segMin) <= min(mHalf, segMax) + 8.0 {
                    let lo = min(-mHalf, segMin)
                    let hi = max(mHalf, segMax)
                    let projMid = m.mid
                    merged[i].a = projMid + mTan * lo
                    merged[i].b = projMid + mTan * hi
                    merged[i].thicknessPx = (m.thicknessPx + s.thicknessPx) * 0.5
                    fused = true
                    break
                }
            }
            if !fused {
                merged.append(s)
            }
        }
        
        // 3. Snap close corner endpoints within 10px to cluster centroids
        var endpoints: [SIMD2<Float>] = []
        for s in merged {
            endpoints.append(s.a)
            endpoints.append(s.b)
        }
        var clusters: [[SIMD2<Float>]] = []
        for ep in endpoints {
            if let idx = clusters.firstIndex(where: { simd_distance($0[0], ep) <= 10.0 }) {
                clusters[idx].append(ep)
            } else {
                clusters.append([ep])
            }
        }
        let centroids: [SIMD2<Float>] = clusters.map { list in
            list.reduce(.zero, +) / Float(list.count)
        }
        func snap(_ p: SIMD2<Float>) -> SIMD2<Float> {
            for c in centroids where simd_distance(p, c) <= 10.0 {
                return c
            }
            return p
        }
        
        var finalSegs: [RawWallSeg] = []
        for var s in merged {
            s.a = snap(s.a)
            s.b = snap(s.b)
            if s.length >= 24.0 {
                finalSegs.append(s)
            }
        }
        return finalSegs
    }
    
    // MARK: - 6. Automatic Door, Window & Opening Detection
    
    private static func detectPortals(
        segments: [RawWallSeg],
        fgMask: [UInt8],
        pixels: [UInt8],
        isLightBg: Bool,
        width: Int,
        height: Int
    ) -> [PortalCandidatePx] {
        var portals: [PortalCandidatePx] = []
        let minGapPx: Float = 14.0
        let maxGapPx: Float = 115.0
        
        func inkAt(_ x: Float, _ y: Float) -> Bool {
            let ix = Int(x.rounded())
            let iy = Int(y.rounded())
            guard ix >= 1 && ix < width - 1 && iy >= 1 && iy < height - 1 else { return false }
            for dy in -1...1 {
                let r = (iy + dy) * width
                for dx in -1...1 where fgMask[r + ix + dx] == 1 {
                    return true
                }
            }
            return false
        }
        
        for i in 0..<segments.count {
            let sA = segments[i]
            let dirA = sA.dir
            let normA = SIMD2<Float>(-dirA.y, dirA.x)
            
            for j in (i + 1)..<segments.count {
                let sB = segments[j]
                guard abs(simd_dot(dirA, sB.dir)) > 0.985 else { continue }
                
                let pairs: [(SIMD2<Float>, SIMD2<Float>)] = [
                    (sA.a, sB.a), (sA.a, sB.b),
                    (sA.b, sB.a), (sA.b, sB.b)
                ]
                var bestPair: (SIMD2<Float>, SIMD2<Float>, Float)? = nil
                for (p1, p2) in pairs {
                    let d = simd_distance(p1, p2)
                    guard d >= minGapPx && d <= maxGapPx else { continue }
                    let perp = abs(simd_dot(p2 - p1, normA))
                    guard perp <= 9.0 else { continue }
                    // Ensure gap points outward from both segments (not overlapping!)
                    let midGap = (p1 + p2) * 0.5
                    let dMidA = simd_distance(midGap, sA.mid)
                    let dMidB = simd_distance(midGap, sB.mid)
                    guard dMidA > sA.length * 0.45 && dMidB > sB.length * 0.45 else { continue }
                    if bestPair == nil || d < bestPair!.2 {
                        bestPair = (p1, p2, d)
                    }
                }
                guard let (p1, p2, gapLen) = bestPair else { continue }
                
                // Sample chord center line & quarter-circle door swing arcs in original foreground ink
                let chordDir = (p2 - p1) / gapLen
                let chordNorm = SIMD2<Float>(-chordDir.y, chordDir.x)
                
                var chordHits = 0
                for step in 2...8 {
                    let pt = p1 + chordDir * (gapLen * Float(step) / 10.0)
                    if inkAt(pt.x, pt.y) { chordHits += 1 }
                }
                
                var bestArcScore = 0
                var bestSwingSide: Float = 1.0
                for hinge in [p1, p2] {
                    let awayDir = (hinge == p1) ? chordDir : -chordDir
                    for sideSign: Float in [1.0, -1.0] {
                        let swingPerp = chordNorm * sideSign
                        var hits = 0
                        for k in 1...8 {
                            let theta = Float(k) * (.pi * 0.5) / 9.0
                            let arcPt = hinge + (awayDir * cos(theta) + swingPerp * sin(theta)) * (gapLen * 0.90)
                            if inkAt(arcPt.x, arcPt.y) { hits += 1 }
                        }
                        // Check leaf line perpendicular to wall from hinge as well
                        var leafHits = 0
                        for k in 2...7 {
                            let leafPt = hinge + swingPerp * (gapLen * Float(k) / 8.0)
                            if inkAt(leafPt.x, leafPt.y) { leafHits += 1 }
                        }
                        let combined = hits + leafHits
                        if combined > bestArcScore {
                            bestArcScore = combined
                            bestSwingSide = sideSign
                        }
                    }
                }
                
                let kind: PortalCandidateKind
                if bestArcScore >= 5 && gapLen <= 85.0 {
                    kind = .door(swingSide: bestSwingSide)
                } else if chordHits >= 4 {
                    kind = .window
                } else {
                    kind = .opening
                }
                
                // Avoid duplicate overlapping portal
                let midP = (p1 + p2) * 0.5
                if !portals.contains(where: { simd_distance($0.mid, midP) < 18.0 }) {
                    portals.append(PortalCandidatePx(a: p1, b: p2, kind: kind))
                }
            }
        }
        
        // Also scan along long perimeter walls for embedded light-filled CAD window sections
        for s in segments where s.length >= 90.0 && s.thicknessPx >= 6.0 {
            let dir = s.dir
            let steps = Int(s.length / 6.0)
            guard steps >= 10 else { continue }
            var brightRunStart: Int? = nil
            
            for k in 1..<(steps - 1) {
                let p = s.a + dir * (Float(k) * 6.0)
                let ix = min(max(Int(p.x.rounded()), 0), width - 1)
                let iy = min(max(Int(p.y.rounded()), 0), height - 1)
                let lum = pixels[iy * width + ix]
                let isGlazing = isLightBg ? (lum > 140) : (lum < 115)
                if isGlazing {
                    if brightRunStart == nil { brightRunStart = k }
                } else if let st = brightRunStart {
                    let runLenPx = Float(k - st) * 6.0
                    if runLenPx >= 24.0 && runLenPx <= min(s.length * 0.65, 160.0) {
                        let wStart = s.a + dir * (Float(st) * 6.0)
                        let wEnd = s.a + dir * (Float(k) * 6.0)
                        let midW = (wStart + wEnd) * 0.5
                        if !portals.contains(where: { simd_distance($0.mid, midW) < 22.0 }) {
                            portals.append(PortalCandidatePx(a: wStart, b: wEnd, kind: .window))
                        }
                    }
                    brightRunStart = nil
                }
            }
        }
        
        return portals
    }
    
    // MARK: - 7. Explicit & Unitless Dimension OCR Scale Inference
    
    private static func inferMetricScaleFromOCR(
        tokens: [OCRToken],
        walls: [RawWallSeg]
    ) -> (dimensions: [String], scaleMpp: Float?) {
        var recognizedDims: [String] = []
        var explicitEstimates: [Float] = []
        
        // Match explicit-unit tokens first
        for tok in tokens {
            if let meters = tok.explicitMeters {
                recognizedDims.append(tok.rawText)
                if let mpp = matchDimensionLabelToWall(meters: meters, token: tok, walls: walls) {
                    explicitEstimates.append(mpp)
                }
            }
        }
        
        if !explicitEstimates.isEmpty {
            explicitEstimates.sort()
            let med = explicitEstimates[explicitEstimates.count / 2]
            let filtered = explicitEstimates.filter { $0 >= med * 0.60 && $0 <= med * 1.65 }
            if !filtered.isEmpty {
                return (recognizedDims, filtered[filtered.count / 2])
            }
        }
        
        // Infer scale from unitless architectural dimensions (e.g. "4.20", "385", "4200")
        let bareNums = tokens.compactMap { t -> (OCRToken, Float, Bool)? in
            guard let n = t.bareNumber else { return nil }
            return (t, n, t.hasDecimal)
        }
        guard !bareNums.isEmpty else { return (recognizedDims, nil) }
        
        // Determine dominant unit multiplier for unitless numbers
        let decimalCount = bareNums.filter { $0.2 && $0.1 >= 0.8 && $0.1 <= 25.0 }.count
        let cmRangeCount = bareNums.filter { !$0.2 && $0.1 >= 80 && $0.1 <= 2500 }.count
        let mmRangeCount = bareNums.filter { !$0.2 && $0.1 >= 1000 && $0.1 <= 25000 }.count
        
        let divisor: Float
        if decimalCount >= max(cmRangeCount, mmRangeCount) && decimalCount > 0 {
            divisor = 1.0
        } else if mmRangeCount > cmRangeCount && mmRangeCount >= 2 {
            divisor = 1000.0
        } else if cmRangeCount >= 2 {
            divisor = 100.0
        } else if decimalCount > 0 {
            divisor = 1.0
        } else {
            return (recognizedDims, nil)
        }
        
        var unitlessEstimates: [Float] = []
        for (tok, num, isDec) in bareNums {
            let meters = isDec ? num : (num / divisor)
            guard meters >= 0.80 && meters <= 28.0 else { continue }
            recognizedDims.append(tok.rawText)
            if let mpp = matchDimensionLabelToWall(meters: meters, token: tok, walls: walls) {
                unitlessEstimates.append(mpp)
            }
        }
        
        guard !unitlessEstimates.isEmpty else { return (recognizedDims, nil) }
        unitlessEstimates.sort()
        let med = unitlessEstimates[unitlessEstimates.count / 2]
        let consistent = unitlessEstimates.filter { $0 >= med * 0.65 && $0 <= med * 1.55 }
        return (recognizedDims, consistent.isEmpty ? med : consistent[consistent.count / 2])
    }
    
    private static func matchDimensionLabelToWall(meters: Float, token: OCRToken, walls: [RawWallSeg]) -> Float? {
        let tc = SIMD2<Float>(Float(token.boxPx.midX), Float(token.boxPx.midY))
        let textHoriz = token.boxPx.width >= token.boxPx.height
        
        var bestSeg: RawWallSeg? = nil
        var bestScore: Float = 0.0
        for seg in walls {
            let len = seg.length
            guard len > 45.0 else { continue }
            let segHoriz = abs(seg.b.x - seg.a.x) >= abs(seg.b.y - seg.a.y)
            guard segHoriz == textHoriz else { continue }
            
            let dir = seg.dir
            let rel = tc - seg.mid
            let along = abs(simd_dot(rel, dir))
            let perp = abs(rel.x * (-dir.y) + rel.y * dir.x)
            // Label must sit beside the wall (perp < 95px) and roughly within its longitudinal span
            guard perp < 95.0 && along <= len * 0.55 + 24.0 else { continue }
            let score = len - perp * 0.65
            if score > bestScore {
                bestScore = score
                bestSeg = seg
            }
        }
        if let matched = bestSeg {
            let mpp = meters / matched.length
            if mpp > 0.0015 && mpp < 0.14 {
                return mpp
            }
        }
        return nil
    }
    
    private static func parseExplicitMeters(text: String) -> Float? {
        let clean = text.lowercased().replacingOccurrences(of: ",", with: ".")
        if clean.contains(":") { return nil } // Ignore scale ratios like 1:100
        
        if let range = clean.range(of: #"(\d+\.?\d*)\s*(m|meter|meters)\b"#, options: .regularExpression) {
            let numStr = clean[range].replacingOccurrences(of: "meters", with: "").replacingOccurrences(of: "meter", with: "").replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Float(numStr), val >= 0.7 && val <= 35.0 { return val }
        }
        if let range = clean.range(of: #"(\d{3,5})\s*mm\b"#, options: .regularExpression) {
            let numStr = clean[range].replacingOccurrences(of: "mm", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Float(numStr), val >= 600 && val <= 35000 { return val / 1000.0 }
        }
        if let range = clean.range(of: #"(\d{2,4})\s*cm\b"#, options: .regularExpression) {
            let numStr = clean[range].replacingOccurrences(of: "cm", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Float(numStr), val >= 60 && val <= 3500 { return val / 100.0 }
        }
        if let regex = try? NSRegularExpression(pattern: #"(\d+)\s*'\s*[- ]?\s*(\d+)"#),
           let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
           match.numberOfRanges >= 3 {
            let ns = clean as NSString
            if let ft = Float(ns.substring(with: match.range(at: 1))),
               let inch = Float(ns.substring(with: match.range(at: 2))) {
                let totalM = (ft * 12.0 + inch) * 0.0254
                if totalM >= 0.7 && totalM <= 35.0 { return totalM }
            }
        }
        if let range = clean.range(of: #"(\d+\.?\d*)\s*(ft|')"#, options: .regularExpression) {
            let numStr = clean[range].replacingOccurrences(of: "ft", with: "").replacingOccurrences(of: "'", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Float(numStr), val >= 2.5 && val <= 115.0 { return val * 0.3048 }
        }
        return nil
    }
    
    private static func parseBareDimensionNumber(text: String) -> (Float?, Bool) {
        let clean = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if clean.contains(":") || clean.contains("x") || clean.contains("/") { return (nil, false) }
        // Accept strict standalone numbers like "4.20", "12.5", "385", "4200"
        guard let regex = try? NSRegularExpression(pattern: #"^(\d+(?:\.\d{1,2})?)$"#),
              regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)) != nil,
              let val = Float(clean) else {
            return (nil, false)
        }
        let hasDecimal = clean.contains(".")
        if hasDecimal && val >= 0.8 && val <= 30.0 {
            return (val, true)
        }
        if !hasDecimal && val >= 80 && val <= 30000 {
            return (val, false)
        }
        return (nil, false)
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
            let rotMat = yRotationTransform(angle: l.angle, x: mx, y: h * 0.5, z: mz)
            walls.append(WallSurface(id: UUID(), dimensions: SIMD3<Float>(l.length, h, 0.15), transform: rotMat))
        }
        
        return VectorizedPlanResult(
            vectorLines: lines,
            walls: walls,
            doors: [],
            windows: [],
            openings: [],
            originalWidthMeters: w,
            originalDepthMeters: d,
            recognizedDimensions: [],
            detectedScaleMetersPerPixel: w / 1024.0,
            usedHeuristicScale: true
        )
    }
}
