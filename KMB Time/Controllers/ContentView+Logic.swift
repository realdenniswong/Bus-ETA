import ActivityKit
import CoreLocation
import SwiftUI
import UserNotifications

// MARK: - Controller / Business Logic
extension ContentView {
    /// Current bus-data adapter used by the app.
    ///
    /// Swap or compose providers here when CTB or other operators are added. The view code below
    /// should remain provider-agnostic.
    var busETAProvider: BusETAProvider {
        KMBETAProvider.shared
    }
    
    // MARK: - Route and Stop Loading
    
    /// Loads route suggestions from the active bus provider.
    func loadAllRoutes() async {
        do {
            let routeSuggestions = try await busETAProvider.fetchRouteSuggestions()
            await MainActor.run {
                self.allRoutes = routeSuggestions
            }
        } catch {
            print("Failed to load route suggestions: \(error)")
        }
    }
    
    /// Loads stops from the active bus provider and builds lookup dictionaries for the UI.
    func loadAllStops() async {
        do {
            let stops = try await busETAProvider.fetchStops()
            let stopNamesById = Dictionary(uniqueKeysWithValues: stops.map { ($0.stop, $0.name_tc) })
            let stopInfoById = Dictionary(uniqueKeysWithValues: stops.map { ($0.stop, $0) })
            
            await MainActor.run {
                self.allStops = stops
                self.stopDictionary = stopNamesById
                self.stopInfoDictionary = stopInfoById
            }
            
            if let userLocation = locationManager.location {
                await updateNearbyStops(userLocation: userLocation)
            }
        } catch {
            print("Failed to load stops: \(error)")
        }
    }
    
    // MARK: - Nearby Dashboard
    
    /// Rebuilds the nearby dashboard from the user's current location.
    ///
    /// - Parameter userLocation: Latest location reported by `LocationManager`.
    func updateNearbyStops(userLocation: CLLocation) async {
        guard !allStops.isEmpty else { return }
        
        await MainActor.run { isSearchingNearby = true }
        
        let nearestStops = nearestStopModels(from: allStops, userLocation: userLocation, limit: 10)
        var nearbyStopsWithRoutes: [NearbyStopModel] = []
        
        for var nearbyStop in nearestStops {
            nearbyStop.routes = await fetchRoutesForStop(stopId: nearbyStop.stopInfo.stop)
            nearbyStopsWithRoutes.append(nearbyStop)
        }
        
        await MainActor.run {
            self.nearbyStops = nearbyStopsWithRoutes
            self.isSearchingNearby = false
        }
    }
    
    /// Refreshes ETA rows for the stops already displayed on the nearby dashboard.
    func refreshNearbyETAs() async {
        guard !nearbyStops.isEmpty else { return }
        await MainActor.run { isSearchingNearby = true }
        
        var refreshedStops = nearbyStops
        for index in refreshedStops.indices {
            refreshedStops[index].routes = await fetchRoutesForStop(stopId: refreshedStops[index].stopInfo.stop)
        }
        
        await MainActor.run {
            self.nearbyStops = refreshedStops
            self.isSearchingNearby = false
        }
    }
    
    /// Fetches provider route cards for one stop.
    ///
    /// - Parameter stopId: Provider-specific stop identifier.
    /// - Returns: Dashboard route cards, or an empty array when the request fails.
    func fetchRoutesForStop(stopId: String) async -> [NearbyRouteModel] {
        do {
            return try await busETAProvider.fetchNearbyRoutes(forStopId: stopId)
        } catch {
            print("Failed to fetch nearby routes for stop \(stopId): \(error)")
            return []
        }
    }
    
    /// Builds nearest-stop models using provider stops already cached in memory.
    ///
    /// - Parameters:
    ///   - stops: Stops with valid coordinates.
    ///   - userLocation: Current user location.
    ///   - limit: Maximum number of nearest stops to return.
    /// - Returns: Stops sorted by distance from the user.
    private func nearestStopModels(from stops: [StopInfo], userLocation: CLLocation, limit: Int) -> [NearbyStopModel] {
        stops
            .compactMap { stop -> NearbyStopModel? in
                guard let stopLocation = stop.clLocation else { return nil }
                return NearbyStopModel(stopInfo: stop, distance: userLocation.distance(from: stopLocation))
            }
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .map { $0 }
    }
    
    // MARK: - Route Search
    
