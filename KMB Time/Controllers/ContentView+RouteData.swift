/// 檔案用途：載入、快取同套用靜態路線及站點資料。
import Foundation

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    var kmbETAProvider: KMBETAProvider {
        KMBETAProvider.shared
    }
    
    var ctbETAProvider: CTBETAProvider {
        CTBETAProvider.shared
    }
    
    var jointRouteETAProvider: JointRouteETAProvider {
        JointRouteETAProvider.shared
    }
    
    var routeSuggestionCatalog: RouteSuggestionCatalog {
        RouteSuggestionCatalog(suggestions: allRoutes) { route, direction in
            ctbETAProvider.companyCode(route: route, direction: direction)
        }
    }
    
    /// 載入需要嘅資料並更新本機狀態或快取。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func loadStaticRouteData() async {
        let startedAt = Date()
        let loadedCachedData = await loadCachedStaticRouteData()
        print("[Performance] route loading initial: \(Int(Date().timeIntervalSince(startedAt) * 1_000))ms cache=\(loadedCachedData)")
        
        if loadedCachedData {
            Task { await refreshStaticRouteData() }
        } else {
            await refreshStaticRouteData()
        }
    }
    
    /// 載入需要嘅資料並更新本機狀態或快取。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func loadAllRoutes() async {
        do {
            let routeSuggestions = try await fetchAllRouteSuggestions()
            await MainActor.run {
                self.allRoutes = routeSuggestions
            }
        } catch {
            print("Failed to load route suggestions: \(error)")
        }
    }
    
    /// 載入需要嘅資料並更新本機狀態或快取。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func loadAllStops() async {
        do {
            let stops = try await fetchAllStops()
            await applyStops(stops)
            await updateNearbyStopsAfterStaticDataLoad()
        } catch {
            print("Failed to load stops: \(error)")
        }
    }
    
    /// 載入需要嘅資料並更新本機狀態或快取。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 條件是否成立。
    private func loadCachedStaticRouteData() async -> Bool {
        guard let snapshot = await StaticRouteDataCache.load() else { return false }
        await applyStaticRouteData(routes: snapshot.routes, stops: snapshot.stops)
        await updateNearbyStopsAfterStaticDataLoad()
        return true
    }
    
    /// 重新整理目前畫面需要嘅資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func refreshStaticRouteData() async {
        let startedAt = Date()
        do {
            async let routesRequest = fetchAllRouteSuggestions()
            async let stopsRequest = fetchAllStops()
            let (routes, stops) = try await (routesRequest, stopsRequest)
            print("[Performance] route loading refresh network: \(Int(Date().timeIntervalSince(startedAt) * 1_000))ms routes=\(routes.count) stops=\(stops.count)")
            
            await applyStaticRouteData(routes: routes, stops: stops)
            await StaticRouteDataCache.save(StaticRouteDataCache.makeSnapshot(routes: routes, stops: stops))
            await updateNearbyStopsAfterStaticDataLoad()
        } catch {
            print("Failed to refresh static route data: \(error)")
        }
    }
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 符合條件並已整理嘅資料列表。
    private func fetchAllRouteSuggestions() async throws -> [RouteSuggestion] {
        async let kmbSuggestions = kmbETAProvider.fetchRouteSuggestions()
        async let ctbSuggestions = ctbETAProvider.fetchRouteSuggestions()
        return try await RouteSuggestionCatalog.merged(kmb: kmbSuggestions, ctb: ctbSuggestions)
    }
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 符合條件並已整理嘅資料列表。
    private func fetchAllStops() async throws -> [StopInfo] {
        async let kmbStops = kmbETAProvider.fetchStops()
        async let ctbStops = ctbETAProvider.fetchStops()
        return try await kmbStops + ctbStops
    }
    
    /// 整理或查找路線相關資料。
    /// - Parameters:
    ///   - routes: 路線編號或路線模型。
    ///   - stops: 車站識別或車站資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func applyStaticRouteData(routes: [RouteSuggestion], stops: [StopInfo]) async {
        await MainActor.run {
            self.allRoutes = routes
        }
        await applyStops(stops)
    }
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - stops: 車站識別或車站資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func applyStops(_ stops: [StopInfo]) async {
        let stopNamesById = Dictionary(stops.map { ($0.stop, $0.name_tc) }, uniquingKeysWith: { first, _ in first })
        let identityStopInfo = stops.map { ($0.identityKey, $0) }
        let plainStopInfo = stops.map { ($0.stop, $0) }
        let stopInfoById = Dictionary(identityStopInfo + plainStopInfo, uniquingKeysWith: { first, _ in first })
        
        await MainActor.run {
            self.allStops = stops
            self.stopDictionary = stopNamesById
            self.stopInfoDictionary = stopInfoById
        }
    }
    
    /// 載入需要嘅資料並更新本機狀態或快取。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func updateNearbyStopsAfterStaticDataLoad() async {
        if let userLocation = locationManager.location {
            await updateNearbyStops(userLocation: userLocation)
            warmFavoriteETAsIfPossible()
        }
    }

}
