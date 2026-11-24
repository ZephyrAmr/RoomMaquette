import SwiftUI

public struct RoomMetricsView: View {
    public var room: MaquetteRoom
    
    public init(room: MaquetteRoom) {
        self.room = room
    }
    
    public var body: some View {
        List {
            // Spatial Metrics Section
            Section("SPATIAL & ARCHITECTURAL METRICS") {
                metricRow(title: "Floor Area", value: "\(room.formattedAreaMetric)  /  \(room.formattedAreaImperial)", icon: "square.fill")
                metricRow(title: "Bounding Dimensions", value: room.formattedDimensions, icon: "cube.fill")
                metricRow(title: "Ceiling Height", value: String(format: "%.2f m (%.1f ft)", room.ceilingHeight, room.ceilingHeight * 3.28084), icon: "arrow.up.and.down")
                metricRow(title: "Wall Perimeter", value: String(format: "%.2f m (%.1f ft)", room.perimeterMeters, room.perimeterMeters * 3.28084), icon: "rectangle.dashed")
                metricRow(title: "Internal Volume", value: String(format: "%.1f m³ (%.0f cu ft)", room.volumeCubicMeters, room.volumeCubicMeters * 35.3147), icon: "shippingbox.fill")
            }
            
            // Surfaces Section
            Section("SURFACES & ENCLOSURE") {
                HStack {
                    Label("\(room.walls.count) Walls", systemImage: "square.split.diagonal.2x2")
                    Spacer()
                    Label("\(room.doors.count) Doors", systemImage: "door.left.hand.open")
                    Spacer()
                    Label("\(room.windows.count) Windows", systemImage: "window.vertical.closed")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.vertical, 4)
                
                ForEach(room.walls) { wall in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wall Segment")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Length: \(String(format: "%.2fm", wall.length)) • Height: \(String(format: "%.2fm", wall.height)) • Thickness: \(String(format: "%.2fm", wall.thickness))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            
            // Furniture & Objects Schedule
            Section("FURNITURE & FIXTURE SCHEDULE (\(room.objects.count))") {
                if room.objects.isEmpty {
                    Text("No furniture detected in this scan.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(room.objects) { obj in
                        HStack(spacing: 12) {
                            Image(systemName: obj.category.systemIcon)
                                .font(.system(size: 18))
                                .foregroundColor(obj.category.accentColor)
                                .frame(width: 28)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(obj.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("\(String(format: "%.2fm (W) × %.2fm (D) × %.2fm (H)", obj.width, obj.depth, obj.height))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Text(obj.category.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
            
            // Metadata Section
            Section("SCAN METADATA") {
                HStack {
                    Text("Created")
                    Spacer()
                    Text(DateFormatter.localizedString(from: room.createdAt, dateStyle: .medium, timeStyle: .short))
                        .foregroundColor(.secondary)
                }
                .font(.footnote)
                
                HStack {
                    Text("Capture Method")
                    Spacer()
                    Text("iPhone Pro LiDAR + RoomPlan")
                        .foregroundColor(.secondary)
                }
                .font(.footnote)
            }
        }
    }
    
    @ViewBuilder
    private func metricRow(title: String, value: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
        }
    }
}