    /// Loads the stop-by-stop timetable for one route direction.
    ///
    /// - Parameters:
    ///   - route: Route number, for example `1A`.
    ///   - direction: Optional app direction string, either `outbound` or `inbound`.
    ///   - company: Reserved for future multi-provider selection. Current provider is KMB.
    ///   - findNearest: When true, highlights the nearest stop on the loaded route.
    ///   - targetStopCode: Optional stop id to highlight, usually from dashboard navigation.
    ///   - shouldScroll: Whether the route-detail screen should scroll to the highlighted stop.
    ///   - isRefresh: When true, keeps current rows visible while refreshing.
    func searchRoute(route: String, direction: String? = nil, company: String? = nil, findNearest: Bool = false, targetStopCode: String? = nil, shouldScroll: Bool = false, isRefresh: Bool = false) async {
        guard !route.isEmpty else { return }
        
        let selectedBusDirection = BusDirection(rawValue: direction ?? selectedDirection) ?? .outbound
        
        await MainActor.run {
            if let direction {
                self.selectedDirection = direction
            }
            self.selectedCompany = busETAProvider.operatorCode.rawValue
            if !isRefresh {
                isLoading = true
                displayData = []
                highlightedStopId = nil
            }
        }
        
        do {
            let timetableRows = try await busETAProvider.fetchTimetableRows(
                route: route,
                direction: selectedBusDirection,
                stopNameById: stopDictionary
            )
            let highlightStopId = highlightedStopIdForRouteSearch(
                rows: timetableRows,
                findNearest: findNearest,
                targetStopCode: targetStopCode
            )
            
            await MainActor.run {
                self.highlightedStopId = highlightStopId
                if timetableRows.isEmpty {
                    systemMessage = "沒有找到路線 \(route) 的 \(selectedBusDirection.rawValue == "outbound" ? "去程" : "回程") 班次數據。"
                    if !isRefresh { displayData = [] }
                } else {
                    displayData = timetableRows
                }
                if shouldScroll { self.scrollTriggerId = UUID() }
                if !isRefresh { isLoading = false }
            }
        } catch {
            await MainActor.run {
                systemMessage = "無法加載數據或找不到此路線。"
                if !isRefresh {
                    displayData = []
                    isLoading = false
                }
            }
        }
    }
    
    /// Chooses which timetable row should be highlighted after a route search completes.
    ///
    /// - Parameters:
    ///   - rows: Timetable rows returned from the selected route direction.
    ///   - findNearest: Whether to choose the nearest row to the user's current location.
    ///   - targetStopCode: Optional stop id requested by dashboard or favourites navigation.
    /// - Returns: The `StopDisplayModel.id` for the best row to highlight, or `nil` when no match exists.
    private func highlightedStopIdForRouteSearch(rows: [StopDisplayModel], findNearest: Bool, targetStopCode: String?) -> String? {
        if findNearest, let userLocation = locationManager.location {
            return rows.min { firstCandidate, secondCandidate in
                let firstDistance = distanceFromLocation(userLocation, to: firstCandidate)
                let secondDistance = distanceFromLocation(userLocation, to: secondCandidate)
                return firstDistance < secondDistance
            }?.id
        }
        
        guard let targetStopCode else {
            return highlightedStopId
        }
        
        if let exactMatch = rows.first(where: { $0.stopId == targetStopCode }) {
            return exactMatch.id
        }
        
        let targetStopName = normalizedStopName(stopInfoDictionary[targetStopCode]?.name_tc ?? "")
        if let nameMatch = rows.first(where: { row in
            !targetStopName.isEmpty && normalizedStopName(row.stopNameTc) == targetStopName
        }) {
            return nameMatch.id
        }
        
        guard let targetLocation = stopInfoDictionary[targetStopCode]?.clLocation else { return nil }
        return rows.min { firstCandidate, secondCandidate in
            let firstDistance = distanceFromLocation(targetLocation, to: firstCandidate)
            let secondDistance = distanceFromLocation(targetLocation, to: secondCandidate)
            return firstDistance < secondDistance
        }?.id
    }
    
    /// Removes terminal bracket text from a stop name before fuzzy stop-name matching.
    ///
    /// - Parameter stopName: Raw Chinese stop name.
    /// - Returns: Name normalized for matching nearby dashboard stops to timetable rows.
    private func normalizedStopName(_ stopName: String) -> String {
        stopName.replacingOccurrences(
            of: "\\s*\\([^)]+\\)\\s*$",
            with: "",
            options: .regularExpression
        )
    }
    
    /// Measures how far a timetable row is from a reference location.
    ///
    /// - Parameters:
    ///   - location: User or target stop location used as the distance origin.
    ///   - stop: Timetable row whose stop location should be compared.
    /// - Returns: Distance in meters, or `.infinity` when the stop has no known coordinates.
    private func distanceFromLocation(_ location: CLLocation, to stop: StopDisplayModel) -> CLLocationDistance {
        let stopLocation = stop.location ?? stopInfoDictionary[stop.stopId]?.clLocation ?? allStops.first(where: { $0.stop == stop.stopId })?.clLocation
        return stopLocation.map { location.distance(from: $0) } ?? .infinity
    }
    
    // MARK: - Timers and Live Activity
    
