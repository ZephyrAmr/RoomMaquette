import SwiftUI
import UIKit
import SceneKit

public enum MaquetteStyle: String, CaseIterable, Identifiable {
    case architecturalClay = "Clay Maquette"
    case basswood = "Basswood Model"
    case technicalBlueprint = "Blueprint"
    case modernMaterial = "Color Coded"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .architecturalClay: return "cube.transparent"
        case .basswood: return "shippingbox"
        case .technicalBlueprint: return "square.grid.3x3"
        case .modernMaterial: return "paintpalette"
        }
    }
    
    // Wall Material
    public var wallMaterial: SCNMaterial {
        let mat = SCNMaterial()
        mat.isDoubleSided = true
        
        switch self {
        case .architecturalClay:
            mat.diffuse.contents = UIColor(red: 0.94, green: 0.93, blue: 0.91, alpha: 1.0) // Warm plaster
            mat.roughness.contents = 0.85
            mat.metalness.contents = 0.05
            mat.lightingModel = .physicallyBased
            
        case .basswood:
            mat.diffuse.contents = UIColor(red: 0.91, green: 0.82, blue: 0.70, alpha: 1.0) // Natural wood tone
            mat.roughness.contents = 0.7
            mat.metalness.contents = 0.0
            mat.lightingModel = .physicallyBased
            
        case .technicalBlueprint:
            mat.diffuse.contents = UIColor(red: 0.05, green: 0.20, blue: 0.45, alpha: 0.75) // Translucent cyan/blue
            mat.roughness.contents = 0.3
            mat.emission.contents = UIColor(red: 0.0, green: 0.4, blue: 0.8, alpha: 0.2)
            mat.transparency = 0.85
            mat.lightingModel = .phong
            
        case .modernMaterial:
            mat.diffuse.contents = UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1.0)
            mat.roughness.contents = 0.5
            mat.metalness.contents = 0.1
            mat.lightingModel = .physicallyBased
        }
        return mat
    }
    
    // Floor Material
    public var floorMaterial: SCNMaterial {
        let mat = SCNMaterial()
        mat.isDoubleSided = true
        
        switch self {
        case .architecturalClay:
            mat.diffuse.contents = UIColor(red: 0.86, green: 0.85, blue: 0.83, alpha: 1.0)
            mat.roughness.contents = 0.9
            mat.lightingModel = .physicallyBased
            
        case .basswood:
            mat.diffuse.contents = UIColor(red: 0.82, green: 0.72, blue: 0.58, alpha: 1.0)
            mat.roughness.contents = 0.8
            mat.lightingModel = .physicallyBased
            
        case .technicalBlueprint:
            mat.diffuse.contents = UIColor(red: 0.02, green: 0.08, blue: 0.20, alpha: 1.0)
            mat.lightingModel = .constant
            
        case .modernMaterial:
            mat.diffuse.contents = UIColor(red: 0.88, green: 0.82, blue: 0.74, alpha: 1.0) // Soft oak parquet tone
            mat.roughness.contents = 0.6
            mat.lightingModel = .physicallyBased
        }
        return mat
    }
    
    // Glass Material for Windows
    public var glassMaterial: SCNMaterial {
        let mat = SCNMaterial()
        mat.isDoubleSided = true
        mat.diffuse.contents = UIColor(red: 0.7, green: 0.85, blue: 0.95, alpha: 0.35)
        mat.transparency = 0.4
        mat.roughness.contents = 0.1
        mat.metalness.contents = 0.1
        mat.lightingModel = .physicallyBased
        return mat
    }
    
    // Door Material
    public var doorMaterial: SCNMaterial {
        let mat = SCNMaterial()
        switch self {
        case .architecturalClay:
            mat.diffuse.contents = UIColor(red: 0.88, green: 0.87, blue: 0.85, alpha: 1.0)
        case .basswood:
            mat.diffuse.contents = UIColor(red: 0.78, green: 0.65, blue: 0.50, alpha: 1.0)
        case .technicalBlueprint:
            mat.diffuse.contents = UIColor(red: 0.1, green: 0.4, blue: 0.7, alpha: 0.8)
        case .modernMaterial:
            mat.diffuse.contents = UIColor(red: 0.75, green: 0.58, blue: 0.44, alpha: 1.0)
        }
        return mat
    }
    
    // Furniture Material by Category
    public func furnitureMaterial(for category: ObjectCategory) -> SCNMaterial {
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        
        switch self {
        case .architecturalClay:
            mat.diffuse.contents = UIColor(red: 0.90, green: 0.89, blue: 0.87, alpha: 1.0)
            mat.roughness.contents = 0.85
            
        case .basswood:
            mat.diffuse.contents = UIColor(red: 0.85, green: 0.75, blue: 0.62, alpha: 1.0)
            mat.roughness.contents = 0.7
            
        case .technicalBlueprint:
            mat.diffuse.contents = UIColor(red: 0.0, green: 0.6, blue: 0.9, alpha: 0.6)
            mat.emission.contents = UIColor(red: 0.0, green: 0.3, blue: 0.6, alpha: 0.2)
            mat.transparency = 0.7
            
        case .modernMaterial:
            mat.diffuse.contents = UIColor(category.accentColor)
            mat.roughness.contents = 0.5
        }
        return mat
    }
    
    // Background Color
    public var sceneBackgroundColor: UIColor {
        switch self {
        case .architecturalClay:
            return UIColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 1.0)
        case .basswood:
            return UIColor(red: 0.95, green: 0.93, blue: 0.90, alpha: 1.0)
        case .technicalBlueprint:
            return UIColor(red: 0.02, green: 0.05, blue: 0.12, alpha: 1.0)
        case .modernMaterial:
            return UIColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1.0)
        }
    }
}
