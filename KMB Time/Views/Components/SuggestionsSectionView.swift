import SwiftUI

struct SuggestionsSectionView: View {
    let suggestions: [RouteSuggestion]
    let allRoutes: [RouteSuggestion]
    let onSelected: (RouteSuggestion, String) -> Void
    
    var body: some View {
        // 🌟 直接用 Apple 原生嘅 Section，SwiftUI 會自動搞掂所有圓角同背景！
        Section {
            ForEach(suggestions, id: \.id) { suggestion in
                Button(action: {
                    let isJoint = JointRouteEvaluator.checkIsJoint(route: suggestion.route, allRoutes: allRoutes)
                    let finalCompany = isJoint ? "JOINT" : suggestion.co
                    onSelected(suggestion, finalCompany)
                }) {
                    HStack(spacing: 12) {
                        // 號碼牌
                        Text(suggestion.route)
                            .font(.system(.body, design: .rounded)).fontWeight(.bold)
                            .foregroundColor(.white)
                            .frame(width: 54, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(JointRouteEvaluator.fetchThemeColor(route: suggestion.route, originalCo: suggestion.co, allRoutes: allRoutes))
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
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4) // 原生 List 已經有 padding，呢度只需要微調
                }
                // 🌟 原生 List 會自動幫你加最靚嘅 Divider，唔使再自己畫！
            }
        } header: {
            Text("搜尋建議")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.gray)
        }
    }
}
