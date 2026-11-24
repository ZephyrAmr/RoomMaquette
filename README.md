# RoomMaquette: iPhone Pro 3D Room & Building Maquette iOS App

**RoomMaquette** is a native iOS application built with Swift and SwiftUI that harnesses Apple's **RoomPlan API**, **ARKit**, and the **iPhone Pro LiDAR Scanner** (iPhone 12 Pro through iPhone 16 Pro, iPad Pro) to scan physical interior spaces and construct architectural 3D models (digital twin maquettes).

The app allows architects, interior designers, 3D artists, and spatial computing developers to inspect the generated maquette in 3D and 2D architectural blueprint modes, place it onto physical surfaces in Augmented Reality (AR Quick Look), and export it into industry-standard 3D and 2D file formats: **USDZ**, **OBJ (+ MTL)**, **STL (3D Printable)**, **glTF 2.0**, **AutoCAD DXF**, **High-Res PNG**, **Architectural PDF**, and **Layered SVG**.

---

## Key Capabilities

### 1. iPhone Pro LiDAR & RoomPlan Scanning
- **Real-Time Capture**: Direct integration with `RoomCaptureSession` and `RoomCaptureView`.
- **Parametric Detection**: Identifies walls, doors (open/closed state), windows, openings, and furniture objects (sofas, tables, chairs, beds, storage, refrigerators, stoves, sinks, toilets, televisions, bathtubs).
- **Interactive Coaching**: Apple's native coaching overlay guides the user to pan across walls, floors, and corners.
- **Hardware Fallback & Simulator Mode**: Built-in hardware detection (`LiDARDetector`). When run on non-LiDAR iPhones or the Xcode Simulator, the app automatically enables interactive sample demo rooms so all 3D inspection and multi-format exports can be tested without physical hardware.

### 2. Interactive 3D Maquette Viewer (`SceneKitMaquetteRenderer`)
- **Architectural Maquette Aesthetics**:
  - **Museum Clay / Plaster**: Off-white plaster finish with directional shadows, ideal for spatial volume evaluation.
  - **Basswood Model**: Natural blonde wood grain aesthetic, resembling physical scale models.
  - **Technical Blueprint**: Translucent navy/cyan wireframe with glowing edge lines.
  - **Color Coded**: Distinguishes structural walls, glazing, doors, and color-coded furniture categories.
- **Camera Controls**: Free orbital rotation, two-finger pan, pinch-to-zoom, and orthographic dollhouse view.
- **Interactive Toggles**:
  - Roof/Ceiling slab toggle (switch between dollhouse and enclosed structure).
  - 3D Dimension lines indicator.
  - One-tap AR Quick Look placement on physical tables or floors.

### 3. Precision 2D Architectural Floor Plan (`FloorPlan2DCanvas`)
- Vector-rendered 2D drawing adhering to international architectural conventions.
- Double-line walls with realistic wall thickness.
- Door swing 90° radial arcs.
- Window glazing mullion symbols.
- Internal furniture plan symbols (sofa cushions, bed pillows, table surfaces, sanitaryware).
- Architectural dimension lines with tick marks and measurements.
- Real-time unit switching: **Metric** (meters) and **Imperial** (feet/inches).
- Scaled architectural grid, north arrow, scale bar, and room badge with gross area ($m^2$ / sq ft).

### 4. Comprehensive Multi-Format Export Engine

| Format | Category | Target Software & Workflow |
| :--- | :--- | :--- |
| **USDZ** | 3D Model | Apple AR Quick Look, RealityKit, Reality Composer, iOS Messages |
| **OBJ + MTL** | 3D Model | Blender, Autodesk 3ds Max, Maya, SketchUp, Cinema 4D, Unreal Engine, Unity |
| **STL** | 3D Model | **3D Printing scale maquettes** (Bambu Studio, PrusaSlicer, Ultimaker Cura) |
| **glTF 2.0** | 3D Model | Web 3D, Three.js, Babylon.js, PlayCanvas, WebGL viewers |
| **DXF** | 2D / 3D CAD | Autodesk AutoCAD, Revit, ArchiCAD, Rhino, LibreCAD |
| **PNG** | 2D Raster | High-resolution 2.5K studio snapshot with architectural studio lighting |
| **PDF** | 2D Document | Complete A4 landscape architectural report sheet with title block & schedule |
| **SVG** | 2D Vector | Layered vector floor plan for Adobe Illustrator, Figma, Affinity Designer |

---

## Project Structure

