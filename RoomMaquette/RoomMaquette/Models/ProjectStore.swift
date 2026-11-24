import Foundation
import Combine

public class ProjectStore: ObservableObject {
    @Published public var rooms: [MaquetteRoom] = []
    @Published public var selectedRoomId: UUID?
    
    private let fileManager = FileManager.default
    private var documentsFolder: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rooms", isDirectory: true)
    }
    
    public init() {
        createDirectoryIfNeeded()
        loadAllRooms()
        
        // If empty on first launch, seed sample rooms
        if rooms.isEmpty {
            saveRoom(SampleRooms.modernStudio)
            saveRoom(SampleRooms.executiveOffice)
        }
        
        if selectedRoomId == nil {
            selectedRoomId = rooms.first?.id
        }
    }
    
    private func createDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: documentsFolder.path) {
            try? fileManager.createDirectory(at: documentsFolder, withIntermediateDirectories: true)
        }
    }
    
    public func loadAllRooms() {
        guard let files = try? fileManager.contentsOfDirectory(at: documentsFolder, includingPropertiesForKeys: nil) else {
            return
        }
        
        var loaded: [MaquetteRoom] = []
        let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }
        
        for fileURL in jsonFiles {
            if let data = try? Data(contentsOf: fileURL),
               let room = try? JSONDecoder().decode(MaquetteRoom.self, from: data) {
                loaded.append(room)
            }
        }
        
        self.rooms = loaded.sorted { $0.modifiedAt > $1.modifiedAt }
    }
    
    public func saveRoom(_ room: MaquetteRoom) {
        var updated = room
        updated.modifiedAt = Date()
        
        if let idx = rooms.firstIndex(where: { $0.id == updated.id }) {
            rooms[idx] = updated
        } else {
            rooms.insert(updated, at: 0)
        }
        
        // Persist to disk
        let fileURL = documentsFolder.appendingPathComponent("\(updated.id.uuidString).json")
        if let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: fileURL)
        }
    }
    
    public func deleteRoom(at offsets: IndexSet) {
        for index in offsets {
            let room = rooms[index]
            let fileURL = documentsFolder.appendingPathComponent("\(room.id.uuidString).json")
            try? fileManager.removeItem(at: fileURL)
        }
        rooms.remove(atOffsets: offsets)
        if selectedRoomId != nil && !rooms.contains(where: { $0.id == selectedRoomId }) {
            selectedRoomId = rooms.first?.id
        }
    }
    
    public func deleteRoom(id: UUID) {
        if let idx = rooms.firstIndex(where: { $0.id == id }) {
            deleteRoom(at: IndexSet(integer: idx))
        }
    }
    
    public func duplicateRoom(_ room: MaquetteRoom) {
        var copy = room
        copy.id = UUID()
        copy.name = "\(room.name) (Copy)"
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        saveRoom(copy)
    }
}
