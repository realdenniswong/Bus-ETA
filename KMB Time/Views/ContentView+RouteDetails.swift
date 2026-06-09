import SwiftUI

extension ContentView {
    var routeDetailView: some View {
        RouteDetailsView(
            selectedDirection: $selectedDirection,
            routeName: searchText,
            selectedCompany: selectedCompany,
            displayData: displayData,
            highlightedStopId: highlightedStopId,
            currentTime: currentTime,
            isLoading: isLoading,
            systemMessage: systemMessage,
            scrollTriggerId: scrollTriggerId,
            isFavorite: favoritesManager.isFavorite(route: searchText.uppercased(), direction: selectedDirection, company: selectedCompany),
            onDirectionChanged: { newValue in
                if !searchText.isEmpty {
                    Task { await searchRoute(route: searchText.uppercased(), direction: newValue, company: selectedCompany, findNearest: true, shouldScroll: true) }
                }
            },
            onSetTimer: { stop, etaDate in
                prepareRouteDetailTimerAlert(stop: stop, etaDate: etaDate)
            },
            onToggleFavorite: toggleCurrentRouteFavorite,
            onRefresh: {
                Task {
                    await searchRoute(route: searchText.uppercased(), direction: selectedDirection, company: selectedCompany, findNearest: false, shouldScroll: false, isRefresh: true)
                }
            }
        )
    }
    
    /// Prepares the reminder alert from a timetable row selected in route detail.
    ///
    /// - Parameters:
    ///   - stop: Timetable stop row selected by the user.
    ///   - etaDate: ETA chosen for reminder tracking.
    func prepareRouteDetailTimerAlert(stop: StopDisplayModel, etaDate: Date) {
        let boundPrefix = selectedDirection == "outbound" ? "O" : "I"
        let matchedRoute = allRoutes.first(where: { $0.route == searchText.uppercased() && $0.bound == boundPrefix })
        
        prepareTimerAlert(
            route: searchText.uppercased(),
            destination: matchedRoute?.destination ?? "終點站",
            stationName: stop.stopNameTc,
            stopId: stop.stopId,
            direction: selectedDirection == "outbound" ? "outbound" : "inbound",
            company: selectedCompany,
            etaDate: etaDate
        )
    }
    
    /// Adds or removes the currently visible route direction from favourites.
    func toggleCurrentRouteFavorite() {
        let isFavorite = favoritesManager.isFavorite(route: searchText.uppercased(), direction: selectedDirection, company: selectedCompany)
        let boundPrefix = selectedDirection == "outbound" ? "O" : "I"
        let matchedRoute = allRoutes.first(where: { $0.route == searchText.uppercased() && $0.bound == boundPrefix })
        let destination = matchedRoute?.destination ?? "終點站"
        
        favoritesManager.toggleFavorite(route: searchText.uppercased(), direction: selectedDirection, destName: destination, company: selectedCompany)
        showToast(isFavorite ? "已從常用路線移除" : "已加入常用路線")
    }
}
