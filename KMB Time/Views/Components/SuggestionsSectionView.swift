/// 檔案用途：顯示搜尋建議路線清單。
import SwiftUI

/// `SuggestionsSectionView` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct SuggestionsSectionView: View {
    let suggestions: [RouteSuggestion]
    let allRoutes: [RouteSuggestion]
    let onSelected: (RouteSuggestion, String) -> Void
    
    var body: some View {
        // 🌟 直接用 Apple 原生嘅 Section，SwiftUI 會自動搞掂所有圓角同背景！
        Section {
            ForEach(suggestions, id: \.id) { suggestion in
                Button(action: {
                    onSelected(suggestion, suggestion.co)
                }) {
                    HStack(spacing: 12) {
                        // 號碼牌
                        Text(suggestion.route)
                            .font(.system(.body, design: .rounded)).fontWeight(.bold)
                            .foregroundColor(KMBRouteTheme.foregroundColor(route: suggestion.route, company: suggestion.co, allRoutes: allRoutes))
                            .frame(width: 54, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(KMBRouteTheme.backgroundColor(route: suggestion.route, company: suggestion.co, allRoutes: allRoutes))
                            )
                            .fixedSize()
                        
                        // 起訖站
                        VStack(alignment: .leading, spacing: 3) {
                            Text(suggestion.destination)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            Text("往 \(suggestion.origin)")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Text(companyDisplayName(suggestion.co))
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(KMBRouteTheme.color(route: suggestion.route, company: suggestion.co, allRoutes: allRoutes))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(KMBRouteTheme.color(route: suggestion.route, company: suggestion.co, allRoutes: allRoutes).opacity(0.12))
                            .cornerRadius(5)
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                // 🌟 原生 List 會自動幫你加最靚嘅 Divider，唔使再自己畫！
            }
        } header: {
            Text("搜尋建議")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.gray)
        }
        .alignedListSectionMargins(horizontal: 16)
    }
    
    /// 判斷指定條件是否成立。
    /// - Parameters:
    ///   - company: 巴士公司代碼。
    /// - Returns: 格式化或查找後嘅文字。
    private func companyDisplayName(_ company: String) -> String {
        switch company {
        case "KMB+CTB":
            return "聯營"
        case BusOperator.ctb.rawValue:
            return "城巴"
        default:
            return "九巴"
        }
    }
}
