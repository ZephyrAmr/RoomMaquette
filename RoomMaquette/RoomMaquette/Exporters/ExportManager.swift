import Foundation
import UIKit

public enum ExportFormat: String, CaseIterable, Identifiable {
    // 3D Formats
    case usdz = "USDZ (Apple AR & Quick Look)"
    case obj = "OBJ + MTL (Universal 3D Mesh)"
    case stl = "STL (3D Printable Maquette)"
    case gltf = "glTF 2.0 (Web 3D & Blender)"
    case dxf = "DXF (AutoCAD & CAD Plans)"
    
    // 2D Formats
    case png = "PNG (High-Resolution Render)"
    case pdf = "PDF (Architectural Report Sheet)"
    case svg = "SVG (Vector Architectural Plan)"
    
    public var id: String { rawValue }
    
    public var fileExtension: String {
        switch self {
        case .usdz: return "usdz"
        case .obj: return "obj"
        case .stl: return "stl"
        case .gltf: return "gltf"
        case .dxf: return "dxf"
        case .png: return "png"
        case .pdf: return "pdf"
        case .svg: return "svg"
        }
    }
    
    public var icon: String {
        switch self {
        case .usdz: return "arkit"
        case .obj: return "cube.fill"
        case .stl: return "printer.fill"
        case .gltf: return "globe"
        case .dxf: return "ruler.fill"
        case .png: return "photo.fill"
        case .pdf: return "doc.richtext.fill"
        case .svg: return "beziercurve"
        }
    }
    
    public var category: String {
        switch self {
        case .usdz, .obj, .stl, .gltf, .dxf:
            return "3D Model Formats"
        case .png, .pdf, .svg:
            return "2D & Documentation Formats"
        }
    }
    
    public var description: String {
        switch self {
        case .usdz:
            return "Native Apple AR format. Ready for iOS Quick Look, RealityKit, and Reality Composer."
        case .obj:
            return "Standard Wavefront geometry with companion MTL materials. Supported by Blender, Maya, 3ds Max, and game engines."
        case .stl:
            return "Manifold solid mesh designed specifically for 3D printing physical scale models and physical maquettes."
        case .gltf:
            return "Modern self-contained glTF 2.0 format with embedded materials for web 3D, Three.js, and Babylon.js."
        case .dxf:
            return "AutoCAD Drawing Exchange format with organized layers (WALLS, DOORS, WINDOWS, FURNITURE, DIMS)."
        case .png:
            return "Crisp 2.5K raster rendering with studio architectural museum lighting."
        case .pdf:
            return "Professional A4 landscape architectural drawing with title block, 2D floor plan, 3D render, and furniture schedule."
        case .svg:
            return "Clean, layered vector graphic compatible with Adobe Illustrator, Figma, and Inkscape."
        }
    }
}

public class ExportManager {
    
    public static func export(
        room: MaquetteRoom,
        format: ExportFormat,
        style: MaquetteStyle = .architecturalClay
    ) throws -> [URL] {
        switch format {
        case .usdz:
            let url = try USDZExporter.export(room: room, style: style)
            return [url]
            
        case .obj:
            let (objURL, mtlURL) = try OBJExporter.export(room: room)
            return [objURL, mtlURL]
            
        case .stl:
            let url = try STLExporter.export(room: room, binary: true)
            return [url]
            
        case .gltf:
            let url = try GLTFExporter.export(room: room)
            return [url]
            
        case .dxf:
            let url = try DXFExporter.export(room: room)
            return [url]
            
        case .png:
            let url = try PNGExporter.export(room: room, style: style, renderType: .perspective3D)
            return [url]
            
        case .pdf:
            let url = try PDFExporter.export(room: room)
            return [url]
            
        case .svg:
            let url = try SVGExporter.export(room: room)
            return [url]
        }
    }
}
