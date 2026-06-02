import WidgetKit
import SwiftUI
import ActivityKit

@main
struct BusETAWidgetBundle: WidgetBundle {
    var body: some Widget {
        BusETAWidget()
    }
}

// MARK: - 🌟 智能顯示組件 (簡潔穩定版)
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
                // 正常著芒狀態
                Text(etaDate, style: .timer)
                    .font(.system(size: bigSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.blue)
                    .multilineTextAlignment(.trailing)
                Text("\(formattedTime(etaDate)) 到達")
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
        // ✂️ 移除 Group 封裝，直接將 Modifiers 寫入 Text 確保生效
        if isLuminanceReduced {
            Text(formattedTime(etaDate))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.primary)
                .minimumScaleFactor(0.8)
                // 🌟 限制最大闊度，並強制靠左 (向鏡頭靠攏！)
                .frame(maxWidth: 36, alignment: .trailing)
        } else {
            Text(etaDate, style: .timer)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.blue)
                .minimumScaleFactor(0.8)
                // 🌟 限制最大闊度，並強制靠左 (向鏡頭靠攏！)
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
                            .font(.system(size: 24, weight: .bold)) // 🌟 按照要求設定為 24
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail) // 🌟 確保太長時尾部變 "..."
                        
                        Text(context.attributes.stationName)
                            .font(.system(size: 12, weight: .medium)) // 🌟 按照要求設定為 12
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail) // 🌟 確保太長時尾部變 "..."
                    }
                    
                    // 🌟 一個自然嘅 Spacer 撐開兩邊
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
                // MARK: - 靈動島展開狀態 (Expanded) - 增加舒適邊距
                
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.routeName)
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundColor(.red)
                        // 🌟 左邊路線牌：加 leading padding，推離左邊黑邊
                        .padding(.leading, 12)
                }
                
                DynamicIslandExpandedRegion(.trailing) {
                    SmartETABlock(etaDate: context.state.etaDate, bigSize: 22, smallSize: 12)
                        // 🌟 右邊倒數：加 trailing padding，推離右邊黑邊
                        .padding(.trailing, 12)
                }
                
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("往 \(context.attributes.destination) ∙ \(context.attributes.stationName)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // 🌟 底部文字：左右加 padding，同上面嘅元素對齊
                            .padding(.horizontal, 12)
                        
                        ProgressView(timerInterval: context.attributes.startTime...context.state.etaDate, countsDown: false)
                            .tint(.blue)
                            .labelsHidden()
                            // 🌟 進度條：左右加 padding，避免撐到極限
                            .padding(.horizontal, 12)
                    }
                    // 🌟 整個底部區塊：增加頂部同底部空間，唔好黐實個底
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
            } compactLeading: {
                // 將路線名變成一個類似 Icon 嘅「圓形/圓角徽章」！
                Text(context.attributes.routeName)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28) // 🌟 強制設定為標準 Icon 大細 (28x28)
                    .background(Color(red: 0.8, green: 0.1, blue: 0.1)) // KMB 紅色底
                    .clipShape(Circle()) // 🌟 剪裁成圓形 (或者用 RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: 36, alignment: .trailing)
            } compactTrailing: {
                // 緊湊右側 (保持唔變)
                CompactETABlock(etaDate: context.state.etaDate)
            } minimal: {
                Image(systemName: "bus.fill")
                    .foregroundColor(.red)
            }
        }
    }
}
