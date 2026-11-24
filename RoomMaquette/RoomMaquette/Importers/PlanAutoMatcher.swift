import Foundation
import simd

public class PlanAutoMatcher {
    
    private struct WallSeg2D {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var dir: SIMD2<Float>
        var normal: SIMD2<Float>
        var offset: Float   // dot(a, normal)
        var length: Float
        var mid: SIMD2<Float>
    }
    
    /// Automatically aligns a (potentially incomplete) LiDAR scan to an imported architectural floor plan.
    /// Uses continuous wall-angle matching, 2-wall corner intersections, directional Chamfer scoring, and local ICP refinement.
    public static func match(scan: MaquetteRoom, plan: ImportedPlan) -> PlanAlignmentTransform {
        let scanWalls = scan.walls
        guard !scanWalls.isEmpty else {
            return PlanAlignmentTransform(offsetX: 0, offsetZ: 0, rotationAngle: 0, scale: 1.0, confidence: 0.5)
        }
        
        let planLines = plan.vectorLines.filter { $0.length >= 0.40 }
        if !planLines.isEmpty {
            return matchGeometric(scan: scan, planLines: planLines, plan: plan)
        }
        
        return matchBoundingBox(scan: scan, plan: plan)
    }
    
    // MARK: - Geometric Wall-Pair & Corner Matching
    
