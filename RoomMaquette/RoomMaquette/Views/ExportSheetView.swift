import SwiftUI
import QuickLook

public struct ExportSheetView: View {
    public var room: MaquetteRoom
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedFormat: ExportFormat = .pdf
    @State private var selectedStyle: MaquetteStyle = .architecturalClay
    @State private var isExporting: Bool = false
    @State private var exportedURLs: [URL]? = nil
    @State private var previewURL: URL? = nil
    @State private var errorMessage: String? = nil
    
    public init(room: MaquetteRoom) {
        self.room = room
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    
                    // Room summary header
                    HStack(spacing: 16) {
                        Image(systemName: "cube.transparent.fill")
                            .font(.system(size: 34))
                            .foregroundColor(.blue)
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text(room.name)
                                .font(.headline)
                            Text("\(room.formattedAreaMetric) (\(room.formattedAreaImperial)) • \(room.walls.count) Walls • \(room.objects.count) Items")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    
                    // Success Result Banner if exported
                    if let urls = exportedURLs, let mainURL = urls.first {
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(.green)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Export Successful!")
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                        .foregroundColor(.primary)
                                    Text(mainURL.lastPathComponent)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                
                                Text(formattedFileSize(url: mainURL))
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.15), in: Capsule())
                                    .foregroundColor(.green)
                            }
                            
                            HStack(spacing: 10) {
                                // Share / Save Button
                                Button {
                                    ShareSheetHelper.present(items: urls)
                                } label: {
                                    HStack {
                                        Image(systemName: "square.and.arrow.up.fill")
                                        Text("Share / Save File")
                                    }
                                    .font(.system(size: 13, weight: .bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 10))
                                    .foregroundColor(.white)
                                }
                                
                                // Preview / Quick Look Button
                                Button {
                                    previewURL = mainURL
                                } label: {
                                    HStack {
                                        Image(systemName: "eye.fill")
                                        Text("Preview")
                                    }
                                    .font(.system(size: 13, weight: .bold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                                    .foregroundColor(.primary)
                                }
                            }
                        }
                        .padding()
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.green.opacity(0.3), lineWidth: 1)
                        )
                    }
                    
                    // Format Selection Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SELECT EXPORT FORMAT")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                        
                        // 2D Architectural Formats (Primary for Plans & Blueprints)
                        VStack(alignment: .leading, spacing: 6) {
                            Label("2D Floor Plans & Blueprints", systemImage: "doc.richtext.fill")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            formatRow(for: .pdf)
                            formatRow(for: .png)
                            formatRow(for: .svg)
                            formatRow(for: .dxf)
                        }
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        // 3D Model Formats
                        VStack(alignment: .leading, spacing: 6) {
                            Label("3D Models & Maquettes", systemImage: "cube.fill")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            formatRow(for: .usdz)
                            formatRow(for: .obj)
                            formatRow(for: .stl)
                            formatRow(for: .gltf)
                        }
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        // Project Backup
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Lossless Backup", systemImage: "externaldrive.fill")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            formatRow(for: .json)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    
                    // Aesthetic Style for USDZ / 3D
                    if selectedFormat == .usdz {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("MAQUETTE MATERIAL STYLE")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                            
                            Picker("Material Style", selection: $selectedStyle) {
                                ForEach(MaquetteStyle.allCases) { style in
                                    Text(style.rawValue).tag(style)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    
                    // Selected Format Info Box
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: selectedFormat.icon)
                                .foregroundColor(.blue)
                            Text(selectedFormat.rawValue)
                                .font(.subheadline)
                                .fontWeight(.bold)
                            Spacer()
                            Text(".\(selectedFormat.fileExtension)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12), in: Capsule())
                                .foregroundColor(.blue)
                        }
                        
                        Text(selectedFormat.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    
                    if let err = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    
                    // Action Button
                    Button {
                        performExport()
                    } label: {
                        HStack {
                            if isExporting {
                                ProgressView()
                                    .tint(.white)
                                    .padding(.trailing, 6)
                            } else {
                                Image(systemName: "square.and.arrow.up.fill")
                            }
                            Text(isExporting ? "Generating \(selectedFormat.fileExtension.uppercased())..." : "Export \(selectedFormat.fileExtension.uppercased())")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundColor(.white)
                    }
                    .disabled(isExporting)
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Export Maquette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .quickLookPreview($previewURL)
        }
    }
    
    @ViewBuilder
    private func formatRow(for format: ExportFormat) -> some View {
        Button {
            selectedFormat = format
        } label: {
            HStack(spacing: 12) {
                Image(systemName: format.icon)
                    .font(.system(size: 15))
                    .foregroundColor(selectedFormat == format ? .blue : .secondary)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(format.rawValue)
                        .font(.system(size: 13.5, weight: selectedFormat == format ? .semibold : .regular))
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                if selectedFormat == format {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary.opacity(0.35))
                }
            }
            .padding(.vertical, 5)
        }
    }
    
    private func performExport() {
        isExporting = true
        errorMessage = nil
        exportedURLs = nil
        
        let needsMainThread = (selectedFormat == .pdf || selectedFormat == .png)
        let queue: DispatchQueue = needsMainThread ? .main : DispatchQueue.global(qos: .userInitiated)
        
        queue.asyncAfter(deadline: .now() + 0.02) {
            do {
                let urls = try ExportManager.export(room: room, format: selectedFormat, style: selectedStyle)
                DispatchQueue.main.async {
                    self.exportedURLs = urls
                    self.isExporting = false
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    ShareSheetHelper.present(items: urls)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Export failed: \(error.localizedDescription)"
                    self.isExporting = false
                }
            }
        }
    }
    
    private func formattedFileSize(url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return ""
        }
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useKB, .useMB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: size)
    }
}
