import SwiftUI
import CoreLocation
import Combine
import UserNotifications
import ActivityKit

// MARK: - Controller / Business Logic
extension ContentView {
    
    // MARK: - Route Loading
    func loadAllRoutes() async {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route/") else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(KMBRoutesResponse.self, from: data)
            
            let sortedRoutes = response.data
                .map {
                    RouteSuggestion(
                        co: "KMB",
                        route: $0.route,
                        bound: $0.bound,
                        origin: $0.orig_tc,
                        destination: $0.dest_tc
                    )
                }
                .sorted {
                    if $0.route == $1.route {
                        return $0.bound > $1.bound
                    }
                    return $0.route.localizedStandardCompare($1.route) == .orderedAscending
                }
            
            await MainActor.run {
                self.allRoutes = sortedRoutes
            }
        } catch {
            print("Failed to load KMB routes: \(error)")
        }
    }
    
    func loadAllStops() async {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop/") else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(StopResponse.self, from: data)
            
            var stopNames: [String: String] = [:]
            var stopInfo: [String: StopInfo] = [:]
            
            for stop in response.data {
                guard let latString = stop.lat,
                      let longString = stop.long,
                      let latitude = Double(latString),
                      let longitude = Double(longString),
                      latitude != 0.0,
                      longitude != 0.0 else {
                    continue
                }
                
                stopNames[stop.stop] = stop.name_tc
                stopInfo[stop.stop] = stop
            }
            
            await MainActor.run {
                self.allStops = Array(stopInfo.values)
                self.stopDictionary = stopNames
                self.stopInfoDictionary = stopInfo
            }
            
            if let userLocation = locationManager.location {
                await updateNearbyStops(userLocation: userLocation)
            }
        } catch {
            print("Failed to load KMB stops: \(error)")
        }
    }
    
    func updateNearbyStops(userLocation: CLLocation) async {
        guard !allStops.isEmpty else { return }
        
        await MainActor.run { isSearchingNearby = true }
        
        let sorted = allStops
            .compactMap { stop -> NearbyStopModel? in
                guard let stopLocation = stop.clLocation else { return nil }
                return NearbyStopModel(stopInfo: stop, distance: userLocation.distance(from: stopLocation))
            }
            .sorted { $0.distance < $1.distance }
            .prefix(10)
        
        var populated: [NearbyStopModel] = []
        for var stopModel in sorted {
            stopModel.routes = await fetchRoutesForStop(stopId: stopModel.stopInfo.stop)
            populated.append(stopModel)
        }
        
        await MainActor.run {
            self.nearbyStops = populated
            self.isSearchingNearby = false
        }
    }
    
    func refreshNearbyETAs() async {
        guard !nearbyStops.isEmpty else { return }
        await MainActor.run { isSearchingNearby = true }
        
        var updatedStops = nearbyStops
        for index in updatedStops.indices {
            updatedStops[index].routes = await fetchRoutesForStop(stopId: updatedStops[index].stopInfo.stop)
        }
        
        await MainActor.run {
            self.nearbyStops = updatedStops
            self.isSearchingNearby = false
        }
    }
    
    func fetchRoutesForStop(stopId: String) async -> [NearbyRouteModel] {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/\(stopId)") else { return [] }
        
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(StopETAResponse.self, from: data)
            let formatter = ISO8601DateFormatter()
            
            let groupedItems = Dictionary(grouping: response.data.filter { $0.service_type == 1 }) { item in
                "\(item.route)-\(item.dir)"
            }
            
            let routes = groupedItems.compactMap { key, items -> NearbyRouteModel? in
                guard let firstItem = items.first else { return nil }
                let parts = key.components(separatedBy: "-")
                guard parts.count >= 2 else { return nil }
                
                let etas = items.compactMap { item -> ETADisplayInfo? in
                    guard let eta = item.eta, !eta.isEmpty, let date = formatter.date(from: eta) else { return nil }
                    return ETADisplayInfo(etaDate: date, remark: item.rmk_tc)
                }
                .sorted { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
                
                return NearbyRouteModel(
                    co: "KMB",
                    route: parts[0],
                    directionCode: parts[1],
                    destNameTc: firstItem.dest_tc,
                    etas: Array(etas.prefix(3))
                )
            }
            
            return routes.sorted { $0.route.localizedStandardCompare($1.route) == .orderedAscending }
        } catch {
            print("Failed to fetch KMB routes for stop \(stopId): \(error)")
            return []
        }
    }
    
    // MARK: - Route Search
    func searchRoute(route: String, direction: String? = nil, company: String? = nil, findNearest: Bool = false, targetStopCode: String? = nil, shouldScroll: Bool = false, isRefresh: Bool = false) async {
        guard !route.isEmpty else { return }
        
        let currentDirection = direction ?? self.selectedDirection
        let targetDirectionCode = currentDirection == "outbound" ? "O" : "I"
        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
        
        await MainActor.run {
            if let newDirection = direction {
                self.selectedDirection = newDirection
            }
            self.selectedCompany = "KMB"
            if !isRefresh {
                isLoading = true
                displayData = []
                highlightedStopId = nil
            }
        }
        
        do {
            let routeStopUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-stop/\(safeRoute)/\(currentDirection)/1")!
            var routeStopRequest = URLRequest(url: routeStopUrl)
            routeStopRequest.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (routeStopData, _) = try await URLSession.shared.data(for: routeStopRequest)
            let routeStops = try JSONDecoder().decode(RouteStopResponse.self, from: routeStopData).data
            
            var results: [StopDisplayModel] = []
            for routeStop in routeStops {
                let stopId = routeStop.stop
                let seq = Int(routeStop.seq) ?? 0
                let stopName = stopInfoDictionary[stopId]?.name_tc ?? stopDictionary[stopId] ?? "未知車站"
                
                var etas: [ETADisplayInfo] = []
                if let stopEtaUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/\(stopId)"),
                   let (etaData, _) = try? await URLSession.shared.data(from: stopEtaUrl),
                   let etaResponse = try? JSONDecoder().decode(StopETAResponse.self, from: etaData) {
                    let formatter = ISO8601DateFormatter()
                    etas = etaResponse.data.compactMap { item in
                        guard item.route == route,
                              item.dir == targetDirectionCode,
                              item.service_type == 1,
                              let eta = item.eta,
                              !eta.isEmpty,
                              let date = formatter.date(from: eta) else {
                            return nil
                        }
                        return ETADisplayInfo(etaDate: date, remark: item.rmk_tc)
                    }
                    .sorted { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
                }
                
                results.append(StopDisplayModel(seq: seq, stopId: stopId, stopNameTc: stopName, etas: Array(etas.prefix(3))))
            }
            results.sort { $0.seq < $1.seq }
            
            let targetId = routeSearchTargetId(results: results, findNearest: findNearest, targetStopCode: targetStopCode)
            
            await MainActor.run {
                self.highlightedStopId = targetId
                if results.isEmpty {
                    systemMessage = "沒有找到路線 \(route) 的 \(currentDirection == "outbound" ? "去程" : "回程") 班次數據。"
                    if !isRefresh { displayData = [] }
                } else {
                    displayData = results
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
    
    private func routeSearchTargetId(results: [StopDisplayModel], findNearest: Bool, targetStopCode: String?) -> String? {
        if findNearest, let userLocation = locationManager.location {
            return results.min { lhs, rhs in
                let lhsDistance = distance(from: userLocation, to: lhs)
                let rhsDistance = distance(from: userLocation, to: rhs)
                return lhsDistance < rhsDistance
            }?.id
        }
        
        guard let targetStopCode else {
            return highlightedStopId
        }
        
        if let exactMatch = results.first(where: { $0.stopId == targetStopCode }) {
            return exactMatch.id
        }
        
        let targetName = stopInfoDictionary[targetStopCode]?.name_tc.replacingOccurrences(
            of: "\\s*\\([^)]+\\)\\s*$",
            with: "",
            options: .regularExpression
        ) ?? ""
        
        if let nameMatch = results.first(where: { result in
            let resultName = result.stopNameTc.replacingOccurrences(
                of: "\\s*\\([^)]+\\)\\s*$",
                with: "",
                options: .regularExpression
            )
            return !targetName.isEmpty && resultName == targetName
        }) {
            return nameMatch.id
        }
        
        guard let targetLocation = stopInfoDictionary[targetStopCode]?.clLocation else { return nil }
        return results.min { lhs, rhs in
            let lhsDistance = distance(from: targetLocation, to: lhs)
            let rhsDistance = distance(from: targetLocation, to: rhs)
            return lhsDistance < rhsDistance
        }?.id
    }
    
    private func distance(from location: CLLocation, to stop: StopDisplayModel) -> CLLocationDistance {
        let stopLocation = stop.location ?? stopInfoDictionary[stop.stopId]?.clLocation ?? allStops.first(where: { $0.stop == stop.stopId })?.clLocation
        return stopLocation.map { location.distance(from: $0) } ?? .infinity
    }
    
    // MARK: - Timers and Live Activity
    func syncActiveTimer() async {
        guard let timer = activeTimer, !timer.stopId.isEmpty else { return }
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/\(timer.stopId)") else { return }
        
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(StopETAResponse.self, from: data)
            
            let targetDirectionCode = timer.direction == "outbound" ? "O" : "I"
            let matchedItems = response.data.filter { $0.route == timer.routeName && $0.dir == targetDirectionCode }
            let sortedItems = matchedItems.sorted { $0.eta_seq < $1.eta_seq }
            
            let dateFormatter = ISO8601DateFormatter()
            if let firstEtaItem = sortedItems.first,
               let etaString = firstEtaItem.eta,
               let newEtaDate = dateFormatter.date(from: etaString) {
                let difference = abs(newEtaDate.timeIntervalSince(timer.etaDate))
                if difference > 10 {
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
                }
            }
        } catch {
            print("Active timer sync failed: \(error)")
        }
    }
    
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
    
    func formattedTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
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
    
    func endLiveActivity() {
        Task {
            for activity in Activity<BusETAAttributes>.activities {
                let state = BusETAAttributes.ContentState(etaDate: activity.content.state.etaDate, remainingSeconds: 0)
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
    
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
    func updateFavoriteETAs() async {
        guard let userLocation = locationManager.location else { return }
        
        let favorites = favoritesManager.favoriteRoutes
        var statuses: [String: FavoriteStatusModel] = [:]
        
        for favorite in favorites {
            if let status = await favoriteStatus(for: favorite, userLocation: userLocation) {
                statuses[favorite.id] = status
            }
        }
        
        await MainActor.run {
            self.favoriteStatus = statuses
        }
    }
    
    private func favoriteStatus(for favorite: FavoriteRoute, userLocation: CLLocation) async -> FavoriteStatusModel? {
        let route = favorite.route
        let direction = favorite.direction
        let directionCode = direction == "outbound" ? "O" : "I"
        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
        
        guard let routeStopUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-stop/\(safeRoute)/\(direction)/1"),
              let (routeStopData, _) = try? await URLSession.shared.data(from: routeStopUrl),
              let routeStopResponse = try? JSONDecoder().decode(RouteStopResponse.self, from: routeStopData) else {
            return nil
        }
        
        var nearestStopId: String?
        var nearestStopName = "未知車站"
        var nearestDistance: CLLocationDistance = .infinity
        
        for routeStop in routeStopResponse.data {
            let stopInfo = await MainActor.run { self.stopInfoDictionary[routeStop.stop] }
            guard let stopLocation = stopInfo?.clLocation else { continue }
            
            let distance = userLocation.distance(from: stopLocation)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestStopId = routeStop.stop
                nearestStopName = stopInfo?.name_tc ?? "未知車站"
            }
        }
        
        guard let nearestStopId,
              let etaUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/\(nearestStopId)"),
              let (etaData, _) = try? await URLSession.shared.data(from: etaUrl),
              let etaResponse = try? JSONDecoder().decode(StopETAResponse.self, from: etaData) else {
            return nil
        }
        
        let formatter = ISO8601DateFormatter()
        let etas = etaResponse.data.compactMap { item -> ETADisplayInfo? in
            guard item.route == route,
                  item.dir == directionCode,
                  item.service_type == 1,
                  let eta = item.eta,
                  !eta.isEmpty,
                  let date = formatter.date(from: eta) else {
                return nil
            }
            return ETADisplayInfo(etaDate: date, remark: item.rmk_tc)
        }
        .sorted { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
        
        return FavoriteStatusModel(etas: Array(etas.prefix(3)), distance: nearestDistance, stopName: nearestStopName)
    }
}
