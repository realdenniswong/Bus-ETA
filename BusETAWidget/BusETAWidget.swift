import WidgetKit
import SwiftUI
import ActivityKit

struct BusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BusETAAttributes.self) { context in
            // Lock screen / Banner UI
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "bus.fill")
                        .foregroundColor(.blue)
                    Text("\(context.attributes.routeName) 往 \(context.attributes.destination)")
                        .font(.headline)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .opacity(1.0)
                        Text("實時追蹤")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                // Progress Bar
                GeometryReader { geometry in
                    let totalTime = max(1.0, context.state.etaDate.timeIntervalSince(context.attributes.startTime))
                    let timeRemaining = max(0.0, context.state.etaDate.timeIntervalSince(Date()))
                    let progress = 1.0 - (timeRemaining / totalTime)
                    
                    let barWidth = geometry.size.width
                    let busPosition = barWidth * CGFloat(max(0, min(1, progress)))
                    
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 8)
                        
                        Capsule()
                            .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, busPosition), height: 8)
                        
                        Image(systemName: "bus.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Circle().fill(Color.blue).shadow(radius: 2))
                            .offset(x: max(0, min(busPosition - 14, barWidth - 28)))
                    }
                }
                .frame(height: 28)
                
                HStack {
                    Text("預計時間: \(context.state.etaDate, style: .time)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(timerInterval: Date()...context.state.etaDate, countsDown: true)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.primary)
                }
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.8))
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI
                DynamicIslandExpandedRegion(.leading) {
                    HStack {
                        Image(systemName: "bus.fill")
                            .foregroundColor(.blue)
                        Text(context.attributes.routeName)
                            .font(.headline)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...context.state.etaDate, countsDown: true)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 50)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack {
                        Text("往 \(context.attributes.destination)")
                            .font(.subheadline)
                        
                        GeometryReader { geometry in
                            let totalTime = max(1.0, context.state.etaDate.timeIntervalSince(context.attributes.startTime))
                            let timeRemaining = max(0.0, context.state.etaDate.timeIntervalSince(Date()))
                            let progress = 1.0 - (timeRemaining / totalTime)
                            
                            let barWidth = geometry.size.width
                            let busPosition = barWidth * CGFloat(max(0, min(1, progress)))
                            
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(height: 6)
                                Capsule()
                                    .fill(Color.blue)
                                    .frame(width: max(0, busPosition), height: 6)
                                Image(systemName: "bus.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Circle().fill(Color.blue))
                                    .offset(x: max(0, min(busPosition - 11, barWidth - 22)))
                            }
                        }
                        .frame(height: 22)
                        .padding(.top, 4)
                    }
                }
            } compactLeading: {
                HStack(spacing: 2) {
                    Image(systemName: "bus.fill")
                        .foregroundColor(.blue)
                    Text(context.attributes.routeName)
                        .font(.caption2)
                }
            } compactTrailing: {
                Text(timerInterval: Date()...context.state.etaDate, countsDown: true)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 30)
            } minimal: {
                Image(systemName: "bus.fill")
                    .foregroundColor(.blue)
            }
        }
    }
}

@main
struct BusETAWidgetBundle: WidgetBundle {
    var body: some Widget {
        BusLiveActivity()
    }
}
