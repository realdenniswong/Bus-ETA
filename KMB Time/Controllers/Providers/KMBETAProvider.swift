/// 檔案用途：處理 KMB API 資料、路線建議、站點、ETA 同收藏狀態。
import CoreLocation
import Foundation

/// `KMBETAProvider` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct KMBETAProvider: BusETAProvider {
    static let shared = KMBETAProvider()
    
    let operatorCode: BusOperator = .kmb
    
    private let baseURL = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/")!
    private let jsonDecoder = JSONDecoder()
    
    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；完成物件初始化。
    private init() { }
    
    /// 讀取 KMB 路線清單並轉成搜尋建議。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 已整理同排序嘅 KMB 路線建議列表。
    func fetchRouteSuggestions() async throws -> [RouteSuggestion] {
        let response: KMBRoutesResponse = try await fetch(path: "route/")
        return response.data
            .map { route in
                RouteSuggestion(
                    co: operatorCode.rawValue,
                    route: route.route,
                    bound: route.bound,
                    origin: route.orig_tc,
                    destination: route.dest_tc
                )
            }
            .sorted(by: sortRouteSuggestions)
    }
    
    /// 讀取 KMB 車站清單並排除無效座標。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 已標記為 KMB 並帶有效座標嘅車站資料列表。
    func fetchStops() async throws -> [StopInfo] {
        let response: StopResponse = try await fetch(path: "stop/")
        return response.data.compactMap { stop in
            guard let latitudeText = stop.lat,
                  let longitudeText = stop.long,
                  let latitude = Double(latitudeText),
                  let longitude = Double(longitudeText),
                  latitude != 0.0,
                  longitude != 0.0 else {
                return nil
            }
            return stop.tagged(with: operatorCode)
        }
    }
    
    /// 讀取指定 KMB 車站嘅到站資料並分組成附近路線。
    /// - Parameters:
    ///   - forStopId: 要查詢嘅 KMB 車站識別碼。
    /// - Returns: 已按路線整理同排序嘅附近路線顯示資料。
    func fetchNearbyRoutes(forStopId stopId: String) async throws -> [NearbyRouteModel] {
        let response: StopETAResponse = try await fetch(path: "stop-eta/\(stopId)", reloadIgnoringCache: true)
        let etaItemsByRouteDirection = Dictionary(grouping: response.data.filter { $0.service_type == 1 }) { etaItem in
            "\(etaItem.route)-\(etaItem.dir)"
        }
        
        let routes = etaItemsByRouteDirection.compactMap { routeDirectionKey, etaItems -> NearbyRouteModel? in
            guard let firstEtaItem = etaItems.first else { return nil }
            let routeDirectionParts = routeDirectionKey.components(separatedBy: "-")
            guard routeDirectionParts.count >= 2 else { return nil }
            
            return NearbyRouteModel(
                co: operatorCode.rawValue,
                route: routeDirectionParts[0],
                directionCode: routeDirectionParts[1],
                destNameTc: firstEtaItem.dest_tc,
                etas: sortedDisplayETAs(from: etaItems),
                operatorStopIds: [operatorCode.rawValue: stopId]
            )
        }
        
        return routes.sorted { $0.route.localizedStandardCompare($1.route) == .orderedAscending }
    }
    
    /// 讀取 KMB 指定路線方向嘅站序，並配對每站可用 ETA。
    /// - Parameters:
    ///   - route: 要查詢嘅路線編號。
    ///   - direction: 要查詢嘅行車方向。
    ///   - stopNameById: 以車站識別碼索引嘅站名對照表。
    /// - Returns: 已按站序整理嘅 KMB 時間表顯示列。
    func fetchTimetableRows(route: String, direction: BusDirection, stopNameById: [String: String]) async throws -> [StopDisplayModel] {
        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
        let routeStopResponse: RouteStopResponse = try await fetch(path: "route-stop/\(safeRoute)/\(direction.rawValue)/1", reloadIgnoringCache: true)
        
        if let routeETAItems = try? await fetchRouteETAItems(route: route) {
            let etaItemsByStop = Dictionary(grouping: routeETAItems.compactMap { item -> (String, StopETAItem)? in
                guard let stopId = item.stop else { return nil }
                return (stopId, item)
            }) { $0.0 }
                .mapValues { pairs in pairs.map(\.1) }
            let etaItemsBySequence = Dictionary(grouping: routeETAItems.compactMap { item -> (Int, StopETAItem)? in
                guard let sequence = item.seq else { return nil }
                return (sequence, item)
            }) { $0.0 }
                .mapValues { pairs in pairs.map(\.1) }
            
            return routeStopResponse.data.map { routeStop in
                let stopId = routeStop.stop
                let stopSequence = Int(routeStop.seq) ?? 0
                let stopName = stopNameById[stopId] ?? "未知車站"
                let etaItems = etaItemsByStop[stopId] ?? etaItemsBySequence[stopSequence] ?? []
                let matchingETAs = sortedDisplayETAs(
                    from: etaItems,
                    route: route,
                    directionCode: direction.routeCode
                )
                
                return StopDisplayModel(
                    seq: stopSequence,
                    stopId: stopId,
                    stopNameTc: stopName,
                    etas: Array(matchingETAs.prefix(3)),
                    operatorStopIds: [operatorCode.rawValue: stopId]
                )
            }
            .sorted { $0.seq < $1.seq }
        }
        
        return await withTaskGroup(of: StopDisplayModel.self) { group in
            for routeStop in routeStopResponse.data {
                group.addTask {
                    let stopId = routeStop.stop
                    let stopSequence = Int(routeStop.seq) ?? 0
                    let stopName = stopNameById[stopId] ?? "未知車站"
                    let etaItems = try? await fetchStopETAItems(stopId: stopId)
                    let matchingETAs = await sortedDisplayETAs(
                        from: etaItems ?? [],
                        route: route,
                        directionCode: direction.routeCode
                    )
                    
                    return StopDisplayModel(
                        seq: stopSequence,
                        stopId: stopId,
                        stopNameTc: stopName,
                        etas: Array(matchingETAs.prefix(3)),
                        operatorStopIds: [operatorCode.rawValue: stopId]
                    )
                }
            }
            
            var rows: [StopDisplayModel] = []
            for await row in group {
                rows.append(row)
            }
            return rows.sorted { $0.seq < $1.seq }
        }
    }
    
    /// 找出 KMB 收藏路線最接近用戶嘅上車站，並讀取該站 ETA。
    /// - Parameters:
    ///   - for: 要更新狀態嘅收藏路線。
    ///   - context: 查找站點同位置所需嘅上下文資料。
    /// - Returns: 找到最近有效站點時回傳收藏狀態；否則為 nil。
    func fetchFavoriteStatus(for favorite: FavoriteRoute, context: RouteStopLookupContext) async throws -> FavoriteStatusModel? {
        let direction = BusDirection(rawValue: favorite.direction) ?? .outbound
        let safeRoute = favorite.route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? favorite.route
        let routeStopResponse: RouteStopResponse = try await fetch(path: "route-stop/\(safeRoute)/\(direction.rawValue)/1")
        
        var nearestStopId: String?
        var nearestStopName = "未知車站"
        var nearestDistance: CLLocationDistance = .infinity
        
        for routeStop in routeStopResponse.data {
            guard let stopInfo = context.stopInfoById[routeStop.stop],
                  let stopLocation = stopInfo.clLocation else {
                continue
            }
            
            let distance = context.userLocation.distance(from: stopLocation)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestStopId = routeStop.stop
                nearestStopName = stopInfo.name_tc
            }
        }
        
        guard let nearestStopId else { return nil }
        let etaItems = try await fetchStopETAItems(stopId: nearestStopId)
        let etas = sortedDisplayETAs(from: etaItems, route: favorite.route, directionCode: direction.routeCode)
        return FavoriteStatusModel(
            etas: Array(etas.prefix(3)),
            distance: nearestDistance,
            stopName: nearestStopName,
            stopId: nearestStopId,
            operatorStopIds: [operatorCode.rawValue: nearestStopId]
        )
    }
    
    /// 讀取 KMB 指定路線、方向同車站嘅倒數計時 ETA。
    /// - Parameters:
    ///   - route: 要查詢嘅路線編號。
    ///   - direction: 要查詢嘅行車方向。
    ///   - stopId: 要查詢嘅 KMB 車站識別碼。
    /// - Returns: 已過濾同排序嘅 ETA 顯示資料列表。
    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String) async throws -> [ETADisplayInfo] {
        let etaItems = try await fetchStopETAItems(stopId: stopId)
        return sortedDisplayETAs(from: etaItems, route: route, directionCode: direction.routeCode)
    }
}

