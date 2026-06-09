import SwiftUI

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
                        stopId: "",
                        direction: favorite.direction,
                        company: company,
                        etaDate: etaDate
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
    
    /// Opens a saved favourite route in the route-detail screen.
    func openFavoriteRoute(_ favorite: FavoriteRoute) {
        selectedTab = 0
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            searchText = favorite.route
            selectedDirection = favorite.direction
            isNavigatingToRoute = true
            Task { await searchRoute(route: favorite.route, direction: favorite.direction, findNearest: true, shouldScroll: true) }
        }
    }
}
