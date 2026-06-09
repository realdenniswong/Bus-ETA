import SwiftUI
import UserNotifications

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
    
    /// Cancels the active dashboard reminder and clears matching system state.
    func cancelActiveTimer() {
        withAnimation(.easeInOut(duration: 0.3)) {
            activeTimer = nil
        }
        endLiveActivity()
        locationManager.stopBackgroundTracking()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["KMBTimeAlarm"])
    }
    
    /// Requests a fresh device location and refreshes nearby stops when a location is already available.
    func refreshLocationAndNearbyStops() {
        locationManager.requestLocation()
        Task {
            if let location = locationManager.location {
                await updateNearbyStops(userLocation: location)
            }
        }
    }
    
    /// Opens the route-detail screen from a search suggestion row.
    ///
    /// - Parameter suggestion: Selected route direction from `searchSuggestions`.
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
    
    /// Opens the route-detail screen from a nearby dashboard route row.
    ///
    /// - Parameters:
    ///   - route: Route row selected from the nearby dashboard.
    ///   - stopInfo: Dashboard stop used as the target highlight in the timetable.
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
    
    /// Prepares the timer confirmation alert from a nearby dashboard route row.
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
    
    /// Fills the pending timer fields before showing the confirmation alert.
    ///
    /// - Parameters:
    ///   - route: Route number selected by the user.
    ///   - destination: Route destination shown in the alert and Live Activity.
    ///   - stationName: Stop name shown in the alert and Live Activity.
    ///   - stopId: Stop id used for future ETA refreshes.
    ///   - direction: Direction string, either `outbound` or `inbound`.
    ///   - etaDate: ETA that the user wants to track.
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
