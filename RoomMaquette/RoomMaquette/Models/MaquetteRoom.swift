import Foundation
import simd
import RoomPlan

public struct MaquetteRoom: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var notes: String
    
    public var walls: [WallSurface]
    public var doors: [DoorSurface]
    public var windows: [WindowSurface]
    public var openings: [OpeningSurface]
    public var objects: [FurnitureObject]
    
    // Cached USDZ data when captured via RoomPlan
    public var usdzData: Data?
    
    public init(
        id: UUID = UUID(),
        name: String = "Scanned Room",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        notes: String = "",
        walls: [WallSurface] = [],
        doors: [DoorSurface] = [],
        windows: [WindowSurface] = [],
        openings: [OpeningSurface] = [],
        objects: [FurnitureObject] = [],
        usdzData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.notes = notes
        self.walls = walls
        self.doors = doors
        self.windows = windows
        self.openings = openings
        self.objects = objects
        self.usdzData = usdzData
    }
    
    // MARK: - Initializer from Apple RoomPlan CapturedRoom
    @available(iOS 16.0, *)
    public init(from capturedRoom: CapturedRoom, name: String = "LiDAR Room Scan", usdzData: Data? = nil) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.notes = "Scanned with iPhone Pro LiDAR and RoomPlan"
        self.usdzData = usdzData
        
        // 1. Walls
        self.walls = capturedRoom.walls.map { wall in
            WallSurface(
                id: wall.identifier,
                dimensions: wall.dimensions,
                transform: wall.transform,
                confidence: wall.confidence == .high ? 1.0 : (wall.confidence == .medium ? 0.7 : 0.4)
            )
        }
        
        // 2. Doors
        self.doors = capturedRoom.doors.map { door in
            var isOpen = true
            if case let .door(open) = door.category {
                isOpen = open
            }
            var parentId: UUID? = nil
            if #available(iOS 17.0, *) {
                parentId = door.parentIdentifier
            }
            return DoorSurface(
                id: door.identifier,
                dimensions: door.dimensions,
                transform: door.transform,
                isOpen: isOpen,
                parentWallId: parentId
            )
        }
        
        // 3. Windows
        self.windows = capturedRoom.windows.map { window in
            var parentId: UUID? = nil
            if #available(iOS 17.0, *) {
                parentId = window.parentIdentifier
            }
            return WindowSurface(
                id: window.identifier,
                dimensions: window.dimensions,
                transform: window.transform,
                parentWallId: parentId
            )
        }
        
        // 4. Openings
        self.openings = capturedRoom.openings.map { opening in
            var parentId: UUID? = nil
            if #available(iOS 17.0, *) {
                parentId = opening.parentIdentifier
            }
            return OpeningSurface(
                id: opening.identifier,
                dimensions: opening.dimensions,
                transform: opening.transform,
                parentWallId: parentId
            )
        }
        
        // 5. Objects (Furniture & Fixtures)
        self.objects = capturedRoom.objects.map { obj in
            FurnitureObject(
                id: obj.identifier,
                category: ObjectCategory.from(roomPlanCategory: obj.category),
                dimensions: obj.dimensions,
                transform: obj.transform,
                confidence: obj.confidence == .high ? 1.0 : (obj.confidence == .medium ? 0.7 : 0.4)
            )
        }
    }
    
    // MARK: - Computed Spatial Bounds & Metrics
    
    public var boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>) {
        if walls.isEmpty && objects.isEmpty {
            return (SIMD3<Float>(-2, 0, -2), SIMD3<Float>(2, 2.5, 2))
        }
        
        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        var minY: Float = 0.0
        var maxY: Float = 2.4 // default ceiling height
        var minZ: Float = .greatestFiniteMagnitude
        var maxZ: Float = -.greatestFiniteMagnitude
        
        for wall in walls {
            let start = wall.startPoint2D
            let end = wall.endPoint2D
            minX = min(minX, Float(start.x), Float(end.x))
            maxX = max(maxX, Float(start.x), Float(end.x))
            minZ = min(minZ, Float(start.y), Float(end.y))
            maxZ = max(maxZ, Float(start.y), Float(end.y))
            maxY = max(maxY, wall.position.y + wall.height / 2.0)
            minY = min(minY, wall.position.y - wall.height / 2.0)
        }
        
        for obj in objects {
            let pos = obj.position
            let halfW = obj.width / 2.0
            let halfD = obj.depth / 2.0
            minX = min(minX, pos.x - halfW)
            maxX = max(maxX, pos.x + halfW)
            minZ = min(minZ, pos.z - halfD)
            maxZ = max(maxZ, pos.z + halfD)
            maxY = max(maxY, pos.y + obj.height / 2.0)
        }
        
        return (SIMD3<Float>(minX, minY, minZ), SIMD3<Float>(maxX, maxY, maxZ))
    }
    
    public var roomWidth: Float {
        let b = boundingBox
        return max(b.max.x - b.min.x, 1.0)
    }
    
    public var roomDepth: Float {
        let b = boundingBox
        return max(b.max.z - b.min.z, 1.0)
    }
    
    public var ceilingHeight: Float {
        let b = boundingBox
        return max(b.max.y - b.min.y, 2.4)
    }
    
    /// Estimated floor area in square meters (approximate via Shoelace formula or bounding hull)
    public var floorAreaSquareMeters: Float {
        guard walls.count >= 3 else {
            return roomWidth * roomDepth * 0.85
        }
        
        // Approximate area using wall center points
        var points: [CGPoint] = []
        for wall in walls {
            points.append(wall.startPoint2D)
            points.append(wall.endPoint2D)
        }
        
        // Convex hull / sorted radial points around centroid
        guard !points.isEmpty else { return roomWidth * roomDepth }
        
        let cx = points.map { $0.x }.reduce(0, +) / CGFloat(points.count)
        let cy = points.map { $0.y }.reduce(0, +) / CGFloat(points.count)
        
        let sorted = points.sorted {
            atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx)
        }
        
        // Shoelace formula
        var area: Double = 0
        let n = sorted.count
        for i in 0..<n {
            let j = (i + 1) % n
            area += Double(sorted[i].x * sorted[j].y)
            area -= Double(sorted[j].x * sorted[i].y)
        }
        let calculated = Float(abs(area) / 2.0)
        return max(calculated, roomWidth * roomDepth * 0.7)
    }
    
    public var floorAreaSquareFeet: Float {
        floorAreaSquareMeters * 10.7639
    }
    
    public var perimeterMeters: Float {
        walls.reduce(0) { $0 + $1.length }
    }
    
    public var volumeCubicMeters: Float {
        floorAreaSquareMeters * ceilingHeight
    }
    
    // MARK: - Formatted Strings
    
    public var formattedAreaMetric: String {
        String(format: "%.1f m²", floorAreaSquareMeters)
    }
    
    public var formattedAreaImperial: String {
        String(format: "%.0f sq ft", floorAreaSquareFeet)
    }
    
    public var formattedDimensions: String {
        String(format: "%.1fm × %.1fm × %.1fm", roomWidth, roomDepth, ceilingHeight)
    }
}