    private static func matchGeometric(scan: MaquetteRoom, planLines: [PlanLine], plan: ImportedPlan) -> PlanAlignmentTransform {
        let scanSegs: [WallSeg2D] = scan.walls.compactMap { wall in
            let s = wall.startPoint2D
            let e = wall.endPoint2D
            return makeSeg(SIMD2<Float>(Float(s.x), Float(s.y)), SIMD2<Float>(Float(e.x), Float(e.y)))
        }.sorted { $0.length > $1.length }
        
        let planSegs: [WallSeg2D] = planLines.compactMap { line in
            makeSeg(SIMD2<Float>(line.startX, line.startZ), SIMD2<Float>(line.endX, line.endZ))
        }.sorted { $0.length > $1.length }
        
        guard !scanSegs.isEmpty, !planSegs.isEmpty else {
            return matchBoundingBox(scan: scan, plan: plan)
        }
        
        // Sample scan wall points with tangent vectors
        var scanSamples: [(pos: SIMD2<Float>, dir: SIMD2<Float>, weight: Float)] = []
        for seg in scanSegs {
            let steps = max(Int(seg.length / 0.30), 2)
            for step in 0...steps {
                let t = Float(step) / Float(steps)
                let p = seg.a * (1.0 - t) + seg.b * t
                scanSamples.append((pos: p, dir: seg.dir, weight: 1.0))
            }
        }
        
        // Plan bounds
        var minX: Float = .greatestFiniteMagnitude, maxX: Float = -.greatestFiniteMagnitude
        var minZ: Float = .greatestFiniteMagnitude, maxZ: Float = -.greatestFiniteMagnitude
        for seg in planSegs {
            minX = min(minX, seg.a.x, seg.b.x)
            maxX = max(maxX, seg.a.x, seg.b.x)
            minZ = min(minZ, seg.a.y, seg.b.y)
            maxZ = max(maxZ, seg.a.y, seg.b.y)
        }
        
        let sb = scan.boundingBox
        let scanCenter = SIMD2<Float>((sb.min.x + sb.max.x) * 0.5, (sb.min.z + sb.max.z) * 0.5)
        
        // 1. Collect dominant continuous rotation candidates aligning major scan walls to major plan walls
        var candidateAngles: [Float] = [0.0, .pi * 0.5, .pi, -.pi * 0.5]
        let topScanSegs = Array(scanSegs.prefix(4))
        let topPlanSegs = Array(planSegs.prefix(12))
        
        for sSeg in topScanSegs {
            let sAng = atan2(sSeg.dir.y, sSeg.dir.x)
            for pSeg in topPlanSegs {
                let pAng = atan2(pSeg.dir.y, pSeg.dir.x)
                for delta in [normalizeAngle(pAng - sAng), normalizeAngle(pAng + .pi - sAng)] {
                    if !candidateAngles.contains(where: { abs(normalizeAngle($0 - delta)) < (4.0 * .pi / 180.0) }) {
                        candidateAngles.append(delta)
                    }
                }
            }
        }
        
        struct ScoredHyp {
            var tx: Float
            var tz: Float
            var rot: Float
            var score: Float
        }
        var topHypotheses: [ScoredHyp] = []
        
        let totalWeight = max(scanSamples.reduce(Float(0)) { $0 + $1.weight }, 1.0)
        
        // 2. For each candidate rotation, solve exact corner intersections & wall-segment alignments
        for rot in candidateAngles {
            let c = cos(rot)
            let s = sin(rot)
            func rotVec(_ v: SIMD2<Float>) -> SIMD2<Float> {
                SIMD2<Float>(v.x * c - v.y * s, v.x * s + v.y * c)
            }
            
            let rotScanSegs = topScanSegs.map { seg -> WallSeg2D in
                makeSeg(rotVec(seg.a), rotVec(seg.b))!
            }
            let rotSamples = scanSamples.map { (pos: rotVec($0.pos), dir: rotVec($0.dir), weight: $0.weight) }
            let rotScanCenter = rotVec(scanCenter)
            
            var transCandidates: [SIMD2<Float>] = []
            
            // A. Corner 2x2 line intersections between top scan walls and compatible plan walls
            if rotScanSegs.count >= 2 {
                for i in 0..<min(rotScanSegs.count, 3) {
                    let sA = rotScanSegs[i]
                    for j in (i + 1)..<min(rotScanSegs.count, 4) {
                        let sB = rotScanSegs[j]
                        guard abs(sA.normal.x * sB.normal.y - sA.normal.y * sB.normal.x) > 0.35 else { continue }
                        
                        let compatA = planSegs.filter { abs(simd_dot(sA.normal, $0.normal)) > 0.90 }
                        let compatB = planSegs.filter { abs(simd_dot(sB.normal, $0.normal)) > 0.90 }
                        
                        for pA in compatA.prefix(12) {
                            let signA: Float = simd_dot(sA.normal, pA.normal) >= 0 ? 1.0 : -1.0
                            let nA = pA.normal * signA
                            let dA = pA.offset * signA
                            let rhsA = dA - simd_dot(sA.mid, nA)
                            
                            for pB in compatB.prefix(12) where pB.a != pA.a || pB.b != pA.b {
                                let signB: Float = simd_dot(sB.normal, pB.normal) >= 0 ? 1.0 : -1.0
                                let nB = pB.normal * signB
                                let dB = pB.offset * signB
                                let rhsB = dB - simd_dot(sB.mid, nB)
                                
                                let det = nA.x * nB.y - nA.y * nB.x
                                guard abs(det) > 0.35 else { continue }
                                let tx = (rhsA * nB.y - rhsB * nA.y) / det
                                let tz = (nA.x * rhsB - nB.x * rhsA) / det
                                
                                let cWorld = rotScanCenter + SIMD2<Float>(tx, tz)
                                if cWorld.x >= minX - 1.5 && cWorld.x <= maxX + 1.5 &&
                                   cWorld.y >= minZ - 1.5 && cWorld.y <= maxZ + 1.5 {
                                    transCandidates.append(SIMD2<Float>(tx, tz))
                                }
                            }
                        }
                    }
                }
            }
            
            // B. Direct wall-to-wall midpoint & endpoint sliding alignments for longest 2 walls
            for sSeg in rotScanSegs.prefix(2) {
                let compat = planSegs.filter { abs(simd_dot(sSeg.normal, $0.normal)) > 0.90 }
                for pSeg in compat.prefix(12) {
                    let sign: Float = simd_dot(sSeg.normal, pSeg.normal) >= 0 ? 1.0 : -1.0
                    let n = pSeg.normal * sign
                    let d = pSeg.offset * sign
                    let perpShift = d - simd_dot(sSeg.mid, n)
                    let tanVec = pSeg.dir
                    
                    // Midpoint, start-aligned, end-aligned
                    let anchors: [SIMD2<Float>] = [
                        pSeg.mid,
                        pSeg.a + tanVec * (sSeg.length * 0.5),
                        pSeg.b - tanVec * (sSeg.length * 0.5)
                    ]
                    for targetMid in anchors {
                        let alongShift = simd_dot(targetMid - sSeg.mid, tanVec)
                        let tr = n * perpShift + tanVec * alongShift
                        let cWorld = rotScanCenter + tr
                        if cWorld.x >= minX - 1.5 && cWorld.x <= maxX + 1.5 &&
                           cWorld.y >= minZ - 1.5 && cWorld.y <= maxZ + 1.5 {
                            transCandidates.append(tr)
                        }
                    }
                }
            }
            
            // Deduplicate translations within 0.16m
            var uniqueTrans: [SIMD2<Float>] = []
            for t in transCandidates {
                if !uniqueTrans.contains(where: { simd_distance($0, t) < 0.16 }) {
                    uniqueTrans.append(t)
                }
            }
            
            for tr in uniqueTrans {
                let score = evaluateAlignmentScore(
                    rotSamples: rotSamples,
                    tx: tr.x,
                    tz: tr.y,
                    planSegs: planSegs,
                    scanCenterWorld: rotScanCenter + tr,
                    planBounds: (minX, maxX, minZ, maxZ)
                )
                
                if topHypotheses.count < 4 || score > (topHypotheses.last?.score ?? -1) {
                    topHypotheses.append(ScoredHyp(tx: tr.x, tz: tr.y, rot: rot, score: score))
                    topHypotheses.sort { $0.score > $1.score }
                    if topHypotheses.count > 4 {
                        topHypotheses.removeLast()
                    }
                }
            }
        }
        
        guard var best = topHypotheses.first else {
            return matchBoundingBox(scan: scan, plan: plan)
        }
        
        // 3. Local ICP / Coordinate-Descent Refinement across top hypotheses
        for var hyp in topHypotheses {
            var stepT: Float = 0.08
            var stepR: Float = 2.0 * .pi / 180.0
            
            for _ in 0..<4 {
                var improved = true
                var iter = 0
                while improved && iter < 8 {
                    improved = false
                    iter += 1
                    let moves: [(Float, Float, Float)] = [
                        (stepT, 0, 0), (-stepT, 0, 0),
                        (0, stepT, 0), (0, -stepT, 0),
                        (0, 0, stepR), (0, 0, -stepR)
                    ]
                    for (dx, dz, dr) in moves {
                        let candTx = hyp.tx + dx
                        let candTz = hyp.tz + dz
                        let candRot = hyp.rot + dr
                        let sScore = scoreRawPose(
                            scanSamples: scanSamples,
                            scanCenter: scanCenter,
                            tx: candTx,
                            tz: candTz,
                            rot: candRot,
                            planSegs: planSegs,
                            planBounds: (minX, maxX, minZ, maxZ)
                        )
                        if sScore > hyp.score + 1e-4 {
                            hyp = ScoredHyp(tx: candTx, tz: candTz, rot: candRot, score: sScore)
                            improved = true
                        }
                    }
                }
                stepT *= 0.5
                stepR *= 0.5
            }
            
            if hyp.score > best.score {
                best = hyp
            }
        }
        
        let confidence = max(0.0, min(best.score / totalWeight, 1.0))
        return PlanAlignmentTransform(
            offsetX: best.tx,
            offsetZ: best.tz,
            rotationAngle: normalizeAngle(best.rot),
            scale: 1.0,
            confidence: confidence
        )
    }
    
