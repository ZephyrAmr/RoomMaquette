import Foundation
import simd

public struct SampleRooms {
    
    /// Creates a transformation matrix given position (x, y, z) and Y-axis rotation in radians
    private static func makeTransform(x: Float, y: Float, z: Float, rotY: Float = 0) -> simd_float4x4 {
        let cosA = cos(rotY)
        let sinA = sin(rotY)
        
        let c0 = SIMD4<Float>(cosA, 0, sinA, 0)
        let c1 = SIMD4<Float>(0, 1, 0, 0)
        let c2 = SIMD4<Float>(-sinA, 0, cosA, 0)
        let c3 = SIMD4<Float>(x, y, z, 1)
        
        return simd_float4x4(c0, c1, c2, c3)
    }
    
    // MARK: - Modern Studio Apartment
    public static var modernStudio: MaquetteRoom {
        let roomWidth: Float = 6.0
        let roomDepth: Float = 4.8
        let wallHeight: Float = 2.6
        let wallThick: Float = 0.15
        
        // 4 outer walls
        let northWall = WallSurface(
            dimensions: SIMD3<Float>(roomWidth, wallHeight, wallThick),
            transform: makeTransform(x: 0, y: wallHeight/2, z: -roomDepth/2, rotY: 0)
        )
        let southWall = WallSurface(
            dimensions: SIMD3<Float>(roomWidth, wallHeight, wallThick),
            transform: makeTransform(x: 0, y: wallHeight/2, z: roomDepth/2, rotY: 0)
        )
        let westWall = WallSurface(
            dimensions: SIMD3<Float>(roomDepth, wallHeight, wallThick),
            transform: makeTransform(x: -roomWidth/2, y: wallHeight/2, z: 0, rotY: .pi / 2)
        )
        let eastWall = WallSurface(
            dimensions: SIMD3<Float>(roomDepth, wallHeight, wallThick),
            transform: makeTransform(x: roomWidth/2, y: wallHeight/2, z: 0, rotY: .pi / 2)
        )
        
        // Doors & Windows
        let entryDoor = DoorSurface(
            dimensions: SIMD3<Float>(0.9, 2.1, 0.08),
            transform: makeTransform(x: -1.8, y: 1.05, z: roomDepth/2, rotY: 0),
            isOpen: true
        )
        let balconyWindow = WindowSurface(
            dimensions: SIMD3<Float>(2.4, 1.8, 0.08),
            transform: makeTransform(x: 0.5, y: 1.4, z: -roomDepth/2, rotY: 0)
        )
        let sideWindow = WindowSurface(
            dimensions: SIMD3<Float>(1.2, 1.4, 0.08),
            transform: makeTransform(x: roomWidth/2, y: 1.5, z: -1.2, rotY: .pi / 2)
        )
        
        // Furniture
        let sofa = FurnitureObject(
            category: .sofa,
            customName: "3-Seater Sofa",
            dimensions: SIMD3<Float>(2.1, 0.85, 0.95),
            transform: makeTransform(x: -1.4, y: 0.42, z: -0.8, rotY: 0)
        )
        let coffeeTable = FurnitureObject(
            category: .table,
            customName: "Glass Coffee Table",
            dimensions: SIMD3<Float>(1.1, 0.42, 0.65),
            transform: makeTransform(x: -1.4, y: 0.21, z: 0.2, rotY: 0)
        )
        let tvUnit = FurnitureObject(
            category: .storage,
            customName: "Media Console",
            dimensions: SIMD3<Float>(1.8, 0.5, 0.45),
            transform: makeTransform(x: -1.4, y: 0.25, z: 1.5, rotY: 0)
        )
        let television = FurnitureObject(
            category: .television,
            customName: "65\" OLED TV",
            dimensions: SIMD3<Float>(1.45, 0.85, 0.1),
            transform: makeTransform(x: -1.4, y: 0.95, z: 1.5, rotY: 0)
        )
        let bed = FurnitureObject(
            category: .bed,
            customName: "Queen Bed",
            dimensions: SIMD3<Float>(1.6, 0.9, 2.05),
            transform: makeTransform(x: 1.9, y: 0.45, z: -1.2, rotY: 0)
        )
        let nightstand = FurnitureObject(
            category: .storage,
            customName: "Nightstand",
            dimensions: SIMD3<Float>(0.5, 0.55, 0.45),
            transform: makeTransform(x: 2.7, y: 0.27, z: -2.0, rotY: 0)
        )
        let diningTable = FurnitureObject(
            category: .table,
            customName: "Dining Table",
            dimensions: SIMD3<Float>(1.3, 0.76, 0.85),
            transform: makeTransform(x: 1.6, y: 0.38, z: 1.2, rotY: 0)
        )
        let chair1 = FurnitureObject(
            category: .chair,
            customName: "Dining Chair",
            dimensions: SIMD3<Float>(0.5, 0.82, 0.5),
            transform: makeTransform(x: 1.6, y: 0.41, z: 0.65, rotY: 0)
        )
        let chair2 = FurnitureObject(
            category: .chair,
            customName: "Dining Chair",
            dimensions: SIMD3<Float>(0.5, 0.82, 0.5),
            transform: makeTransform(x: 1.6, y: 0.41, z: 1.75, rotY: .pi)
        )
        let fridge = FurnitureObject(
            category: .refrigerator,
            customName: "Refrigerator",
            dimensions: SIMD3<Float>(0.75, 1.85, 0.72),
            transform: makeTransform(x: -2.5, y: 0.92, z: 1.8, rotY: -.pi/2)
        )
        
        return MaquetteRoom(
            name: "Modern Studio Apartment",
            notes: "High-ceiling loft with open-concept living, sleeping & dining zones.",
            walls: [northWall, southWall, westWall, eastWall],
            doors: [entryDoor],
            windows: [balconyWindow, sideWindow],
            openings: [],
            objects: [sofa, coffeeTable, tvUnit, television, bed, nightstand, diningTable, chair1, chair2, fridge]
        )
    }
    
