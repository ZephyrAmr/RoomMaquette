import Foundation
import SceneKit
import SceneKit.ModelIO
import ModelIO

public class USDZExporter {
    
    /// Exports the room as a USDZ file.
    /// If native RoomPlan USDZ data exists, uses it; otherwise generates from SceneKit.
    public static func export(room: MaquetteRoom, style: MaquetteStyle = .architecturalClay) throws -> URL {
        let safeName = room.name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileName = "\(safeName)_\(room.id.uuidString).usdz"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        // Remove existing if any
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        // 1. If native RoomPlan capture USDZ data is stored, write and return it
        if let rawUSDZ = room.usdzData, !rawUSDZ.isEmpty {
            try rawUSDZ.write(to: outputURL, options: .atomic)
            if FileManager.default.fileExists(atPath: outputURL.path),
               (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 {
                return outputURL
            }
        }
        
        // 2. Otherwise generate high-quality USDZ from SceneKit maquette scene
        let scene = SceneKitMaquetteRenderer.buildScene(for: room, style: style, showCeiling: false)
        
        // Attempt export using MDLAsset for standard USDZ compliance
        let asset = MDLAsset(scnScene: scene)
        if MDLAsset.canExportFileExtension("usdz") {
            try asset.export(to: outputURL)
        } else {
            // Direct SceneKit fallback
            let written = scene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil)
            guard written else {
                throw NSError(domain: "USDZExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to write USDZ scene from SceneKit"])
            }
        }
        
        guard FileManager.default.fileExists(atPath: outputURL.path),
              (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
            throw NSError(domain: "USDZExporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Generated USDZ file is missing or empty"])
        }
        
        return outputURL
    }
}
