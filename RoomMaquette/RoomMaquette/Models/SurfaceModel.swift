import Foundation
import CoreGraphics
import simd
import RoomPlan

// MARK: - Transform Matrix Codable Wrapper

public struct TransformMatrix: Codable, Equatable, Hashable {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    
    public init(_ matrix: simd_float4x4) {
        self.columns = (matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3)
    }
    
    public var matrix: simd_float4x4 {
        simd_float4x4(columns.0, columns.1, columns.2, columns.3)
    }
    
    public var position: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
    
    public var rotationY: Float {
        atan2(columns.0.z, columns.0.x)
    }
    
    // MARK: - Codable
    
    enum CodingKeys: String, CodingKey {
        case col0, col1, col2, col3
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let c0 = try container.decode([Float].self, forKey: .col0)
        let c1 = try container.decode([Float].self, forKey: .col1)
        let c2 = try container.decode([Float].self, forKey: .col2)
        let c3 = try container.decode([Float].self, forKey: .col3)
        
        self.columns = (
            SIMD4<Float>(c0[0], c0[1], c0[2], c0[3]),
            SIMD4<Float>(c1[0], c1[1], c1[2], c1[3]),
            SIMD4<Float>(c2[0], c2[1], c2[2], c2[3]),
            SIMD4<Float>(c3[0], c3[1], c3[2], c3[3])
        )
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([columns.0.x, columns.0.y, columns.0.z, columns.0.w], forKey: .col0)
        try container.encode([columns.1.x, columns.1.y, columns.1.z, columns.1.w], forKey: .col1)
        try container.encode([columns.2.x, columns.2.y, columns.2.z, columns.2.w], forKey: .col2)
        try container.encode([columns.3.x, columns.3.y, columns.3.z, columns.3.w], forKey: .col3)
    }
    
    public static func == (lhs: TransformMatrix, rhs: TransformMatrix) -> Bool {
        lhs.columns.0 == rhs.columns.0 &&
        lhs.columns.1 == rhs.columns.1 &&
        lhs.columns.2 == rhs.columns.2 &&
        lhs.columns.3 == rhs.columns.3
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(columns.3.x)
        hasher.combine(columns.3.y)
        hasher.combine(columns.3.z)
    }
}

// MARK: - Surface Types

public enum SurfaceCategory: String, Codable, CaseIterable {
    case wall
    case door
    case window
    case opening
    
    public var displayName: String {
        switch self {
        case .wall: return "Wall"
        case .door: return "Door"
        case .window: return "Window"
        case .opening: return "Opening"
        }
    }
    
    public var iconName: String {
        switch self {
        case .wall: return "square.split.diagonal.2x2"
        case .door: return "door.left.hand.open"
        case .window: return "window.vertical.closed"
        case .opening: return "rectangle.dashed"
        }
    }
}

public struct WallSurface: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var dimensions: SIMD3<Float> // width (x), height (y), thickness (z)
    public var transform: TransformMatrix
    public var confidence: Float
    
    public init(id: UUID = UUID(), dimensions: SIMD3<Float>, transform: simd_float4x4, confidence: Float = 1.0) {
        self.id = id
        self.dimensions = dimensions
        self.transform = TransformMatrix(transform)
        self.confidence = confidence
    }
    
    public var length: Float { dimensions.x }
    public var height: Float { dimensions.y }
    public var thickness: Float { max(dimensions.z, 0.10) } // Standard architectural wall thickness fallback
    
    public var position: SIMD3<Float> { transform.position }
    
    // Calculates start and end points in 2D top-down plane (x, z)
    public var startPoint2D: CGPoint {
        let halfLen = dimensions.x / 2.0
        let rotY = transform.rotationY
        let cosA = cos(rotY)
        let sinA = sin(rotY)
        let cx = position.x
        let cz = position.z
        return CGPoint(x: CGFloat(cx - halfLen * cosA), y: CGFloat(cz - halfLen * sinA))
    }
    
    public var endPoint2D: CGPoint {
        let halfLen = dimensions.x / 2.0
        let rotY = transform.rotationY
        let cosA = cos(rotY)
        let sinA = sin(rotY)
        let cx = position.x
        let cz = position.z
        return CGPoint(x: CGFloat(cx + halfLen * cosA), y: CGFloat(cz + halfLen * sinA))
    }
    
    public var displayName: String {
        let rot = transform.rotationY
        let deg = (Int(rot * 180.0 / .pi) % 360 + 360) % 360
        if deg >= 315 || deg < 45 {
            return "North Wall"
        } else if deg >= 45 && deg < 135 {
            return "East Wall"
        } else if deg >= 135 && deg < 225 {
            return "South Wall"
        } else {
            return "West Wall"
        }
    }
}

public struct DoorSurface: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var dimensions: SIMD3<Float> // width, height, thickness
    public var transform: TransformMatrix
    public var isOpen: Bool
    public var parentWallId: UUID?
    
    public init(id: UUID = UUID(), dimensions: SIMD3<Float>, transform: simd_float4x4, isOpen: Bool = true, parentWallId: UUID? = nil) {
        self.id = id
        self.dimensions = dimensions
        self.transform = TransformMatrix(transform)
        self.isOpen = isOpen
        self.parentWallId = parentWallId
    }
    
    public var width: Float { dimensions.x }
    public var height: Float { dimensions.y }
    public var position: SIMD3<Float> { transform.position }
}

public struct WindowSurface: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var dimensions: SIMD3<Float> // width, height, thickness
    public var transform: TransformMatrix
    public var parentWallId: UUID?
    
    public init(id: UUID = UUID(), dimensions: SIMD3<Float>, transform: simd_float4x4, parentWallId: UUID? = nil) {
        self.id = id
        self.dimensions = dimensions
        self.transform = TransformMatrix(transform)
        self.parentWallId = parentWallId
    }
    
    public var width: Float { dimensions.x }
    public var height: Float { dimensions.y }
    public var position: SIMD3<Float> { transform.position }
}

public struct OpeningSurface: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var dimensions: SIMD3<Float>
    public var transform: TransformMatrix
    public var parentWallId: UUID?
    
    public init(id: UUID = UUID(), dimensions: SIMD3<Float>, transform: simd_float4x4, parentWallId: UUID? = nil) {
        self.id = id
        self.dimensions = dimensions
        self.transform = TransformMatrix(transform)
        self.parentWallId = parentWallId
    }
    
    public var width: Float { dimensions.x }
    public var height: Float { dimensions.y }
    public var position: SIMD3<Float> { transform.position }
}
