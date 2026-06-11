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
    
    /// 載入首頁需要嘅靜態路線同站點資料。
    ///
    /// 如有快取快照，會先套用以加快 UI 顯示，再喺背景更新 KMB 同 CTB 資料。無快取時會即時完成網絡更新先返回。
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
    
    /// 嘗試還原之前儲存嘅靜態路線快照。
    ///
    /// 找到快照時，會套用快取路線、站點、查表字典同附近站點狀態，然後返回 `true`。
    /// - Returns: 成功還原快取資料時返回 `true`，否則返回 `false`。
    private func loadCachedStaticRouteData() async -> Bool {
        guard let snapshot = await StaticRouteDataCache.load() else { return false }
        await applyStaticRouteData(routes: snapshot.routes, stops: snapshot.stops)
        await updateNearbyStopsAfterStaticDataLoad()
        return true
    }
    
    /// 從兩間營辦商下載最新路線建議同站點紀錄。
    ///
    /// 更新成功後會取代記憶體內嘅路線同站點狀態，儲存新快照供下次啟動使用，並喺已有使用者位置時重新計算附近站點。
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
    
    /// 並行擷取 KMB 同 CTB 路線建議目錄，並合併重複嘅聯營路線。
    /// - Returns: 按 `RouteSuggestionCatalog` 規則排序、可直接顯示嘅路線建議列表。
    private func fetchAllRouteSuggestions() async throws -> [RouteSuggestion] {
        async let kmbSuggestions = kmbETAProvider.fetchRouteSuggestions()
        async let ctbSuggestions = ctbETAProvider.fetchRouteSuggestions()
        return try await RouteSuggestionCatalog.merged(kmb: kmbSuggestions, ctb: ctbSuggestions)
    }
    
    /// 並行擷取所有已知 KMB 同 CTB 站點紀錄。
    /// - Returns: 合併後嘅站點列表，用作建立站名字典同附近站點結果。
    private func fetchAllStops() async throws -> [StopInfo] {
        async let kmbStops = kmbETAProvider.fetchStops()
        async let ctbStops = ctbETAProvider.fetchStops()
        return try await kmbStops + ctbStops
    }
    
    /// 將完整靜態資料套用到搜尋同附近首頁會用到嘅狀態。
    /// - Parameters:
    ///   - routes: 已合併嘅 KMB、CTB 同聯營路線建議。
    ///   - stops: 兩間營辦商嘅站點紀錄。
    private func applyStaticRouteData(routes: [RouteSuggestion], stops: [StopInfo]) async {
        await MainActor.run {
            self.allRoutes = routes
        }
        await applyStops(stops)
    }
    
    /// 儲存站點資料，並重建路線搜尋、收藏同附近配對會用到嘅查表字典。
    /// - Parameter stops: KMB 同 CTB 站點紀錄，包含營辦商專用身份鍵。
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
    
    /// 路線同站點字典可用後，重建附近站點同收藏 ETA 狀態。
    ///
    /// 位置管理器未有目前使用者位置前，呢個方法唔會執行任何更新。
    private func updateNearbyStopsAfterStaticDataLoad() async {
        if let userLocation = locationManager.location {
            await updateNearbyStops(userLocation: userLocation)
            warmFavoriteETAsIfPossible()
        }
    }

}
