/// 檔案用途：處理路線詳情畫面 UI 同計時器/收藏操作。
import SwiftUI

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
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
    
    /// 準備稍後操作需要嘅資料同 UI 狀態。
    /// - Parameters:
    ///   - stop: 車站識別或車站資料。
    ///   - etaDate: 時間或到站時間資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
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
            etaDate: etaDate,
            operatorStopIds: stop.operatorStopIds
        )
    }
    
    /// 切換指定項目嘅狀態。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func toggleCurrentRouteFavorite() {
        let isFavorite = favoritesManager.isFavorite(route: searchText.uppercased(), direction: selectedDirection, company: selectedCompany)
        let boundPrefix = selectedDirection == "outbound" ? "O" : "I"
        let matchedRoute = allRoutes.first(where: { $0.route == searchText.uppercased() && $0.bound == boundPrefix })
        let destination = matchedRoute?.destination ?? "終點站"
        
        favoritesManager.toggleFavorite(route: searchText.uppercased(), direction: selectedDirection, destName: destination, company: selectedCompany)
        showToast(isFavorite ? "已從常用路線移除" : "已加入常用路線")
    }
}
