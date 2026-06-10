/// 檔案用途：定義 Live Activity / widget 顯示區塊同配色。
import WidgetKit
import SwiftUI
import ActivityKit

@main
/// `BusETAWidgetBundle` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct BusETAWidgetBundle: WidgetBundle {
    var body: some Widget {
        BusETAWidget()
    }
}

// MARK: - 🌟 智能顯示組件 (修正版：完全移除「即將到達」與「到達」字眼)
/// `SmartETABlock` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
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
/// `CompactETABlock` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
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

/// 將資料格式化成畫面顯示文字。
/// - Parameters:
///   - date: 時間或到站時間資料。
/// - Returns: 格式化或查找後嘅文字。
fileprivate func formattedTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

/// `RouteBadgeTheme` 列出此功能範圍會用到嘅固定選項。
private enum RouteBadgeTheme {
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - company: 巴士公司代碼。
    /// - Returns: 畫面應使用嘅顏色。
    static func backgroundColor(company: String) -> Color {
        switch company {
        case "CTB":
            return Color(red: 247 / 255, green: 222 / 255, blue: 6 / 255)
        case "KMB+CTB":
            return Color(red: 0.12, green: 0.32, blue: 0.58)
        default:
            return Color(red: 0.65, green: 0.08, blue: 0.12)
        }
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - company: 巴士公司代碼。
    /// - Returns: 畫面應使用嘅顏色。
    static func foregroundColor(company: String) -> Color {
        company == "CTB" ? Color(red: 1 / 255, green: 93 / 255, blue: 166 / 255) : .white
    }
}

// MARK: - Widget 定義
/// `BusETAWidget` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct BusETAWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BusETAAttributes.self) { context in
            // MARK: - 鎖屏 / 通知中心 Banner
            VStack(spacing: 16) {
                
                HStack(alignment: .center, spacing: 10) {
                    
                    // 1. 左邊：精緻嘅路線徽章
                    Text(context.attributes.routeName)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(minWidth: 44)
                        .padding(.horizontal, 8)
                        .frame(height: 36)
                        .background(RouteBadgeTheme.backgroundColor(company: context.attributes.company))
                        .foregroundColor(RouteBadgeTheme.foregroundColor(company: context.attributes.company))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    
                    // 2. 中間：目的地與車站名
                    VStack(alignment: .leading, spacing: 2) {
                        Text("往 \(context.attributes.destination)")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        
                        Text(context.attributes.stationName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
                    .layoutPriority(1)
                    
                    // 3. 右邊：清晰倒數計時
                    SmartETABlock(etaDate: context.state.etaDate, bigSize: 18, smallSize: 11)
                        .frame(width: 68, height: 36, alignment: .trailing)
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
                        .foregroundColor(RouteBadgeTheme.foregroundColor(company: context.attributes.company))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RouteBadgeTheme.backgroundColor(company: context.attributes.company))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .foregroundColor(RouteBadgeTheme.foregroundColor(company: context.attributes.company))
                    .frame(width: 28, height: 28)
                    .background(RouteBadgeTheme.backgroundColor(company: context.attributes.company))
                    .clipShape(Circle())
                    .frame(maxWidth: 36, alignment: .trailing)
            } compactTrailing: {
                CompactETABlock(etaDate: context.state.etaDate)
            } minimal: {
                Image(systemName: "bus.fill")
                    .foregroundColor(RouteBadgeTheme.backgroundColor(company: context.attributes.company))
            }
        }
    }
}
