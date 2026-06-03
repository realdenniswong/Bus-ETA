import SwiftUI
import CoreLocation
import Combine
import UserNotifications
import ActivityKit

// MARK: - Controller / Business Logic
extension ContentView {
    
    // MARK: - Network Functions
    func loadAllRoutes() async {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route/") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(AllRoutesResponse.self, from: data)
            
            var uniqueSuggestions: [String: RouteSuggestion] = [:]
            
            for item in response.data {
                let key = "\(item.route)-\(item.bound)"
                if uniqueSuggestions[key] == nil {
                    uniqueSuggestions[key] = RouteSuggestion(
                        route: item.route,
                        bound: item.bound,
                        origin: item.orig_tc,
                        destination: item.dest_tc
                    )
                }
            }
            
            let sortedRoutes = uniqueSuggestions.values.sorted {
                if $0.route == $1.route { return $0.bound > $1.bound }
                return $0.route.localizedStandardCompare($1.route) == .orderedAscending
            }
            
            await MainActor.run {
                self.allRoutes = sortedRoutes
            }
        } catch {
            print("Failed to load all routes: \(error)")
        }
    }
    
    func loadAllStops() async {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop/") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(StopResponse.self, from: data)
            
            var newDict: [String: String] = [:]
            var newInfoDict: [String: StopInfo] = [:]
            for stop in response.data {
                newDict[stop.stop] = stop.name_tc
                newInfoDict[stop.stop] = stop
            }
            
            await MainActor.run {
                self.allStops = response.data
                self.stopDictionary = newDict
                self.stopInfoDictionary = newInfoDict
            }
            
            if let userLoc = locationManager.location {
                await updateNearbyStops(userLocation: userLoc)
            }
        } catch {
            print("Failed to load stops dictionary: \(error)")
        }
    }
    
    func updateNearbyStops(userLocation: CLLocation) async {
        guard !allStops.isEmpty else { return }
        
        await MainActor.run {
            isSearchingNearby = true
        }
        
        let sorted = await Task.detached(priority: .userInitiated) { () -> [NearbyStopModel] in
            var temp: [NearbyStopModel] = []
            for stop in allStops {
                guard let stopLoc = stop.clLocation else { continue }
                let dist = userLocation.distance(from: stopLoc)
                temp.append(NearbyStopModel(stopInfo: stop, distance: dist))
            }
            temp.sort { $0.distance < $1.distance }
            return Array(temp.prefix(10)) // 🌟 將最近車站顯示數量由 3 加到 10
        }.value
        
        var populated: [NearbyStopModel] = []
        for var stopModel in sorted {
            let routes = await fetchRoutesForStop(stopId: stopModel.stopInfo.stop)
            stopModel.routes = routes
            populated.append(stopModel)
        }
        
        await MainActor.run {
            self.nearbyStops = populated
            self.isSearchingNearby = false
        }
    }
    
    func fetchRoutesForStop(stopId: String) async -> [NearbyRouteModel] {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/\(stopId)") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            if let jsonString = String(data: data, encoding: .utf8) {
                print("======================================================")
                print("🐛 [DEBUG] Dashboard 車站 ID: \(stopId) 嘅 ETA 原始數據:")
                print(jsonString)
                print("======================================================")
            }
            
            let response = try JSONDecoder().decode(StopETAResponse.self, from: data)
            
            var grouped: [String: [StopETAItem]] = [:]
                        
            for item in response.data {
                guard item.service_type == 1 else { continue }
                
                let key = "\(item.route)-\(item.dir)-\(item.dest_tc)"
                grouped[key, default: []].append(item)
            }
            
            var routes: [NearbyRouteModel] = []
            let dateFormatter = ISO8601DateFormatter()
            
            for (_, items) in grouped {
                guard let first = items.first else { continue }
                let sortedItems = items.sorted { $0.eta_seq < $1.eta_seq }
                
                var etaInfos: [ETADisplayInfo] = []
                for etaItem in sortedItems {
                    if let etaString = etaItem.eta, let etaDate = dateFormatter.date(from: etaString) {
                        etaInfos.append(ETADisplayInfo(etaDate: etaDate, remark: etaItem.rmk_tc))
                    }
                }
                
                routes.append(NearbyRouteModel(
                    route: first.route,
                    directionCode: first.dir,
                    destNameTc: first.dest_tc,
                    etas: etaInfos
                ))
            }
            
            return routes.sorted { $0.route.localizedStandardCompare($1.route) == .orderedAscending }
        } catch {
            print("Failed to fetch routes for stop \(stopId): \(error)")
            return []
        }
    }
    
    func searchRoute(route: String, direction: String? = nil, findNearest: Bool = false, targetStopCode: String? = nil, shouldScroll: Bool = false, isRefresh: Bool = false) async {
        guard !route.isEmpty else { return }
        
        print("🐛 [DEBUG] 開始搜尋路線: \(route) | findNearest: \(findNearest) | shouldScroll: \(shouldScroll)")
        
        let currentDir = direction ?? self.selectedDirection
        
        await MainActor.run {
            if let newDir = direction {
                self.selectedDirection = newDir
            }
            if !isRefresh {
                isLoading = true
                displayData = []
                highlightedStopId = nil
            }
        }
        
        let routeStopUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-stop/\(route)/\(currentDir)/1")!
        let etaUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-eta/\(route)/1")!
        
        do {
            async let (routeStopData, _) = URLSession.shared.data(from: routeStopUrl)
            async let (etaData, _) = URLSession.shared.data(from: etaUrl)
            
            if let jsonString = await String(data: etaData, encoding: .utf8) {
                print("======================================================")
                print("🐛 [DEBUG] Bus Route ID: \(route) 嘅 ETA 原始數據:")
                print(jsonString)
                print("======================================================")
            }
            
            let decoder = JSONDecoder()
            let routeStops = try await decoder.decode(RouteStopResponse.self, from: routeStopData).data
            let allEtas = try await decoder.decode(ETAResponse.self, from: etaData).data
            
            let targetDirectionCode = currentDir == "outbound" ? "O" : "I"
            let filteredEtas = allEtas.filter { $0.dir == targetDirectionCode }
            
            let dateFormatter = ISO8601DateFormatter()
            var results: [StopDisplayModel] = []
            
            for routeStop in routeStops {
                let stopNameTc: String
                if let stopInfo = stopInfoDictionary[routeStop.stop] {
                    stopNameTc = stopInfo.name_tc
                } else {
                    stopNameTc = stopDictionary[routeStop.stop] ?? "未知車站"
                }
                
                let seqInt = Int(routeStop.seq) ?? 0
                let stopEtas = filteredEtas.filter { $0.seq == seqInt }
                
                var parsedEtas: [ETADisplayInfo] = []
                for etaItem in stopEtas {
                    if let etaString = etaItem.eta, let etaDate = dateFormatter.date(from: etaString) {
                        parsedEtas.append(ETADisplayInfo(etaDate: etaDate, remark: etaItem.rmk_tc))
                    }
                }
                
                results.append(StopDisplayModel(seq: seqInt, stopId: routeStop.stop, stopNameTc: stopNameTc, etas: parsedEtas))
            }
            
            var targetId: String? = nil
            if findNearest {
                if let userLoc = locationManager.location, !results.isEmpty {
                    var minDistance: CLLocationDistance = .infinity
                    for rs in results {
                        let loc: CLLocation? = stopInfoDictionary[rs.stopId]?.clLocation ?? allStops.first(where: { $0.stop == rs.stopId })?.clLocation
                        if let stopLoc = loc {
                            let dist = userLoc.distance(from: stopLoc)
                            if dist < minDistance {
                                minDistance = dist
                                targetId = rs.id
                            }
                        }
                    }
                }
            } else if let code = targetStopCode {
                targetId = results.first(where: { $0.stopId == code })?.id
            } else {
                targetId = highlightedStopId
            }
            
            await MainActor.run {
                self.highlightedStopId = targetId
                
                if results.isEmpty {
                    systemMessage = "沒有找到路線 \(route) 的 \(currentDir == "outbound" ? "去程" : "回程") 班次數據。"
                    if !isRefresh { displayData = [] }
                } else {
                    displayData = results
                }
                
                if shouldScroll {
                    self.scrollTriggerId = UUID()
                }
                
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
    
    // MARK: - 實時背景同步與追蹤更新函數
    func syncActiveTimer() async {
        guard let timer = activeTimer, !timer.stopId.isEmpty else { return }
        
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/\(timer.stopId)") else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(StopETAResponse.self, from: data)
            
            let targetDirCode = timer.direction == "outbound" ? "O" : "I"
            let matchedItems = response.data.filter { $0.route == timer.routeName && $0.dir == targetDirCode }
            let sortedItems = matchedItems.sorted { $0.eta_seq < $1.eta_seq }
            
            let dateFormatter = ISO8601DateFormatter()
            if let firstEtaItem = sortedItems.first,
               let etaString = firstEtaItem.eta,
               let newEtaDate = dateFormatter.date(from: etaString) {
                
                let difference = abs(newEtaDate.timeIntervalSince(timer.etaDate))
                if difference > 10 {
                    print("🐛 [DEBUG] 偵測到最新巴士真實班次已更動！正在進行動態重設...")
                    
                    await MainActor.run {
                        withAnimation {
                            self.activeTimer?.etaDate = newEtaDate
                            self.activeTimer?.targetAlertDate = newEtaDate.addingTimeInterval(-120)
                        }
                    }
                    
                    let alertDate = newEtaDate.addingTimeInterval(-120)
                    if alertDate.timeIntervalSince(Date()) > 0 {
                        scheduleLocalNotification(
                            routeName: timer.routeName,
                            destination: timer.destination,
                            alertDate: alertDate
                        )
                    }
                    
                    updateLiveActivity(etaDate: newEtaDate)
                }
            }
        } catch {
            print("🐛 [DEBUG] 背景計時器即時同步失敗: \(error)")
        }
    }
    
    func updateLiveActivity(etaDate: Date) {
        Task {
            for activity in Activity<BusETAAttributes>.activities {
                let remaining = Int(etaDate.timeIntervalSince(Date()))
                let state = BusETAAttributes.ContentState(etaDate: etaDate, remainingSeconds: remaining)
                
                let expireDate = etaDate.addingTimeInterval(1 * 60)
                await activity.update(ActivityContent(state: state, staleDate: expireDate))
            }
        }
    }
    
    func formattedTime(_ date: Date?) -> String {
        guard let date = date else { return "" }
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
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule local notification: \(error)")
            }
        }
    }
    
    func startLiveActivity(routeName: String, destination: String, stationName: String, etaDate: Date, startTime: Date) {
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                let attributes = BusETAAttributes(routeName: routeName, destination: destination, stationName: stationName, startTime: startTime)
                let remaining = Int(etaDate.timeIntervalSince(Date()))
                let state = BusETAAttributes.ContentState(etaDate: etaDate, remainingSeconds: remaining)
                
                let expireDate = etaDate.addingTimeInterval(1 * 60)
                let content = ActivityContent(state: state, staleDate: expireDate)
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
            let attribs = activity.attributes
            let state = activity.content.state
            
            if state.etaDate.timeIntervalSince(Date()) > 0 {
                if self.activeTimer == nil {
                    self.activeTimer = ActiveTimerModel(
                        routeName: attribs.routeName,
                        destination: attribs.destination,
                        etaDate: state.etaDate,
                        targetAlertDate: state.etaDate.addingTimeInterval(-120),
                        startTime: attribs.startTime,
                        stopId: "",
                        direction: "",
                        stationName: attribs.stationName
                    )
                    print("成功重新連接背景計時器: \(attribs.routeName)")
                }
            } else {
                print("🐛 [DEBUG] 發現過期卡片 \(attribs.routeName)，立即刪除！")
                Task {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }
}