    private static func scoreRawPose(
        scanSamples: [(pos: SIMD2<Float>, dir: SIMD2<Float>, weight: Float)],
        scanCenter: SIMD2<Float>,
        tx: Float,
        tz: Float,
        rot: Float,
        planSegs: [WallSeg2D],
        planBounds: (Float, Float, Float, Float)
    ) -> Float {
        let c = cos(rot)
        let s = sin(rot)
        let rotSamples = scanSamples.map { item in
            (
                pos: SIMD2<Float>(item.pos.x * c - item.pos.y * s, item.pos.x * s + item.pos.y * c),
                dir: SIMD2<Float>(item.dir.x * c - item.dir.y * s, item.dir.x * s + item.dir.y * c),
                weight: item.weight
            )
        }
        let rCenter = SIMD2<Float>(scanCenter.x * c - scanCenter.y * s + tx, scanCenter.x * s + scanCenter.y * c + tz)
        return evaluateAlignmentScore(
            rotSamples: rotSamples,
            tx: tx,
            tz: tz,
            planSegs: planSegs,
            scanCenterWorld: rCenter,
            planBounds: planBounds
        )
    }
    
    private static func evaluateAlignmentScore(
        rotSamples: [(pos: SIMD2<Float>, dir: SIMD2<Float>, weight: Float)],
        tx: Float,
        tz: Float,
        planSegs: [WallSeg2D],
        scanCenterWorld: SIMD2<Float>,
        planBounds: (Float, Float, Float, Float)
    ) -> Float {
        var score: Float = 0.0
        for sample in rotSamples {
            let wp = SIMD2<Float>(sample.pos.x + tx, sample.pos.y + tz)
            var minDistSqAligned: Float = .greatestFiniteMagnitude
            var minDistSqAny: Float = .greatestFiniteMagnitude
            
            for seg in planSegs {
                let dSq = pointToSegmentDistanceSquared(p: wp, a: seg.a, b: seg.b)
                minDistSqAny = min(minDistSqAny, dSq)
                if abs(simd_dot(sample.dir, seg.dir)) > 0.90 {
                    minDistSqAligned = min(minDistSqAligned, dSq)
                }
            }
            
            // Strongly prefer aligned wall directions; small fallback if perpendicular
            let alignedTerm = 1.0 / (1.0 + minDistSqAligned / 0.04) // 20cm half-height
            let fallbackTerm = 0.20 / (1.0 + minDistSqAny / 0.04)
            score += sample.weight * max(alignedTerm, fallbackTerm)
        }
        
        // Mild containment bonus if scan center lands cleanly inside plan envelope
        if scanCenterWorld.x >= planBounds.0 && scanCenterWorld.x <= planBounds.1 &&
           scanCenterWorld.y >= planBounds.2 && scanCenterWorld.y <= planBounds.3 {
            score += 1.5
        }
        return score
    }
    
