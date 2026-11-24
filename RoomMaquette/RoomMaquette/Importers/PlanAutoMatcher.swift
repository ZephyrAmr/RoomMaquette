import Foundation
import simd

public class PlanAutoMatcher {
    
    /// Automatically aligns a (potentially incomplete) LiDAR scan to an imported architectural floor plan.
    public static func match(scan: MaquetteRoom, plan: ImportedPlan) -> PlanAlignmentTransform {
        let scanWalls = scan.walls
        guard !scanWalls.isEmpty else {
            // Default center alignment if scan has no walls
            return PlanAlignmentTransform(
                offsetX: 0,
                offsetZ: 0,
                rotationAngle: 0,
                scale: 1.0,
                confidence: 0.5
            )
        }
        
        let planLines = plan.vectorLines
        
        // If vector CAD lines are available, perform robust geometric ICP / Chamfer matching
        if !planLines.isEmpty {
            return matchGeometric(scanWalls: scanWalls, planLines: planLines, plan: plan)
        }
        
        // Otherwise perform architectural bounding box & dominant axis alignment
        return matchBoundingBox(scan: scan, plan: plan)
    }
    
    // MARK: - Geometric Chamfer Matching (Vector CAD / DXF)
    
    private static func matchGeometric(scanWalls: [WallSurface], planLines: [PlanLine], plan: ImportedPlan) -> PlanAlignmentTransform {
        // Sample points along scan walls (1 point every 0.35m)
        var scanPoints: [SIMD2<Float>] = []
        for wall in scanWalls {
            let s = wall.startPoint2D
            let e = wall.endPoint2D
            let p1 = SIMD2<Float>(Float(s.x), Float(s.y))
            let p2 = SIMD2<Float>(Float(e.x), Float(e.y))
            let len = simd_distance(p1, p2)
            let steps = max(Int(len / 0.35), 2)
            for step in 0...steps {
                let t = Float(step) / Float(steps)
                scanPoints.append(p1 * (1.0 - t) + p2 * t)
            }
        }
        
        // Plan bounds
        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        var minZ: Float = .greatestFiniteMagnitude
        var maxZ: Float = -.greatestFiniteMagnitude
        for line in planLines {
            minX = min(minX, line.startX, line.endX)
            maxX = max(maxX, line.startX, line.endX)
            minZ = min(minZ, line.startZ, line.endZ)
            maxZ = max(maxZ, line.startZ, line.endZ)
        }
        
        // Candidate rotations (0°, 90°, 180°, 270°)
        let candidateRotations: [Float] = [0.0, .pi / 2.0, .pi, 3.0 * .pi / 2.0]
        
        var bestScore: Float = -1.0
        var bestTransform = PlanAlignmentTransform()
        
        // Grid search step
        let stepX = max((maxX - minX) / 12.0, 0.5)
        let stepZ = max((maxZ - minZ) / 12.0, 0.5)
        
        for rot in candidateRotations {
            let cosA = cos(rot)
            let sinA = sin(rot)
            
            // Rotate scan points
            let rotatedPoints = scanPoints.map { p in
                SIMD2<Float>(p.x * cosA - p.y * sinA, p.x * sinA + p.y * cosA)
            }
            
            // Search translation offsets across the plan area
            var tx = minX
            while tx <= maxX {
                var tz = minZ
                while tz <= maxZ {
                    var score: Float = 0.0
                    
                    for pt in rotatedPoints {
                        let worldPt = SIMD2<Float>(pt.x + tx, pt.y + tz)
                        var minDistSq: Float = .greatestFiniteMagnitude
                        
                        // Minimum distance to nearest plan line segment
                        for line in planLines {
                            let distSq = pointToSegmentDistanceSquared(
                                p: worldPt,
                                a: SIMD2<Float>(line.startX, line.startZ),
                                b: SIMD2<Float>(line.endX, line.endZ)
                            )
                            minDistSq = min(minDistSq, distSq)
                        }
                        
                        // Cauchy kernel: rewards close points strongly, robust to outliers (incomplete scan)
                        score += 1.0 / (1.0 + minDistSq * 16.0)
                    }
                    
                    if score > bestScore {
                        bestScore = score
                        let normalizedConfidence = min(score / Float(scanPoints.count), 1.0)
                        bestTransform = PlanAlignmentTransform(
                            offsetX: tx,
                            offsetZ: tz,
                            rotationAngle: rot,
                            scale: 1.0,
                            confidence: normalizedConfidence
                        )
                    }
                    
                    tz += stepZ
                }
                tx += stepX
            }
        }
        
        return bestTransform
    }
    
    // MARK: - Architectural Bounding Box Matching (Image / PDF Blueprint)
    
    private static func matchBoundingBox(scan: MaquetteRoom, plan: ImportedPlan) -> PlanAlignmentTransform {
        let sb = scan.boundingBox
        let scanWidth = max(sb.max.x - sb.min.x, 1.0)
        let scanDepth = max(sb.max.z - sb.min.z, 1.0)
        let scanCenter = (sb.min + sb.max) / 2.0
        
        // Plan center
        let planWidth = max(plan.originalWidthMeters, 2.0)
        let planDepth = max(plan.originalDepthMeters, 2.0)
        
        // Check if aspect ratio matches better rotated 90 degrees
        let ratioScan = scanWidth / scanDepth
        let ratioPlan = planWidth / planDepth
        
        var rot: Float = 0.0
        if (ratioScan > 1.0 && ratioPlan < 1.0) || (ratioScan < 1.0 && ratioPlan > 1.0) {
            rot = .pi / 2.0
        }
        
        let offsetX = -scanCenter.x
        let offsetZ = -scanCenter.z
        
        return PlanAlignmentTransform(
            offsetX: offsetX,
            offsetZ: offsetZ,
            rotationAngle: rot,
            scale: 1.0,
            confidence: 0.85
        )
    }
    
    // MARK: - Math Helpers
    
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
