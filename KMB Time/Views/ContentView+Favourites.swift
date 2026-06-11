/// 檔案用途：處理收藏分頁 UI 同收藏路線開啟流程。
import SwiftUI

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    var favoritesTab: some View {
        NavigationStack {
            FavouritesView(
                favoritesManager: favoritesManager,
                favoriteStatus: favoriteStatus,
                allRoutes: allRoutes,
                currentTime: currentTime,
                onOpenFavorite: { favorite in
                    openFavoriteRoute(favorite)
                },
                onSetTimer: { favorite, status, etaDate, company in
                    prepareTimerAlert(
                        route: favorite.route,
                        destination: favorite.destNameTc,
                        stationName: status.stopName,
                        stopId: status.stopId,
                        direction: favorite.direction,
                        company: company,
                        etaDate: etaDate,
                        operatorStopIds: status.operatorStopIds
                    )
                },
                onRefresh: {
                    await updateFavoriteETAs()
                }
            )
        }
        .task {
            if selectedTab == 1 {
                await updateFavoriteETAs()
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == 1 {
                Task { await updateFavoriteETAs() }
            }
        }
        .tabItem {
            Label("常用路線", systemImage: "star.fill")
        }
    }
    
    /// 開啟指定路線或畫面流程。
    /// - Parameters:
    ///   - favorite: 收藏路線資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func openFavoriteRoute(_ favorite: FavoriteRoute) {
        selectedTab = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let direction = BusDirection(rawValue: favorite.direction) ?? .outbound
            let company = routeSuggestionCatalog.resolvedCompany(
                route: favorite.route,
                direction: direction,
                preferredCompany: favorite.company
            )
            searchText = favorite.route
            selectedDirection = favorite.direction
            selectedCompany = company
            isNavigatingToRoute = true
            Task { await searchRoute(route: favorite.route, direction: favorite.direction, company: company, findNearest: true, shouldScroll: true) }
        }
    }
}
