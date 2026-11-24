import Foundation
import SceneKit

public class USDZExporter {
    
    /// Exports the room as a USDZ file.
    /// If native RoomPlan USDZ data exists, uses it; otherwise generates from SceneKit.
    public static func export(room: MaquetteRoom, style: MaquetteStyle = .architecturalClay) throws -> URL {
        let fileName = "\(room.name.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).usdz"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        // Remove existing if any
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        // If native RoomPlan capture USDZ data is stored, write it
        if let rawUSDZ = room.usdzData, !rawUSDZ.isEmpty {
            try rawUSDZ.write(to: outputURL)
            return outputURL
        }
        
        // Otherwise generate high-quality USDZ from SceneKit maquette scene
        let scene = SceneKitMaquetteRenderer.buildScene(for: room, style: style, showCeiling: false)
        let success = scene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil)
        
        guard success else {
            throw NSError(domain: "USDZExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to write USDZ scene"])
        }
        
        return outputURL
    }
}