/// 擴充 `KMBETAProvider`，加入此檔案負責嘅相關功能。
private extension KMBETAProvider {
    /// 讀取並解碼一個 KMB API 路徑。
    ///
    /// - Parameters:
    ///   - path: 接喺 KMB base URL 後面嘅 API 路徑。
    ///   - reloadIgnoringCache: 是否為即時 ETA 繞過本機 URL 快取。
    /// - Returns: 已解碼嘅回應 DTO。
    func fetch<Response: Decodable>(path: String, reloadIgnoringCache: Bool = false) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        if reloadIgnoringCache {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let decodeStart = Date()
        let response = try jsonDecoder.decode(Response.self, from: data)
        print("[Performance] JSON decoding KMB \(path): \(Int(Date().timeIntervalSince(decodeStart) * 1_000))ms")
        return response
    }
    
    /// 讀取指定 KMB 車站嘅原始 ETA 項目。
    /// - Parameters:
    ///   - stopId: 要查詢嘅 KMB 車站識別碼。
    /// - Returns: API 回傳嘅車站 ETA 項目列表。
    func fetchStopETAItems(stopId: String) async throws -> [StopETAItem] {
        let response: StopETAResponse = try await fetch(path: "stop-eta/\(stopId)", reloadIgnoringCache: true)
        return response.data
    }
    
