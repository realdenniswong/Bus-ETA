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
            // MARK: - 鎖定畫面 (Lock Screen) / Banner UI
            VStack(spacing: 16) {
                
                // Top Row: Huge Route, Destination/Station, and Huge Countdown
                HStack(alignment: .center, spacing: 12) {
                    
                    // Huge Route Badge
                    Text(context.attributes.routeName)
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.85, green: 0.1, blue: 0.15)) // KMB Red
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
                    
                    // Huge Countdown Timer on the Right
                    Text(timerInterval: Date()...context.state.etaDate, countsDown: true)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.primary)
                }
                
                // Bottom Row: Clean Animated Progress Bar (No extra text!)
                ProgressView(timerInterval: context.attributes.startTime...context.state.etaDate, countsDown: false)
                    .tint(.blue)
                    .background(Color.gray.opacity(0.2))
                    .labelsHidden()
                
            }
            .padding()
            
        } dynamicIsland: { context in
            DynamicIsland {
                // MARK: - 動態島長按展開 (Expanded)
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.routeName)
                        .font(.title2)
                        .fontWeight(.black)
                        .foregroundColor(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...context.state.etaDate, countsDown: true)
                        .font(.title3)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundColor(.blue)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("往 \(context.attributes.destination)")
                            .font(.subheadline)
                            .fontWeight(.bold)
                        
                        ProgressView(timerInterval: context.attributes.startTime...context.state.etaDate, countsDown: false)
                            .tint(.blue)
                            .labelsHidden()
                    }
                    .padding(.top, 8)
                }
            } compactLeading: {
                // MARK: - 動態島左側
                Text(context.attributes.routeName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.red)
                    .padding(.leading, 4)
            } compactTrailing: {
                // MARK: - 動態島右側 (防斬字)
                Text(timerInterval: Date()...context.state.etaDate, countsDown: true)
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .frame(maxWidth: 40, alignment: .trailing)
                    .minimumScaleFactor(0.6)
                    .foregroundColor(.blue)
            } minimal: {
                // MARK: - 極簡模式
                Image(systemName: "bus.fill")
                    .foregroundColor(.red)
            }
        }
    }
}
