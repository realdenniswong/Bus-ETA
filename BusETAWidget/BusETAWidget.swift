import WidgetKit
import SwiftUI
import ActivityKit

@main
struct BusETAWidgetBundle: WidgetBundle {
    var body: some Widget {
        BusETAWidget()
    }
}

// MARK: - 🌟 智能顯示組件 (修正版：完全移除「即將到達」與「到達」字眼)
struct SmartETABlock: View {
    let etaDate: Date
    let bigSize: CGFloat
    let smallSize: CGFloat
    
    @Environment(\.isLuminanceReduced) var isLuminanceReduced
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if isLuminanceReduced {
                // AOD 熄芒狀態
                Text(formattedTime(etaDate))
                    .font(.system(size: bigSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                Text("預計到達")
                    .font(.system(size: smallSize, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                // 正常著芒狀態：直接進行精確倒數，不加多餘字眼
                Text(etaDate, style: .timer)
                    .font(.system(size: bigSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.blue)
                    .multilineTextAlignment(.trailing)
                Text(formattedTime(etaDate))
                    .font(.system(size: smallSize, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 🌟 智能顯示組件 2：靈動島緊湊模式 (單行空間)
struct CompactETABlock: View {
    let etaDate: Date
    @Environment(\.isLuminanceReduced) var isLuminanceReduced
    
    var body: some View {
        if isLuminanceReduced {
            Text(formattedTime(etaDate))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.primary)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: 36, alignment: .trailing)
        } else {
            Text(etaDate, style: .timer)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.blue)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: 36, alignment: .trailing)
        }
    }
}

fileprivate func formattedTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

// MARK: - The Widget Definition
struct BusETAWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BusETAAttributes.self) { context in
            // MARK: - 鎖屏 / 通知中心 Banner
            VStack(spacing: 16) {
                
                HStack(alignment: .center, spacing: 12) {
                    
                    // 1. 左邊：精緻嘅路線徽章
                    Text(context.attributes.routeName)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .frame(minWidth: 54)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(red: 0.8, green: 0.1, blue: 0.1))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    
                    // 2. 中間：目的地與車站名
                    VStack(alignment: .leading, spacing: 2) {
                        Text("往 \(context.attributes.destination)")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        
                        Text(context.attributes.stationName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    
                    Spacer(minLength: 8)
                    
                    // 3. 右邊：清晰倒數計時
                    SmartETABlock(etaDate: context.state.etaDate, bigSize: 24, smallSize: 12)
                }
                
                // 4. 底部：自然嘅進度條
                ProgressView(timerInterval: context.attributes.startTime...context.state.etaDate, countsDown: false)
                    .tint(.blue)
                    .background(Color.gray.opacity(0.15))
                    .labelsHidden()
            }
            .padding()
            .activityBackgroundTint(Color(.systemBackground))
            
        } dynamicIsland: { context in
            DynamicIsland {
                // MARK: - 靈動島展開狀態 (Expanded)
                
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.routeName)
                        .font(.system(size: 36, weight: .black, design: .rounded))
                        .foregroundColor(.red)
                        .padding(.leading, 12)
                }
                
                DynamicIslandExpandedRegion(.trailing) {
                    SmartETABlock(etaDate: context.state.etaDate, bigSize: 22, smallSize: 12)
                        .padding(.trailing, 12)
                }
                
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(context.attributes.stationName) 往 \(context.attributes.destination)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 12)
                        
                        ProgressView(timerInterval: context.attributes.startTime...context.state.etaDate, countsDown: false)
                            .tint(.blue)
                            .labelsHidden()
                            .padding(.horizontal, 12)
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
            } compactLeading: {
                Text(context.attributes.routeName)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color(red: 0.8, green: 0.1, blue: 0.1))
                    .clipShape(Circle())
                    .frame(maxWidth: 36, alignment: .trailing)
            } compactTrailing: {
                CompactETABlock(etaDate: context.state.etaDate)
            } minimal: {
                Image(systemName: "bus.fill")
                    .foregroundColor(.red)
            }
        }
    }
}