    /// 讀取指定 KMB 路線全線嘅原始 ETA 項目。
    /// - Parameters:
    ///   - route: 要查詢嘅路線編號。
    /// - Returns: API 回傳嘅路線 ETA 項目列表。
    func fetchRouteETAItems(route: String) async throws -> [StopETAItem] {
        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
        let response: StopETAResponse = try await fetch(path: "route-eta/\(safeRoute)/1", reloadIgnoringCache: true)
        return response.data
    }
    
    /// 按畫面需要排序並回傳結果。
    /// - Parameters:
    ///   - from: 此函式需要嘅輸入資料。
    ///   - route: 路線編號或路線模型。
    ///   - directionCode: 巴士方向資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func sortedDisplayETAs(from items: [StopETAItem], route: String? = nil, directionCode: String? = nil) -> [ETADisplayInfo] {
        let formatter = ISO8601DateFormatter()
        let staleETAThreshold = Date().addingTimeInterval(-60)
        return items.compactMap { item -> ETADisplayInfo? in
            if let route, item.route != route { return nil }
            if let directionCode, item.dir != directionCode { return nil }
            guard item.service_type == 1,
                  let etaText = item.eta,
                  !etaText.isEmpty,
                  let etaDate = formatter.date(from: etaText),
                  etaDate >= staleETAThreshold else {
                return nil
            }
            return ETADisplayInfo(etaDate: etaDate, remark: item.rmk_tc, companyCode: operatorCode.rawValue)
        }
        .sorted { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
    }
    
    /// 按畫面需要排序並回傳結果。
    /// - Parameters:
    ///   - first: 此函式需要嘅輸入資料。
    ///   - second: 此函式需要嘅輸入資料。
    /// - Returns: 條件是否成立。
    func sortRouteSuggestions(_ first: RouteSuggestion, _ second: RouteSuggestion) -> Bool {
        if first.route == second.route {
            return first.bound > second.bound
        }
        return first.route.localizedStandardCompare(second.route) == .orderedAscending
    }
}