    /// Refreshes the active timer with the provider's latest ETA for the tracked stop.
    func syncActiveTimer() async {
        guard let timer = activeTimer, !timer.stopId.isEmpty else { return }
        let timerDirection = BusDirection(rawValue: timer.direction) ?? .outbound
        
        do {
            let etas = try await busETAProvider.fetchTimerETAs(route: timer.routeName, direction: timerDirection, stopId: timer.stopId)
            guard let newEtaDate = etas.first?.etaDate else { return }
            
            let difference = abs(newEtaDate.timeIntervalSince(timer.etaDate))
            guard difference > 10 else { return }
            
            await MainActor.run {
                withAnimation {
                    self.activeTimer?.etaDate = newEtaDate
                    self.activeTimer?.targetAlertDate = newEtaDate.addingTimeInterval(-120)
                }
            }
            
            let alertDate = newEtaDate.addingTimeInterval(-120)
            if alertDate.timeIntervalSince(Date()) > 0 {
                scheduleLocalNotification(routeName: timer.routeName, destination: timer.destination, alertDate: alertDate)
            }
            updateLiveActivity(etaDate: newEtaDate)
        } catch {
            print("Active timer sync failed: \(error)")
        }
    }
    
    /// Pushes a new ETA state to any running Live Activity.
    ///
    /// - Parameter etaDate: Latest estimated arrival time for the tracked bus.
    func updateLiveActivity(etaDate: Date) {
        Task {
            for activity in Activity<BusETAAttributes>.activities {
                let remaining = Int(etaDate.timeIntervalSince(Date()))
                let state = BusETAAttributes.ContentState(etaDate: etaDate, remainingSeconds: remaining)
                let expireDate = etaDate.addingTimeInterval(60)
                await activity.update(ActivityContent(state: state, staleDate: expireDate))
            }
        }
    }
    
    /// Formats an optional date for alert copy.
    ///
    /// - Parameter date: Date to display in `HH:mm` format.
    /// - Returns: A time string, or an empty string when `date` is nil.
    func formattedTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    /// Schedules the single local reminder used by the active timer.
    ///
    /// - Parameters:
    ///   - routeName: Route number shown in the notification body.
    ///   - destination: Destination name shown in the notification body.
    ///   - alertDate: Date when the notification should fire.
    func scheduleLocalNotification(routeName: String, destination: String, alertDate: Date) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["KMBTimeAlarm"])
        
        let content = UNMutableNotificationContent()
        content.title = "巴士即將抵達！"
        content.body = "您設定的 \(routeName) (往 \(destination)) 巴士即將在 2 分鐘內抵達，請準備上車。"
        content.sound = .default
        
        let timeInterval = alertDate.timeIntervalSince(Date())
        guard timeInterval > 0 else { return }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
        let request = UNNotificationRequest(identifier: "KMBTimeAlarm", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
    
    /// Starts a Live Activity for the selected ETA reminder.
    ///
    /// - Parameters:
    ///   - routeName: Route number displayed in the Live Activity.
    ///   - destination: Destination displayed in the Live Activity.
    ///   - stationName: Stop name displayed in the Live Activity.
    ///   - etaDate: Estimated arrival time being tracked.
    ///   - startTime: Time when the user created the reminder.
    func startLiveActivity(routeName: String, destination: String, stationName: String, etaDate: Date, startTime: Date) {
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                let attributes = BusETAAttributes(routeName: routeName, destination: destination, stationName: stationName, startTime: startTime)
                let remaining = Int(etaDate.timeIntervalSince(Date()))
                let state = BusETAAttributes.ContentState(etaDate: etaDate, remainingSeconds: remaining)
                let content = ActivityContent(state: state, staleDate: etaDate.addingTimeInterval(60))
                let _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                print("Error starting Live Activity: \(error.localizedDescription)")
            }
        }
    }
    
    /// Ends every Live Activity created by this app.
    func endLiveActivity() {
        Task {
            for activity in Activity<BusETAAttributes>.activities {
                let state = BusETAAttributes.ContentState(etaDate: activity.content.state.etaDate, remainingSeconds: 0)
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
    
    /// Rehydrates `activeTimer` from an existing Live Activity after app launch or foregrounding.
    func reconnectActiveLiveActivity() {
        for activity in Activity<BusETAAttributes>.activities {
            let attributes = activity.attributes
            let state = activity.content.state
            
            if state.etaDate.timeIntervalSince(Date()) > 0 {
                if self.activeTimer == nil {
                    self.activeTimer = ActiveTimerModel(
                        routeName: attributes.routeName,
                        destination: attributes.destination,
                        etaDate: state.etaDate,
                        targetAlertDate: state.etaDate.addingTimeInterval(-120),
                        startTime: attributes.startTime,
                        stopId: "",
                        direction: "",
                        stationName: attributes.stationName
                    )
                }
            } else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }
    
    // MARK: - Favorites
    
    /// Refreshes ETA and nearest-stop status for every saved favourite route.
    func updateFavoriteETAs() async {
        guard let userLocation = locationManager.location else { return }
        
        let context = RouteStopLookupContext(userLocation: userLocation, stopInfoById: stopInfoDictionary)
        let favorites = favoritesManager.favoriteRoutes
        var statuses: [String: FavoriteStatusModel] = [:]
        
        for favorite in favorites {
            do {
                if let status = try await busETAProvider.fetchFavoriteStatus(for: favorite, context: context) {
                    statuses[favorite.id] = status
                }
            } catch {
                print("Failed to refresh favourite \(favorite.id): \(error)")
            }
        }
        
        await MainActor.run {
            self.favoriteStatus = statuses
        }
    }
}