```
RoomMaquette/
├── RoomMaquette.xcodeproj/
│   ├── project.pbxproj               # Complete PBX project configuration
│   └── project.xcworkspace/
│       └── contents.xcworkspacedata
├── RoomMaquette/
│   ├── App/
│   │   ├── RoomMaquetteApp.swift     # SwiftUI @main entry point
│   │   └── Info.plist                # Camera usage & File sharing permissions
│   ├── Models/
│   │   ├── SurfaceModel.swift        # Wall, door, window, opening models & transforms
│   │   ├── ObjectModel.swift         # Furniture categories & parametric dimensions
│   │   ├── MaquetteRoom.swift        # Room container, spatial bounds, and area math
│   │   ├── MaquetteBuilding.swift    # Multi-room & multi-level building support
│   │   ├── SampleRooms.swift         # Realistic studio & office demo rooms
│   │   └── ProjectStore.swift        # Document persistence & JSON storage
│   ├── Capture/
│   │   ├── LiDARDetector.swift       # Hardware capability verification
│   │   ├── RoomCaptureManager.swift  # Apple RoomPlan capture session orchestrator
│   │   └── RoomCaptureViewContainer.swift # UIViewRepresentable for RoomCaptureView
│   ├── Renderers/
│   │   ├── MaquetteTheme.swift       # Material styles (Clay, Basswood, Blueprint)
│   │   ├── SceneKitMaquetteRenderer.swift # 3D procedural maquette generation
│   │   ├── Maquette3DSceneView.swift # SwiftUI 3D viewer with touch gestures
│   │   └── FloorPlan2DCanvas.swift   # Vector SwiftUI 2D architectural plan canvas
│   ├── Exporters/
│   │   ├── ExportManager.swift       # Unified export orchestrator
│   │   ├── USDZExporter.swift        # Apple USDZ exporter
│   │   ├── OBJExporter.swift         # Wavefront OBJ + MTL geometry exporter
│   │   ├── STLExporter.swift         # 3D printable binary/ASCII STL exporter
│   │   ├── GLTFExporter.swift        # Self-contained glTF 2.0 exporter
│   │   ├── DXFExporter.swift         # AutoCAD DXF layer exporter
│   │   ├── PNGExporter.swift         # High-resolution raster snapshot exporter
│   │   ├── PDFExporter.swift         # Architectural report sheet PDF exporter
│   │   └── SVGExporter.swift         # Layered vector SVG exporter
│   ├── Views/
│   │   ├── HomeDashboardView.swift   # Project list, scan CTA, and hardware status
│   │   ├── RoomScanView.swift        # Live scanner screen with HUD stats
│   │   ├── MaquetteWorkspaceView.swift # 3D/2D/Specs inspector workspace
│   │   ├── FloorPlanTabView.swift    # 2D plan controls with metric/imperial toggle
│   │   ├── RoomMetricsView.swift     # Area, ceiling height, volume, and schedule
│   │   ├── ExportSheetView.swift     # Interactive export sheet modal
│   │   ├── QuickLookView.swift       # Native iOS AR Quick Look controller
│   │   └── ShareSheet.swift          # UIActivityViewController wrapper
│   └── Assets.xcassets/              # App icon & accent colors
├── README.md
└── EXPORT_SPECIFICATION.md
```

---

## How to Build & Run

### Requirements
- **Mac** with macOS Sonoma (14.0+) or macOS Sequoia.
- **Xcode 15.0+** or Xcode 16.0+.
- **iOS Device**:
  - For live LiDAR scanning: **iPhone 12 Pro, 13 Pro, 14 Pro, 15 Pro, 16 Pro** or **iPad Pro** (2020 or newer) running **iOS 16.0+**.
  - For testing in Simulator or non-Pro iPhones: Any iOS 16.0+ simulator target or device (using built-in sample demo scans).

### Steps
1. Open `RoomMaquette.xcodeproj` in Xcode.
2. Select the `RoomMaquette` scheme.
3. In the project settings under **Signing & Capabilities**, select your Apple Developer Team.
4. Choose your physical iPhone Pro or an iOS Simulator target.
5. Press **Cmd + R** (Build and Run).

### Testing Without LiDAR
If you don't have an iPhone Pro nearby:
- Launch the app in the Simulator or on any iPhone.
- The app will automatically seed two complete architectural models:
  1. **Modern Studio Apartment** ($28.8\text{ m}^2$ / $310\text{ sq ft}$) with 4 walls, balcony glass window, entry door, sofa, bed, dining table, chairs, TV unit, and refrigerator.
  2. **Executive Boardroom** ($36.4\text{ m}^2$ / $392\text{ sq ft}$) with acoustic walls, conference table, executive chairs, presentation screen, and credenza.
- Open any project, switch between 3D Maquette and 2D Floor Plan, customize styles, and tap **Export** to test generating all 8 file formats!
