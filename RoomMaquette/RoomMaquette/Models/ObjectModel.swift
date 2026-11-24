import Foundation
import SwiftUI
import simd
import RoomPlan

public enum ObjectCategory: String, Codable, CaseIterable {
    case sofa
    case chair
    case table
    case storage
    case bed
    case refrigerator
    case stove
    case oven
    case sink
    case washerDryer
    case toilet
    case bathtub
    case television
    case desk
    case plant
    case generic
    
    public var displayName: String {
        switch self {
        case .sofa: return "Sofa"
        case .chair: return "Chair"
        case .table: return "Table"
        case .storage: return "Storage / Cabinet"
        case .bed: return "Bed"
        case .refrigerator: return "Refrigerator"
        case .stove: return "Stove"
        case .oven: return "Oven"
        case .sink: return "Sink"
        case .washerDryer: return "Washer / Dryer"
        case .toilet: return "Toilet"
        case .bathtub: return "Bathtub"
        case .television: return "Television"
        case .desk: return "Desk"
        case .plant: return "Plant"
        case .generic: return "Object"
        }
    }
    
    public var systemIcon: String {
        switch self {
        case .sofa: return "sofa.fill"
        case .chair: return "chair.fill"
        case .table: return "table.furniture.fill"
        case .storage: return "cabinet.fill"
        case .bed: return "bed.double.fill"
        case .refrigerator: return "refrigerator.fill"
        case .stove, .oven: return "cooktop.fill"
        case .sink: return "sink.fill"
        case .washerDryer: return "washer.fill"
        case .toilet: return "toilet.fill"
        case .bathtub: return "bathtub.fill"
        case .television: return "tv.fill"
        case .desk: return "deskclock.fill"
        case .plant: return "leaf.fill"
        case .generic: return "cube.fill"
        }
    }
    
    public var accentColor: Color {
        switch self {
        case .sofa: return Color.orange
        case .chair: return Color.brown
        case .table: return Color.yellow
        case .storage: return Color.indigo
        case .bed: return Color.purple
        case .refrigerator, .washerDryer: return Color.cyan
        case .stove, .oven: return Color.red
        case .sink, .toilet, .bathtub: return Color.teal
        case .television: return Color.blue
        case .desk: return Color.mint
        case .plant: return Color.green
        case .generic: return Color.gray
        }
    }
    
    @available(iOS 16.0, *)
    public static func from(roomPlanCategory: CapturedRoom.Object.Category) -> ObjectCategory {
        switch roomPlanCategory {
        case .storage: return .storage
        case .refrigerator: return .refrigerator
        case .stove: return .stove
        case .bed: return .bed
        case .sink: return .sink
        case .washerDryer: return .washerDryer
        case .toilet: return .toilet
        case .bathtub: return .bathtub
        case .oven: return .oven
        case .table: return .table
        case .sofa: return .sofa
        case .chair: return .chair
        case .television: return .television
        @unknown default:
            return .generic
        }
    }
}

public struct FurnitureObject: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var category: ObjectCategory
    public var customName: String?
    public var dimensions: SIMD3<Float> // width (x), height (y), depth (z)
    public var transform: TransformMatrix
    public var confidence: Float
    
    public init(
        id: UUID = UUID(),
        category: ObjectCategory,
        customName: String? = nil,
        dimensions: SIMD3<Float>,
        transform: simd_float4x4,
        confidence: Float = 1.0
    ) {
        self.id = id
        self.category = category
        self.customName = customName
        self.dimensions = dimensions
        self.transform = TransformMatrix(transform)
        self.confidence = confidence
    }
    
    public var displayName: String {
        customName ?? category.displayName
    }
    
    public var width: Float { dimensions.x }
    public var height: Float { dimensions.y }
    public var depth: Float { dimensions.z }
    public var position: SIMD3<Float> { transform.position }
    public var rotationY: Float { transform.rotationY }
}
