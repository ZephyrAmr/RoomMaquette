import Foundation
import SwiftUI
import simd

public enum PlanFileType: String, Codable, CaseIterable {
    case image = "Image (PNG, JPEG, HEIC)"
    case pdf = "PDF Blueprint"
    case dxf = "CAD Drawing (DXF)"
    case svg = "Vector SVG"
    case json = "RoomPlan JSON"
    
    public var icon: String {
        switch self {
        case .image: return "photo.fill"
        case .pdf: return "doc.richtext.fill"
        case .dxf: return "ruler.fill"
        case .svg: return "scribble.variable"
        case .json: return "curlybraces"
        }
    }
}

public struct PlanLine: Codable, Equatable, Hashable {
    public var startX: Float
    public var startZ: Float
    public var endX: Float
    public var endZ: Float
    
    public init(startX: Float, startZ: Float, endX: Float, endZ: Float) {
        self.startX = startX
        self.startZ = startZ
        self.endX = endX
        self.endZ = endZ
    }
    
    public var length: Float {
        let dx = endX - startX
        let dz = endZ - startZ
        return sqrt(dx*dx + dz*dz)
    }
    
    public var angle: Float {
        atan2(endZ - startZ, endX - startX)
    }
}

public struct PlanAlignmentTransform: Codable, Equatable, Hashable {
    public var offsetX: Float = 0.0 // meters
    public var offsetZ: Float = 0.0 // meters
    public var rotationAngle: Float = 0.0 // radians
    public var scale: Float = 1.0 // scale multiplier
    public var confidence: Float = 1.0 // 0.0 to 1.0 match score
    
    public init(offsetX: Float = 0.0, offsetZ: Float = 0.0, rotationAngle: Float = 0.0, scale: Float = 1.0, confidence: Float = 1.0) {
        self.offsetX = offsetX
        self.offsetZ = offsetZ
        self.rotationAngle = rotationAngle
        self.scale = scale
        self.confidence = confidence
    }
    
    /// Maps a point in room/scan space (meters) into plan space
    public func mapScanToPlan(point: SIMD3<Float>) -> SIMD3<Float> {
        let cosA = cos(rotationAngle)
        let sinA = sin(rotationAngle)
        let scaledX = point.x * scale
        let scaledZ = point.z * scale
        let rotX = scaledX * cosA - scaledZ * sinA
        let rotZ = scaledX * sinA + scaledZ * cosA
        return SIMD3<Float>(rotX + offsetX, point.y, rotZ + offsetZ)
    }
    
    /// Inverts a point in plan space into room/scan space
    public func mapPlanToScan(point: SIMD3<Float>) -> SIMD3<Float> {
        let dx = point.x - offsetX
        let dz = point.z - offsetZ
        let cosA = cos(-rotationAngle)
        let sinA = sin(-rotationAngle)
        let unrotX = (dx * cosA - dz * sinA) / max(scale, 0.001)
        let unrotZ = (dx * sinA + dz * cosA) / max(scale, 0.001)
        return SIMD3<Float>(unrotX, point.y, unrotZ)
    }
}

public struct ImportedPlan: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var fileType: PlanFileType
    public var importedAt: Date
    public var originalWidthMeters: Float
    public var originalDepthMeters: Float
    
    // Rendered 2D raster bitmap data (JPEG or PNG) for quick blueprint rendering
    public var renderedImageData: Data?
    
    // Extracted vector lines for CAD/SVG/PDF
    public var vectorLines: [PlanLine]
    
    // Architectural openings & furniture extracted from imported plan (if detected)
    public var detectedDoors: [DoorSurface]?
    public var detectedWindows: [WindowSurface]?
    public var detectedOpenings: [OpeningSurface]?
    public var isHeuristicScale: Bool?
    
    // Scan-to-Plan alignment
    public var alignment: PlanAlignmentTransform
    
    // Raw source text or data if DXF or SVG
    public var sourceText: String?
    
    public init(
        id: UUID = UUID(),
        name: String = "Imported Floor Plan",
        fileType: PlanFileType = .image,
        importedAt: Date = Date(),
        originalWidthMeters: Float = 10.0,
        originalDepthMeters: Float = 10.0,
        renderedImageData: Data? = nil,
        vectorLines: [PlanLine] = [],
        detectedDoors: [DoorSurface]? = nil,
        detectedWindows: [WindowSurface]? = nil,
        detectedOpenings: [OpeningSurface]? = nil,
        isHeuristicScale: Bool? = nil,
        alignment: PlanAlignmentTransform = PlanAlignmentTransform(),
        sourceText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fileType = fileType
        self.importedAt = importedAt
        self.originalWidthMeters = originalWidthMeters
        self.originalDepthMeters = originalDepthMeters
        self.renderedImageData = renderedImageData
        self.vectorLines = vectorLines
        self.detectedDoors = detectedDoors
        self.detectedWindows = detectedWindows
        self.detectedOpenings = detectedOpenings
        self.isHeuristicScale = isHeuristicScale
        self.alignment = alignment
        self.sourceText = sourceText
    }
}
