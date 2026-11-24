# RoomMaquette: Technical Export Specification

This document details the exact specifications, geometry construction, units, and software compatibility for each format produced by **RoomMaquette**.

---

## 1. Coordinate System & Units
- **Origin**: Center of the scanned room or primary wall origin.
- **Orientation**: Right-handed Cartesian coordinate system:
  - $+X$: Right / East
  - $+Y$: Up / Vertical elevation (Ceiling direction)
  - $+Z$: Front / South
- **Units**:
  - 3D Models (`.obj`, `.stl`, `.gltf`, `.usdz`): **Meters** ($1.0 = 1\text{ meter}$).
  - 2D CAD (`.dxf`): **Meters** (`$INSUNITS = 6`).
  - 2D Vector (`.svg`): $1.0\text{ meter} = 100\text{ user pixels}$.
  - PDF Document (`.pdf`): Points ($72\text{ pt/inch}$) formatted at 1:50 architectural scale.

---

## 2. 3D Model Formats

### A. Apple USDZ (`.usdz`)
- **Specification**: Universal Scene Description (Zip-compressed package).
- **Features**:
  - Embedded PBR materials (diffuse, roughness, metallic).
  - Native integration with Apple AR Quick Look (`QLPreviewController`).
  - Supports instant AR placement: tap "View in AR" to drop the miniature maquette on a table at 1:20 or 1:50 scale.
- **Target Applications**: Apple Vision Pro, iOS Quick Look, Reality Composer, Safari Web AR.

### B. Wavefront OBJ + MTL (`.obj`, `.mtl`)
- **Specification**: Universal polygonal geometry format.
- **Hierarchy & Groups**:
  - `g FloorPlinth`: Base architectural exhibition pedestal with beveled corners.
  - `g Wall_1`, `g Wall_2`, ...: Oriented 3D wall solids.
  - `g Door_1`, ...: Door leaves with frame thickness.
  - `g Window_1`, ...: Glazing panels with transparency.
  - `g Furniture_<category>_...`: Volumetric bounding meshes for furniture.
- **Material Library (`.mtl`)**:
  - `WallMaterial`: Warm plaster matte finish ($K_d = 0.92, 0.91, 0.89$).
  - `GlassMaterial`: Semi-transparent cyan tint with specular highlights ($d = 0.35, K_s = 0.9$).
  - `DoorMaterial`: Natural wood finish.
  - Category-specific furniture materials.
- **Target Applications**: Blender 4.x, Autodesk 3ds Max, Maya, SketchUp Pro, Cinema 4D, Unreal Engine 5, Unity.

### C. Stereolithography STL (`.stl`) - 3D Printing
- **Specification**: ASCII and Binary STL with 80-byte header and 50-byte triangular facet records.
- **Architectural Manifold Structure**:
  - Walls and furniture volumes are extruded and joined onto a solid floor plinth.
  - Every triangle normal is computed with outward-facing right-hand vertex ordering (`cross(v1 - v0, v2 - v0)`).
  - Watertight geometries designed specifically for non-manifold error-free slicing in 3D printing software.
- **Target Slicers**: Bambu Studio, PrusaSlicer, Ultimaker Cura, OrcaSlicer, Formlabs PreForm.
- **Scale Recommendation for Slicers**:
  - For $1:50$ scale maquette: scale model by $2\%$ ($0.02$).
  - For $1:100$ scale maquette: scale model by $1\%$ ($0.01$).

### D. glTF 2.0 (`.gltf`)
- **Specification**: Modern GL Transmission Format 2.0 with embedded binary buffer (data URI).
- **Features**:
  - Self-contained single-file `.gltf` (no separate `.bin` file required).
  - PBR metallic-roughness material definition.
  - Full node hierarchy matching the room spatial structure with translation vectors and rotation quaternions.
- **Target Applications**: WebGL, Three.js, Babylon.js, PlayCanvas, Godot, Blender.

### E. AutoCAD Drawing Exchange Format (`.dxf`)
- **Specification**: ASCII DXF AC1015 (AutoCAD 2000 standard).
- **CAD Layer Table**:
  - `A-WALL` (Color 7: White/Black) - Perimeter and interior partition walls.
  - `A-DOOR` (Color 5: Blue) - Door thresholds and leaves.
  - `A-GLAZ` (Color 4: Cyan) - Window glazing.
  - `A-FURN` (Color 30: Wood/Orange) - Furniture outlines.
  - `A-DIMS` (Color 2: Yellow) - Architectural dimension lines and tick marks.
- **Target Applications**: Autodesk AutoCAD, Revit, ArchiCAD, Rhino, Vectorworks, LibreCAD.

---

## 3. 2D Vector & Document Formats

### A. Scalable Vector Graphics (`.svg`)
- **Specification**: W3C Scalable Vector Graphics XML.
- **Structured XML Layer Groups**:
  - `<g id="background">`: 1-meter architectural grid.
  - `<g id="walls">`: High-contrast wall core lines.
  - `<g id="doors">`: Door leaves and $90^\circ$ radial swing arcs (`stroke-dasharray="4,4"`).
  - `<g id="windows">`: Double-line glass representations.
  - `<g id="furniture">`: Rotated `<g transform="translate(...) rotate(...)">` components with labels.
  - `<g id="dimensions">`: Dimension extension lines, ticks, and numeric text in meters.
  - `<g id="title-block">`: Room title and gross floor area.
- **Target Applications**: Adobe Illustrator, Figma, Affinity Designer, Inkscape, Laser Cutters.

### B. Architectural Documentation PDF (`.pdf`)
- **Specification**: ISO A4 Landscape sheet ($842 \times 595\text{ pt}$).
- **Contents**:
  1. Title Block header: Room Title, Date, iPhone Pro LiDAR attribution, Area ($m^2$ and $sq\ ft$).
  2. 2D schematic floor plan with dimensions at 1:50 scale.
  3. 3D perspective maquette render with soft studio lighting.
  4. Room Specifications & Furniture Schedule table detailing item dimensions ($W \times D \times H$).
- **Target Applications**: AirPrint, Acrobat Reader, Client Presentations, Building Permit applications.

### C. Studio Render PNG (`.png`)
- **Specification**: 24-bit RGB with alpha channel at $2560 \times 1440$ resolution.
- **Rendering Engine**: SceneKit physically-based offscreen rendering with 4x multisampling anti-aliasing and directional shadow casting.