    // MARK: - Executive Boardroom & Office
    public static var executiveOffice: MaquetteRoom {
        let roomWidth: Float = 7.0
        let roomDepth: Float = 5.2
        let wallHeight: Float = 2.8
        let wallThick: Float = 0.15
        
        let north = WallSurface(
            dimensions: SIMD3<Float>(roomWidth, wallHeight, wallThick),
            transform: makeTransform(x: 0, y: wallHeight/2, z: -roomDepth/2)
        )
        let south = WallSurface(
            dimensions: SIMD3<Float>(roomWidth, wallHeight, wallThick),
            transform: makeTransform(x: 0, y: wallHeight/2, z: roomDepth/2)
        )
        let west = WallSurface(
            dimensions: SIMD3<Float>(roomDepth, wallHeight, wallThick),
            transform: makeTransform(x: -roomWidth/2, y: wallHeight/2, z: 0, rotY: .pi / 2)
        )
        let east = WallSurface(
            dimensions: SIMD3<Float>(roomDepth, wallHeight, wallThick),
            transform: makeTransform(x: roomWidth/2, y: wallHeight/2, z: 0, rotY: .pi / 2)
        )
        
        let glassWindow = WindowSurface(
            dimensions: SIMD3<Float>(4.5, 2.2, 0.08),
            transform: makeTransform(x: 0, y: 1.4, z: -roomDepth/2)
        )
        let officeDoor = DoorSurface(
            dimensions: SIMD3<Float>(1.0, 2.2, 0.08),
            transform: makeTransform(x: 2.2, y: 1.1, z: roomDepth/2)
        )
        
        let confTable = FurnitureObject(
            category: .table,
            customName: "Conference Table",
            dimensions: SIMD3<Float>(3.2, 0.75, 1.2),
            transform: makeTransform(x: 0, y: 0.38, z: 0)
        )
        let credenza = FurnitureObject(
            category: .storage,
            customName: "Executive Credenza",
            dimensions: SIMD3<Float>(2.4, 0.8, 0.5),
            transform: makeTransform(x: 0, y: 0.4, z: 2.2)
        )
        let presentationDisplay = FurnitureObject(
            category: .television,
            customName: "85\" Presentation Display",
            dimensions: SIMD3<Float>(1.9, 1.1, 0.1),
            transform: makeTransform(x: -3.2, y: 1.6, z: 0, rotY: .pi/2)
        )
        
        var chairs: [FurnitureObject] = []
        for i in 0..<3 {
            let offset = Float(i - 1) * 0.95
            chairs.append(FurnitureObject(
                category: .chair,
                customName: "Executive Chair",
                dimensions: SIMD3<Float>(0.65, 0.95, 0.65),
                transform: makeTransform(x: offset, y: 0.47, z: -0.9)
            ))
            chairs.append(FurnitureObject(
                category: .chair,
                customName: "Executive Chair",
                dimensions: SIMD3<Float>(0.65, 0.95, 0.65),
                transform: makeTransform(x: offset, y: 0.47, z: 0.9, rotY: .pi)
            ))
        }
        
        return MaquetteRoom(
            name: "Executive Boardroom",
            notes: "Corporate meeting space with acoustic walls and video conferencing setup.",
            walls: [north, south, west, east],
            doors: [officeDoor],
            windows: [glassWindow],
            openings: [],
            objects: [confTable, credenza, presentationDisplay] + chairs
        )
    }
}
