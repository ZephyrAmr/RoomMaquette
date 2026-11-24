import Foundation
import simd

public struct BuildingLevel: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var elevation: Float // meters from ground
    public var roomIds: [UUID]
    
    public init(id: UUID = UUID(), name: String = "Ground Floor", elevation: Float = 0.0, roomIds: [UUID] = []) {
        self.id = id
        self.name = name
        self.elevation = elevation
        self.roomIds = roomIds
    }
}

public struct MaquetteBuilding: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var address: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var levels: [BuildingLevel]
    public var rooms: [MaquetteRoom]
    
    public init(
        id: UUID = UUID(),
        name: String = "Building Maquette",
        address: String = "Project Site",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        levels: [BuildingLevel] = [],
        rooms: [MaquetteRoom] = []
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.levels = levels.isEmpty ? [BuildingLevel(name: "Level 1", elevation: 0.0, roomIds: rooms.map { $0.id })] : levels
        self.rooms = rooms
    }
    
    public var totalFloorAreaSquareMeters: Float {
        rooms.reduce(0) { $0 + $1.floorAreaSquareMeters }
    }
    
    public var totalFloorAreaSquareFeet: Float {
        totalFloorAreaSquareMeters * 10.7639
    }
    
    public var totalRoomCount: Int {
        rooms.count
    }
    
    public var totalObjectCount: Int {
        rooms.reduce(0) { $0 + $1.objects.count }
    }
}
