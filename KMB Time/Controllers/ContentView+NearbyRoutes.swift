/// 檔案用途：根據使用者位置計算附近站點同即時附近路線 ETA。
import CoreLocation

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    /// 更新相關狀態，令畫面或快取保持最新。
    /// - Parameters:
    ///   - userLocation: 用嚟計算距離嘅位置。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func updateNearbyStops(userLocation: CLLocation) async {
        let stepStart = Date()
        guard !allStops.isEmpty else { return }
        
        let shouldStartUpdate = await MainActor.run {
            guard !isUpdatingNearby else { return false }
            isUpdatingNearby = true
            isSearchingNearby = true
            return true
        }
        guard shouldStartUpdate else { return }
        
        let dashboardStops = nearbyStopModels(from: allStops, userLocation: userLocation, radius: 300)
        logTiming("nearby stop search", startedAt: stepStart, detail: "\(dashboardStops.count) stops")
        
        await MainActor.run {
            self.nearbyStops = dashboardStops
            self.isSearchingNearby = false
        }
        logTiming("nearby UI update", startedAt: stepStart)
        
        await progressivelyFetchRoutes(for: dashboardStops)
    }
    
    /// 重新整理目前畫面需要嘅資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func refreshNearbyETAs() async {
        guard !nearbyStops.isEmpty else { return }
        await MainActor.run { isSearchingNearby = true }
        await progressivelyFetchRoutes(for: nearbyStops, forceRefresh: true)
    }
    
    /// Fetch nearby route ETAs in small batches and publish each stop as soon as it completes.
    /// - Parameters:
    ///   - stops: Candidate nearby stops already shown on screen.
    ///   - forceRefresh: Whether to bypass the short ETA cache.
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func progressivelyFetchRoutes(for stops: [NearbyStopModel], forceRefresh: Bool = false) async {
        let routeStart = Date()
        let sortedStops = stops.sorted { $0.distance < $1.distance }
        let visibleStops = Array(sortedStops.prefix(8))
        let deferredStops = Array(sortedStops.dropFirst(8).prefix(12))
        
        await fetchRouteBatches(for: visibleStops, forceRefresh: forceRefresh, concurrencyLimit: 4)
        logTiming("visible ETA fetching", startedAt: routeStart, detail: "\(visibleStops.count) stops")
        
        if !deferredStops.isEmpty {
            await fetchRouteBatches(for: deferredStops, forceRefresh: forceRefresh, concurrencyLimit: 2)
            logTiming("deferred ETA fetching", startedAt: routeStart, detail: "\(deferredStops.count) stops")
        }
        
        await MainActor.run {
            self.isSearchingNearby = false
            self.isUpdatingNearby = false
        }
    }
    
    /// Fetch route data with a bounded number of concurrent API requests.
    /// - Parameters:
    ///   - stops: Stops to fetch.
    ///   - forceRefresh: Whether to bypass the short ETA cache.
    ///   - concurrencyLimit: Maximum concurrent stop fetches.
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func fetchRouteBatches(for stops: [NearbyStopModel], forceRefresh: Bool, concurrencyLimit: Int) async {
        guard !stops.isEmpty else { return }
        let batches = stride(from: 0, to: stops.count, by: concurrencyLimit).map {
            Array(stops[$0..<min($0 + concurrencyLimit, stops.count)])
        }
        
        for batch in batches {
            await withTaskGroup(of: NearbyStopModel.self) { group in
                for stop in batch {
                    group.addTask {
                        let startedAt = Date()
                        var stopWithRoutes = stop
                        stopWithRoutes.routes = await fetchRoutesForNearbyStop(stop.stopInfo, forceRefresh: forceRefresh)
                        stopWithRoutes.hasFetchedRoutes = true
                        logTiming("ETA fetching", startedAt: startedAt, detail: stop.stopInfo.name_tc)
                        return stopWithRoutes
                    }
                }
                
                for await stopWithRoutes in group {
                    await applyNearbyStopRoutes(stopWithRoutes)
                }
            }
        }
    }
    
    /// Update a single nearby stop row after its ETA request finishes.
    /// - Parameters:
    ///   - stop: Updated stop model.
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func applyNearbyStopRoutes(_ stop: NearbyStopModel) async {
        let updateStart = Date()
        await MainActor.run {
            guard let index = self.nearbyStops.firstIndex(where: { $0.stopInfo.identityKey == stop.stopInfo.identityKey }) else { return }
            self.nearbyStops[index] = stop
        }
        logTiming("UI update", startedAt: updateStart, detail: stop.stopInfo.name_tc)
    }
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - stopInfo: 車站識別或車站資料。
    ///   - forceRefresh: 控制此流程是否啟用嘅設定。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func fetchRoutesForNearbyStop(_ stopInfo: StopInfo, forceRefresh: Bool = false) async -> [NearbyRouteModel] {
        let routes: [NearbyRouteModel]
        switch stopInfo.operatorCode {
        case .kmb:
            async let kmbRoutes = (try? kmbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
            async let jointRoutes = (try? jointRouteETAProvider.fetchNearbyRoutes(for: stopInfo)) ?? []
            routes = dashboardRoutes(kmbRoutes: await kmbRoutes, ctbRoutes: [], jointRoutes: await jointRoutes)
        case .ctb:
            let ctbRoutes = (try? await ctbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
            routes = dashboardRoutes(kmbRoutes: [], ctbRoutes: ctbRoutes, jointRoutes: [])
        case nil:
            async let kmbRoutes = (try? kmbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
            async let jointRoutes = (try? jointRouteETAProvider.fetchNearbyRoutes(for: stopInfo)) ?? []
            async let ctbRoutes = (try? ctbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
            routes = dashboardRoutes(kmbRoutes: await kmbRoutes, ctbRoutes: await ctbRoutes, jointRoutes: await jointRoutes)
        }
        let routesWithCachedETAs = await cachedRoutes(routes, stopId: stopInfo.identityKey, forceRefresh: forceRefresh)
        return routesWithCachedETAs.sorted {
            if $0.route == $1.route { return $0.directionCode < $1.directionCode }
            return $0.route.localizedStandardCompare($1.route) == .orderedAscending
        }
    }
    
    /// 整理或查找路線相關資料。
    /// - Parameters:
    ///   - kmbRoutes: 路線編號或路線模型。
    ///   - ctbRoutes: 路線編號或路線模型。
    ///   - jointRoutes: 路線編號或路線模型。
    /// - Returns: 符合條件並已整理嘅資料列表。
    private func dashboardRoutes(kmbRoutes: [NearbyRouteModel], ctbRoutes: [NearbyRouteModel], jointRoutes: [NearbyRouteModel]) -> [NearbyRouteModel] {
        let kmbOnlyRoutes = kmbRoutes.filter { route in
            !ctbETAProvider.isJointRoute(route: route.route, direction: BusDirection(routeCode: route.directionCode))
        }
        let ctbOnlyRoutes = ctbRoutes.filter { $0.co != "KMB+CTB" }
        return kmbOnlyRoutes + jointRoutes + ctbOnlyRoutes
    }
    
    /// Apply the short ETA cache and save fresh ETA results on the main actor.
    /// - Parameters:
    ///   - routes: Route models returned by providers.
    ///   - stopId: Stop identity used in cache keys.
    ///   - forceRefresh: Whether to skip cached values.
    /// - Returns: Routes with cached ETAs filled when available.
    private func cachedRoutes(_ routes: [NearbyRouteModel], stopId: String, forceRefresh: Bool = false) async -> [NearbyRouteModel] {
        await MainActor.run {
            routes.map { route in
                let key = dashboardETAKey(route: route, stopId: stopId)
                if !route.etas.isEmpty {
                    dashboardETAByKey[key] = (Date(), route.etas)
                    return route
                }
                guard !forceRefresh,
                      let cachedEntry = dashboardETAByKey[key],
                      Date().timeIntervalSince(cachedEntry.updatedAt) <= dashboardETACacheLifetime else {
                    return route
                }
                return routeWithETAs(route, etas: cachedEntry.etas)
            }
        }
    }
    
    /// 整理或查找路線相關資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - etas: 時間或到站時間資料。
    /// - Returns: 計算後嘅 `NearbyRouteModel`。
    private func routeWithETAs(_ route: NearbyRouteModel, etas: [ETADisplayInfo]) -> NearbyRouteModel {
        NearbyRouteModel(
            co: route.co,
            route: route.route,
            directionCode: route.directionCode,
            destNameTc: route.destNameTc,
            displayStopName: route.displayStopName,
            displayStopId: route.displayStopId,
            etas: etas,
            detailDirectionCode: route.detailDirectionCode
        )
    }
    
    private var dashboardETACacheLifetime: TimeInterval { 30 }
    
    /// 建立用於查找或快取嘅穩定 key。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - stopId: 車站識別或車站資料。
    /// - Returns: 格式化或查找後嘅文字。
    private func dashboardETAKey(route: NearbyRouteModel, stopId: String) -> String {
        "\(route.co)-\(route.route.uppercased())-\(route.directionCode)-\(stopId)"
    }
    
    /// 建立用於查找或快取嘅穩定 key。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    /// - Returns: 格式化或查找後嘅文字。
    private func dashboardRouteKey(route: NearbyRouteModel) -> String {
        "\(route.co)-\(route.route.uppercased())-\(route.directionCode)"
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - stopName: 車站識別或車站資料。
    /// - Returns: 格式化或查找後嘅文字。
    private func normalizedStationName(_ stopName: String) -> String {
        let withoutPoleId = stopName.replacingOccurrences(
            of: "\\s*\\(([A-Z]{1,4}\\d{1,4}|[A-Z]\\d{1,5}|\\d{1,5})\\)\\s*$",
            with: "",
            options: .regularExpression
        )
        let baseName = withoutPoleId
            .split(whereSeparator: { $0 == "，" || $0 == "," })
            .first
            .map(String.init) ?? withoutPoleId
        return baseName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - from: 此函式需要嘅輸入資料。
    /// - Returns: 可用嘅位置資料；沒有時為 nil。
    private func location(from stopInfo: StopInfo) -> CLLocation? {
        guard let latitudeText = stopInfo.lat,
              let longitudeText = stopInfo.long,
              let latitude = Double(latitudeText),
              let longitude = Double(longitudeText) else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - from: 此函式需要嘅輸入資料。
    ///   - userLocation: 用嚟計算距離嘅位置。
    ///   - radius: 搜尋半徑。
    /// - Returns: 符合條件並已整理嘅資料列表。
    private func nearbyStopModels(from stops: [StopInfo], userLocation: CLLocation, radius: CLLocationDistance) -> [NearbyStopModel] {
        stops
            .compactMap { stop -> NearbyStopModel? in
                guard let stopLocation = stop.clLocation else { return nil }
                let distance = userLocation.distance(from: stopLocation)
                guard distance <= radius else { return nil }
                return NearbyStopModel(stopInfo: stop, distance: distance)
            }
            .sorted { $0.distance < $1.distance }
    }
}
/// Print compact timing diagnostics for launch and nearby ETA performance.
/// - Parameters:
///   - step: Step name.
///   - startedAt: Start time.
///   - detail: Optional context for the log line.
/// - Returns: 無回傳值；會透過 console 輸出完成工作。
nonisolated private func logTiming(_ step: String, startedAt: Date, detail: String? = nil) {
    let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
    if let detail, !detail.isEmpty {
        print("[Performance] \(step): \(milliseconds)ms (\(detail))")
    } else {
        print("[Performance] \(step): \(milliseconds)ms")
    }
}

