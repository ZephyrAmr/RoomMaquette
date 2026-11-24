import UIKit
import SceneKit

public class PNGExporter {
    
    public enum RenderType {
        case perspective3D
        case orthographicDollhouse
    }
    
    public static func export(
        room: MaquetteRoom,
        style: MaquetteStyle = .architecturalClay,
        renderType: RenderType = .perspective3D,
        size: CGSize = CGSize(width: 2560, height: 1440)
    ) throws -> URL {
        let baseName = "\(room.name.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).png"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(baseName)
        
        let isOrtho = (renderType == .orthographicDollhouse)
        let image = SceneKitMaquetteRenderer.snapshot(
            room: room,
            style: style,
            size: size,
            isOrthographic: isOrtho
        )
        
        guard let data = image.pngData() else {
            throw NSError(domain: "PNGExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate PNG data"])
        }
        
        try data.write(to: outputURL)
        return outputURL
    }
}
