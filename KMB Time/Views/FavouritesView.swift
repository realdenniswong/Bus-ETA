/// 檔案用途：顯示收藏路線清單、最近 ETA、距離同刪除操作。
import CoreLocation
import SwiftUI

/// `FavouritesView` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct FavouritesView: View {
    @ObservedObject var favoritesManager: FavoritesManager
    let favoriteStatus: [String: FavoriteStatusModel]
    let allRoutes: [RouteSuggestion]
    let currentTime: Date
    let onOpenFavorite: (FavoriteRoute) -> Void
    let onSetTimer: (FavoriteRoute, FavoriteStatusModel, Date, String) -> Void
    let onRefresh: () async -> Void
    
    var body: some View {
        List {
            if favoritesManager.favoriteRoutes.isEmpty {
                Text("您尚未加入任何常用路線。")
                    .foregroundColor(.secondary)
                    .padding()
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(sortedFavorites) { favorite in
                        favoriteRouteButton(favorite)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                favoriteSwipeActions(favorite)
                            }
                    }
                    .onDelete { indexSet in
                        let favoriteIdsToDelete = Set(indexSet.map { sortedFavorites[$0].id })
                        favoritesManager.favoriteRoutes.removeAll { favoriteIdsToDelete.contains($0.id) }
                    }
                }
                .alignedListSectionMargins(horizontal: 16)
            }
        }
        .navigationTitle("常用路線")
        .padding(.top, 16)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .refreshable {
            await onRefresh()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    Task { await onRefresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
    
    private var sortedFavorites: [FavoriteRoute] {
        favoritesManager.favoriteRoutes.sorted { first, second in
            let firstStatus = favoriteStatus[first.id]
            let secondStatus = favoriteStatus[second.id]
            
            let firstHasService = !(firstStatus?.etas.isEmpty ?? true)
            let secondHasService = !(secondStatus?.etas.isEmpty ?? true)
            if firstHasService != secondHasService {
                return firstHasService
            }
            
            let firstDistance = firstStatus?.distance ?? .infinity
            let secondDistance = secondStatus?.distance ?? .infinity
            if firstDistance != secondDistance {
                return firstDistance < secondDistance
            }
            
            if first.direction != second.direction {
                return first.direction == "inbound"
            }
            
            return first.route.localizedStandardCompare(second.route) == .orderedAscending
        }
    }
    
    @ViewBuilder
    /// 整理或查找路線相關資料。
    /// - Parameters:
    ///   - favorite: 收藏路線資料。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    private func favoriteRouteButton(_ favorite: FavoriteRoute) -> some View {
        let company = companyCode(for: favorite)
        Button(action: { onOpenFavorite(favorite) }) {
            HStack(alignment: .center, spacing: 12) {
                Text(favorite.route)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(KMBRouteTheme.foregroundColor(route: favorite.route, company: company, allRoutes: allRoutes))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 64, height: 52)
                    .background(RoundedRectangle(cornerRadius: 8).fill(KMBRouteTheme.backgroundColor(route: favorite.route, company: company, allRoutes: allRoutes)))
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("往")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(favorite.destNameTc)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let status = favoriteStatus[favorite.id] {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(status.stopName)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(formatDistance(status.distance))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text("正在尋找最近車站...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                if let status = favoriteStatus[favorite.id] {
                    etaCountdownView(etas: status.etas)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - favorite: 收藏路線資料。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    private func favoriteSwipeActions(_ favorite: FavoriteRoute) -> some View {
        Button(role: .destructive) {
            if let index = favoritesManager.favoriteRoutes.firstIndex(where: { $0.id == favorite.id }) {
                favoritesManager.favoriteRoutes.remove(at: index)
            }
        } label: {
            Label("刪除", systemImage: "trash")
        }
        
        if let status = favoriteStatus[favorite.id],
           let firstEta = status.etas.first(where: { $0.etaDate?.timeIntervalSince(Date()) ?? 0 > 120 }),
           let etaDate = firstEta.etaDate {
            let company = companyCode(for: favorite)
            Button {
                onSetTimer(favorite, status, etaDate, company)
            } label: {
                Label("設定提示", systemImage: "bell.fill")
            }
            .tint(.blue)
        }
    }
    
    /// 整理或查找巴士公司顯示資料。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    /// - Returns: 格式化或查找後嘅文字。
    private func companyCode(for favorite: FavoriteRoute) -> String {
        if favorite.company != BusOperator.kmb.rawValue {
            return favorite.company
        }
        let bound = (BusDirection(rawValue: favorite.direction) ?? .outbound).routeCode
        let matches = allRoutes.filter { suggestion in
            suggestion.route == favorite.route.uppercased() && suggestion.bound == bound
        }
        if matches.count == 1 {
            return matches[0].co
        }
        return matches.first(where: { $0.co == "KMB+CTB" })?.co ?? favorite.company
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    ///   - color: 畫面顏色。
    /// - Returns: 格式化或查找後嘅文字。
    private func relativeTimeText(for etas: [ETADisplayInfo]) -> (text: String, color: Color) {
        guard let firstEta = etas
            .compactMap(\.etaDate)
            .first(where: { $0 >= currentTime.addingTimeInterval(-60) }) else {
            return ("沒有班次", .secondary)
        }
        
        let diff = firstEta.timeIntervalSince(currentTime)
        if diff < 60 {
            return ("即將抵達", .red)
        }
        
        return ("\(Int(diff / 60)) 分鐘", .primary)
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - etas: 時間或到站時間資料。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    private func etaCountdownView(etas: [ETADisplayInfo]) -> some View {
        let etaInfo = relativeTimeText(for: etas)
        return Text(etaInfo.text)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(etaInfo.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(etaInfo.color.opacity(0.1))
            .cornerRadius(6)
    }
    
    /// 將資料格式化成畫面顯示文字。
    /// - Parameters:
    ///   - distance: 此函式需要嘅輸入資料。
    /// - Returns: 格式化或查找後嘅文字。
    private func formatDistance(_ distance: CLLocationDistance) -> String {
        if distance < 1000 {
            return String(format: "%.0f 米", distance)
        }
        return String(format: "%.1f 公里", distance / 1000)
    }
}
