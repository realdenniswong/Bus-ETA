/// 檔案用途：根據使用者位置計算附近站點同即時附近路線 ETA。
import CoreLocation

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    /// 更新相關狀態，令畫面或快取保持最新。
    /// - Parameters:
    ///   - userLocation: 用嚟計算距離嘅位置。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func updateNearbyStops(userLocation: CLLocation) async {
        guard !allStops.isEmpty else { return }
        
        let shouldStartUpdate = await MainActor.run {
            guard !isUpdatingNearby else { return false }
            isUpdatingNearby = true
            isSearchingNearby = true
            return true
        }
        guard shouldStartUpdate else { return }
        
        let dashboardStops = nearbyStopModels(from: allStops, userLocation: userLocation, radius: 300)
        let nearbyStopsWithRoutes = await nearbyStopsForAllBusesMode(dashboardStops)
        
        await MainActor.run {
            self.nearbyStops = nearbyStopsWithRoutes
            self.isSearchingNearby = false
            self.isUpdatingNearby = false
        }
    }
    
    /// 重新整理目前畫面需要嘅資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func refreshNearbyETAs() async {
        guard !nearbyStops.isEmpty else { return }
        await MainActor.run { isSearchingNearby = true }
        
        let refreshedStops = await nearbyStopsForAllBusesMode(nearbyStops)
        
        await MainActor.run {
            self.nearbyStops = refreshedStops
            self.isSearchingNearby = false
        }
    }
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - stops: 車站識別或車站資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    private func nearbyStopsForAllBusesMode(_ stops: [NearbyStopModel]) async -> [NearbyStopModel] {
        var fetchedStops: [NearbyStopModel] = []
        var uniqueRouteKeys = Set<String>()
        let maxUniqueRoutes = 24
        
        for stop in stops.sorted(by: { $0.distance < $1.distance }) {
            var stopWithRoutes = stop
            stopWithRoutes.routes = await fetchRoutesForNearbyStop(stop.stopInfo)
            stopWithRoutes.hasFetchedRoutes = true
            fetchedStops.append(stopWithRoutes)
            
            for route in stopWithRoutes.routes {
                uniqueRouteKeys.insert(dashboardRouteKey(route: route))
            }
            if uniqueRouteKeys.count >= maxUniqueRoutes {
                break
            }
        }
        
        let fetchedStopIds = Set(fetchedStops.map { $0.stopInfo.identityKey })
        let unfetchedStops = stops.filter { !fetchedStopIds.contains($0.stopInfo.identityKey) }
        return (fetchedStops + unfetchedStops.map { stop in
            var stopWithoutRoutes = stop
            stopWithoutRoutes.routes = []
            return stopWithoutRoutes
        })
        .sorted { $0.distance < $1.distance }
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
        return routes
            .map { cachedRoute($0, stopId: stopInfo.identityKey, forceRefresh: forceRefresh) }
            .sorted {
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
    
    /// 整理或查找路線相關資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - stopId: 車站識別或車站資料。
    ///   - forceRefresh: 控制此流程是否啟用嘅設定。
    /// - Returns: 計算後嘅 `NearbyRouteModel`。
    private func cachedRoute(_ route: NearbyRouteModel, stopId: String, forceRefresh: Bool = false) -> NearbyRouteModel {
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
