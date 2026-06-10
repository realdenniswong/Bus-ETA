/// 檔案用途：連接首頁 UI 操作同 ContentView 狀態。
import SwiftUI
import UserNotifications

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    var dashboardContentView: some View {
        DashboardView(
            locationManager: locationManager,
            searchText: $searchText,
            showCustomKeyboard: $showCustomKeyboard,
            activeTimer: activeTimer,
            currentTime: currentTime,
            allStops: allStops,
            nearbyStops: nearbyStops,
            allRoutes: allRoutes,
            searchSuggestions: searchSuggestions,
            validNextKeys: validNextKeys,
            selectedDirection: selectedDirection,
            isSearchingNearby: isSearchingNearby,
            onCancelTimer: cancelActiveTimer,
            onRequestLocation: { locationManager.requestLocation() },
            onRefreshLocationAndNearbyStops: refreshLocationAndNearbyStops,
            onSuggestedRouteSelected: openSuggestedRoute,
            onNearbyRouteSelected: { route, stopInfo in
                openNearbyDashboardRoute(route, stopInfo: stopInfo)
            },
            onSetNearbyTimer: prepareNearbyTimerAlert,
            onSearchRoute: { route, direction in
                isNavigatingToRoute = true
                Task { await searchRoute(route: route, direction: direction, findNearest: true, shouldScroll: true) }
            },
            onShowToast: showToast
        )
    }
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func cancelActiveTimer() {
        withAnimation(.easeInOut(duration: 0.3)) {
            activeTimer = nil
        }
        endLiveActivity()
        locationManager.stopBackgroundTracking()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["KMBTimeAlarm"])
    }
    
    /// 重新整理目前畫面需要嘅資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func refreshLocationAndNearbyStops() {
        locationManager.requestLocation()
        Task {
            if let location = locationManager.location {
                await updateNearbyStops(userLocation: location)
            }
        }
    }
    
    /// 開啟指定路線或畫面流程。
    /// - Parameters:
    ///   - suggestion: 此函式需要嘅輸入資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func openSuggestedRoute(_ suggestion: RouteSuggestion) {
        showCustomKeyboard = false
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            searchText = suggestion.route
            let newDirection = suggestion.bound.uppercased().hasPrefix("O") ? "outbound" : "inbound"
            selectedDirection = newDirection
            isNavigatingToRoute = true
            
            Task {
                await searchRoute(
                    route: suggestion.route.uppercased(),
                    direction: newDirection,
                    company: suggestion.co,
                    findNearest: true,
                    shouldScroll: true
                )
            }
        }
    }
    
    /// 開啟指定路線或畫面流程。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - stopInfo: 車站識別或車站資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func openNearbyDashboardRoute(_ route: NearbyRouteModel, stopInfo: StopInfo) {
        let detailDirectionCode = route.detailDirectionCode ?? route.directionCode
        let newDirection = detailDirectionCode == "O" ? "outbound" : "inbound"
        let targetStopCode = route.co == "KMB+CTB" ? stopInfo.stop : (route.displayStopId ?? stopInfo.stop)
        selectedDirection = newDirection
        searchText = route.route
        isNavigatingToRoute = true
        
        Task {
            await searchRoute(
                route: route.route,
                direction: newDirection,
                company: route.co,
                findNearest: false,
                targetStopCode: targetStopCode,
                shouldScroll: true
            )
        }
    }
    
    /// 準備稍後操作需要嘅資料同 UI 狀態。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - stopInfo: 車站識別或車站資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func prepareNearbyTimerAlert(route: NearbyRouteModel, stopInfo: StopInfo) {
        guard let firstEta = route.etas.first(where: { $0.etaDate ?? Date.distantFuture > Date() }),
              let etaDate = firstEta.etaDate else { return }
        prepareTimerAlert(
            route: route.route.uppercased(),
            destination: route.destNameTc,
            stationName: route.co == "KMB+CTB" ? stopInfo.name_tc : (route.displayStopName ?? stopInfo.name_tc),
            stopId: route.co == "KMB+CTB" ? stopInfo.stop : (route.displayStopId ?? stopInfo.stop),
            direction: route.directionCode == "O" ? "outbound" : "inbound",
            company: route.co,
            etaDate: etaDate
        )
    }
    
    /// 準備稍後操作需要嘅資料同 UI 狀態。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - destination: 畫面顯示文字。
    ///   - stationName: 車站識別或車站資料。
    ///   - stopId: 車站識別或車站資料。
    ///   - direction: 巴士方向資料。
    ///   - company: 巴士公司代碼。
    ///   - etaDate: 時間或到站時間資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func prepareTimerAlert(route: String, destination: String, stationName: String, stopId: String, direction: String, company: String = BusOperator.kmb.rawValue, etaDate: Date) {
        timerTargetDate = etaDate
        timerRouteName = route.uppercased()
        timerCompany = company
        timerStationName = stationName
        timerStopId = stopId
        timerDirection = direction
        timerDestination = destination
        showingAddTimerAlert = true
    }
}