    // MARK: - Architectural Bounding Box Matching (Fallback)
    
    private static func matchBoundingBox(scan: MaquetteRoom, plan: ImportedPlan) -> PlanAlignmentTransform {
        let sb = scan.boundingBox
        let scanWidth = max(sb.max.x - sb.min.x, 1.0)
        let scanDepth = max(sb.max.z - sb.min.z, 1.0)
        let scanCenter = (sb.min + sb.max) / 2.0
        
        let planWidth = max(plan.originalWidthMeters, 2.0)
        let planDepth = max(plan.originalDepthMeters, 2.0)
        
        let ratioScan = scanWidth / scanDepth
        let ratioPlan = planWidth / planDepth
        
        var rot: Float = 0.0
        if (ratioScan > 1.0 && ratioPlan < 1.0) || (ratioScan < 1.0 && ratioPlan > 1.0) {
            rot = .pi / 2.0
        }
        
        let c = cos(rot)
        let s = sin(rot)
        let rotCenterX = scanCenter.x * c - scanCenter.z * s
        let rotCenterZ = scanCenter.x * s + scanCenter.z * c
        
        return PlanAlignmentTransform(
            offsetX: -rotCenterX,
            offsetZ: -rotCenterZ,
            rotationAngle: rot,
            scale: 1.0,
            confidence: 0.65
        )
    }
    
    // MARK: - Helpers
    
    private static func makeSeg(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> WallSeg2D? {
        let d = b - a
        let len = simd_length(d)
        guard len >= 0.30 else { return nil }
        let dir = d / len
        let normal = SIMD2<Float>(-dir.y, dir.x)
        return WallSeg2D(
            a: a,
            b: b,
            dir: dir,
            normal: normal,
            offset: simd_dot(a, normal),
            length: len,
            mid: (a + b) * 0.5
        )
    }
    
    private static func normalizeAngle(_ a: Float) -> Float {
        var r = a.truncatingRemainder(dividingBy: 2.0 * .pi)
        if r > .pi { r -= 2.0 * .pi }
        if r < -.pi { r += 2.0 * .pi }
        return r
    }
    
    private static func pointToSegmentDistanceSquared(p: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> Float {
        let ab = b - a
        let ap = p - a
        let abLenSq = simd_dot(ab, ab)
        if abLenSq < 1e-6 {
            return simd_distance_squared(p, a)
        }
        let t = max(0.0, min(1.0, simd_dot(ap, ab) / abLenSq))
        let proj = a + ab * t
        return simd_distance_squared(p, proj)
    }
}
