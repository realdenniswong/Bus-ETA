import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - The Main Entry Point
@main
struct BusETAWidgetBundle: WidgetBundle {
    var body: some Widget {
        BusETAWidget()
    }
}

// MARK: - The Widget Definition
struct BusETAWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BusETAAttributes.self) { context in
            // MARK: - (Lock Screen) / Banner UI
            VStack(spacing: 16) {
                
                // Top Row: Huge Route, Destination/Station, and Custom Text Layout
                HStack(alignment: .center, spacing: 12) {
                    
                    // Huge Route Badge
                    Text(context.attributes.routeName)
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.65, green: 0.08, blue: 0.12)) // KMB 標準紅
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    
                    // 2 Lines: Destination & Station Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("往 \(context.attributes.destination)")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        Text(context.attributes.stationName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer(minLength: 4)
                    
                    // 右側大字：完全由代碼控制文字，寫死「分鐘」
                    VStack(alignment: .trailing, spacing: 2) {
                        let mins = max(0, Int(context.state.etaDate.timeIntervalSince(Date()) / 60))
                        
                        if mins < 2 {
                            Text("即將抵達")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundColor(.green)
                        } else {
                            Text("\(mins) 分鐘")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.blue)
                        }
                        
                        Text("\(formattedTime(context.state.etaDate)) 到達")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                
                // Bottom Row: Clean Animated Progress Bar
                ProgressView(timerInterval: context.attributes.startTime...context.state.etaDate, countsDown: false)
                    .tint(.blue)
                    .background(Color.gray.opacity(0.2))
                    .labelsHidden()
                
            }
            .padding()
            
        } dynamicIsland: { context in
            DynamicIsland {
                // MARK: - (Expanded 展開狀態)
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.routeName)
                        .font(.title2)
                        .fontWeight(.black)
                        .foregroundColor(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // 靈動島展開右側
                    VStack(alignment: .trailing, spacing: 2) {
                        let mins = max(0, Int(context.state.etaDate.timeIntervalSince(Date()) / 60))
                        if mins < 2 {
                            Text("即將抵達")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(.green)
                        } else {
                            Text("\(mins) 分鐘")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.blue)
                        }
                        Text(formattedTime(context.state.etaDate))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("往 \(context.attributes.destination) ∙ \(context.attributes.stationName)")
                            .font(.subheadline)
                            .fontWeight(.bold)
                        
                        ProgressView(timerInterval: context.attributes.startTime...context.state.etaDate, countsDown: false)
                            .tint(.blue)
                            .labelsHidden()
                    }
                    .padding(.top, 8)
                }
            } compactLeading: {
                // MARK: - Compact Leading (緊湊左側)
                Text(context.attributes.routeName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.red)
                    .padding(.leading, 4)
            } compactTrailing: {
                // MARK: - Compact Trailing (緊湊右側)
                // 緊湊模式下空間極小，直接 hardcode 顯示「X分」，既美觀又絕對不會爆位
                let mins = max(0, Int(context.state.etaDate.timeIntervalSince(Date()) / 60))
                Text(mins < 2 ? "即將到" : "\(mins)分")
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .frame(maxWidth: 60, alignment: .trailing)
                    .minimumScaleFactor(0.7)
                    .foregroundColor(mins < 2 ? .green : .blue)
            } minimal: {
                // MARK: - Minimal (最小化獨立狀態)
                Image(systemName: "bus.fill")
                    .foregroundColor(.red)
            }
        }
    }
    
    // 輔助函數：用來格式化 Widget 內部的絕對時間
    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
