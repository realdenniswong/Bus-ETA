/// 檔案用途：處理城巴資料來源、CSV 快取、API 站點、ETA 同聯營路線配對。
import CoreLocation
import Foundation

/// `CTBETAProvider` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct CTBETAProvider: BusETAProvider {
    static let shared = CTBETAProvider()

    let operatorCode: BusOperator = .ctb

    private let baseURL = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/")!
    private let jsonDecoder = JSONDecoder()
    private let routeStore = CTBRouteStore.shared

    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；完成物件初始化。
    private init() { }

    /// 讀取 CTB 路線清單同 CSV 公司標記，並轉成搜尋建議。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 已整理同排序嘅 CTB／聯營路線建議列表。
    func fetchRouteSuggestions() async throws -> [RouteSuggestion] {
        let routes = try await loadRouteList()
        routeStore.loadCSVDataIfNeeded()

        return routes.flatMap { route in
            [BusDirection.outbound, .inbound].map { direction in
                RouteSuggestion(
                    co: routeStore.companyCode(route: route.route, direction: direction) ?? route.co ?? operatorCode.rawValue,
                    route: route.route.uppercased(),
                    bound: direction.routeCode,
                    origin: direction == .outbound ? route.orig_tc : route.dest_tc,
                    destination: direction == .outbound ? route.dest_tc : route.orig_tc
                )
            }
        }
        .sorted(by: sortRouteSuggestions)
    }

    /// 讀取 CSV 快取入面可用嘅 CTB 車站資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 已載入快取嘅車站資料列表。
    func fetchStops() async throws -> [StopInfo] {
        routeStore.loadCSVDataIfNeeded()
        return routeStore.stops
    }

    /// 用指定車站識別碼查找 CTB／聯營附近路線，並配對可用 ETA。
    /// - Parameters:
    ///   - forStopId: 要查詢嘅車站識別碼。
    /// - Returns: 已按路線整理同排序嘅附近路線顯示資料。
    func fetchNearbyRoutes(forStopId stopId: String) async throws -> [NearbyRouteModel] {
        _ = try await loadRouteList()
        routeStore.loadCSVDataIfNeeded()

        let targetStopInfo = routeStore.stopInfo(stopId: stopId)
        let directions = routeStore.routeDirections(servingStopId: stopId)
        let models = await nearbyRouteModels(for: directions, near: targetStopInfo?.clLocation)

        return models.sorted {
            if $0.route == $1.route { return $0.directionCode < $1.directionCode }
            return $0.route.localizedStandardCompare($1.route) == .orderedAscending
        }
    }

    /// 讀取 CTB 指定路線方向嘅站序、站名同每站 ETA。
    /// - Parameters:
    ///   - route: 要查詢嘅路線編號。
    ///   - direction: 要查詢嘅行車方向。
    ///   - stopNameById: 以車站識別碼索引嘅備用站名對照表。
    /// - Returns: 已按站序整理嘅 CTB 時間表顯示列。
    func fetchTimetableRows(route: String, direction: BusDirection, stopNameById: [String: String]) async throws -> [StopDisplayModel] {
        let rows = try await fetchAPIRouteStops(route: route, direction: direction)
        return await withTaskGroup(of: StopDisplayModel.self) { group in
            for row in rows.sorted(by: { $0.stopSequence < $1.stopSequence }) {
                group.addTask {
                    async let stopInfo = try? fetchStopInfo(stopId: row.stopId)
                    async let etas = (try? fetchCTBETAs(stopId: row.stopId, route: route, direction: direction)) ?? []
                    let resolvedStopInfo = await stopInfo
                    let resolvedETAs = await etas
                    return StopDisplayModel(
                        seq: row.stopSequence,
                        stopId: row.stopId,
                        stopNameTc: resolvedStopInfo?.name_tc ?? stopNameById[row.stopId] ?? "未知車站",
                        etas: Array(resolvedETAs.prefix(3)),
                        location: resolvedStopInfo.flatMap { Self.stopLocation(from: $0) },
                        operatorStopIds: [operatorCode.rawValue: row.stopId]
                    )
                }
            }

            var displayRows: [StopDisplayModel] = []
            for await row in group {
                displayRows.append(row)
            }
            return displayRows.sorted { $0.seq < $1.seq }
        }
    }

    /// 找出 CTB 收藏路線最接近用戶嘅上車站，並讀取該站 ETA。
    /// - Parameters:
    ///   - for: 要更新狀態嘅收藏路線。
    ///   - context: 查找站點同位置所需嘅上下文資料。
    /// - Returns: 找到最近有效站點時回傳收藏狀態；否則為 nil。
    func fetchFavoriteStatus(for favorite: FavoriteRoute, context: RouteStopLookupContext) async throws -> FavoriteStatusModel? {
        let direction = BusDirection(rawValue: favorite.direction) ?? .outbound
        let rows = try await fetchAPIRouteStops(route: favorite.route, direction: direction)

        var nearestRow: CTBRouteStopRow?
        var nearestStopInfo: StopInfo?
        var nearestDistance: CLLocationDistance = .infinity

        for row in rows {
            guard let stopInfo = try? await fetchStopInfo(stopId: row.stopId),
                  let rowLocation = Self.stopLocation(from: stopInfo) else { continue }
            let distance = context.userLocation.distance(from: rowLocation)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestRow = row
                nearestStopInfo = stopInfo
            }
        }

        guard let nearestRow, let nearestStopInfo else { return nil }
        let etas = try await fetchCTBETAs(stopId: nearestRow.stopId, route: favorite.route, direction: direction)
        return FavoriteStatusModel(
            etas: Array(etas.prefix(3)),
            distance: nearestDistance,
            stopName: nearestStopInfo.name_tc,
            stopId: nearestRow.stopId,
            operatorStopIds: [operatorCode.rawValue: nearestRow.stopId]
        )
    }

    /// 讀取 CTB 指定路線、方向同車站嘅倒數計時 ETA。
    /// - Parameters:
    ///   - route: 要查詢嘅路線編號。
    ///   - direction: 要查詢嘅行車方向。
    ///   - stopId: 要查詢嘅 CTB 車站識別碼。
    /// - Returns: 已過濾同排序嘅 ETA 顯示資料列表。
    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String) async throws -> [ETADisplayInfo] {
        try await fetchCTBETAs(stopId: stopId, route: route, direction: direction)
    }
}

/// 擴充 `CTBETAProvider`，加入此檔案負責嘅相關功能。
extension CTBETAProvider {
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - near: 此函式需要嘅輸入資料。
    ///   - limit: 最多回傳嘅項目數量。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func nearbyStops(near location: CLLocation, limit: Int) async throws -> [StopInfo] {
        routeStore.loadCSVDataIfNeeded()
        return routeStore.nearbyStops(near: location, limit: limit)
    }

    /// 以座標查找附近 CTB／聯營路線，並配對可用 ETA。
    /// - Parameters:
    ///   - near: 用嚟查找附近車站嘅座標。
    /// - Returns: 已按路線整理同排序嘅附近路線顯示資料。
    func fetchNearbyRoutes(near location: CLLocation) async throws -> [NearbyRouteModel] {
        _ = try await loadRouteList()
        routeStore.loadCSVDataIfNeeded()
        let directions = routeStore.routeDirections(near: location, radius: 120, limitStops: 3)
        let models = await nearbyRouteModels(for: directions, near: location)

        return models.sorted {
            if $0.route == $1.route { return $0.directionCode < $1.directionCode }
            return $0.route.localizedStandardCompare($1.route) == .orderedAscending
        }
    }

    /// 判斷指定條件是否成立。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 條件是否成立。
    func isJointRoute(route: String, direction: BusDirection) -> Bool {
        routeStore.loadCSVDataIfNeeded()
        return routeStore.companyCode(route: route, direction: direction) == "KMB+CTB"
    }

    /// 整理或查找巴士公司顯示資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 格式化或查找後嘅文字。
    func companyCode(route: String, direction: BusDirection) -> String? {
        routeStore.loadCSVDataIfNeeded()
        return routeStore.companyCode(route: route, direction: direction)
    }
}

/// 擴充 `CTBETAProvider`，加入此檔案負責嘅相關功能。
private extension CTBETAProvider {
    /// 計算或讀取附近站點同路線資料。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    ///   - near: 此函式需要嘅輸入資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func nearbyRouteModels(for directions: [CTBRouteDirection], near location: CLLocation?) async -> [NearbyRouteModel] {
        await withTaskGroup(of: NearbyRouteModel.self) { group in
            for direction in directions {
                group.addTask {
                    await nearbyRouteModel(for: direction, near: location)
                }
            }
            
            var models: [NearbyRouteModel] = []
            for await model in group {
                models.append(model)
            }
            return models
        }
    }
    
    /// 計算或讀取附近站點同路線資料。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    ///   - near: 此函式需要嘅輸入資料。
    /// - Returns: 計算後嘅 `NearbyRouteModel`。
    func nearbyRouteModel(for direction: CTBRouteDirection, near location: CLLocation?) async -> NearbyRouteModel {
        let apiStopId = await matchedAPIStopId(
            route: direction.routeName,
            direction: direction.bound,
            preferredStopId: direction.sourceStopId,
            near: location
        )
        let etas: [ETADisplayInfo]
        let matchedStopName: String?
        if let apiStopId {
            matchedStopName = (try? await fetchStopInfo(stopId: apiStopId))?.name_tc
            etas = (try? await fetchCTBETAs(stopId: apiStopId, route: direction.routeName, direction: direction.bound)) ?? []
        } else {
            matchedStopName = nil
            etas = []
        }
        
        return NearbyRouteModel(
            co: direction.companyCode,
            route: direction.routeName,
            directionCode: direction.bound.routeCode,
            destNameTc: direction.destinationName,
            displayStopName: direction.companyCode == BusOperator.ctb.rawValue ? matchedStopName : nil,
            displayStopId: apiStopId,
            etas: Array(etas.prefix(3)),
            operatorStopIds: apiStopId.map { [operatorCode.rawValue: $0] } ?? [:]
        )
    }
    
    /// 載入需要嘅資料並更新本機狀態或快取。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func loadRouteList() async throws -> [CTBRouteAPIItem] {
        if let routes = routeStore.routeListIfLoaded() {
            return routes
        }

        let task = routeStore.routeListTaskOrCreate {
            Task {
                let response: CTBRouteResponse = try await fetch(path: "route/CTB")
                return response.data
            }
        }

        do {
            let routes = try await task.value
            routeStore.clearRouteListTask()
            return routeStore.updateRouteList(routes)
        } catch {
            routeStore.clearRouteListTask()
            throw error
        }
    }

    /// 讀取並快取 CTB API 回傳嘅指定路線站序。
    /// - Parameters:
    ///   - route: 要查詢嘅路線編號。
    ///   - direction: 要查詢嘅行車方向。
    /// - Returns: 已轉成內部格式並按路線方向快取嘅站序資料。
    func fetchAPIRouteStops(route: String, direction: BusDirection) async throws -> [CTBRouteStopRow] {
        if let rows = routeStore.apiRouteStops(route: route, direction: direction) {
            return rows
        }

        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
        let task = routeStore.apiRouteStopsTaskOrCreate(route: route, direction: direction) {
            Task {
                let response: CTBRouteStopResponse = try await fetch(path: "route-stop/CTB/\(safeRoute)/\(direction.apiRouteStopPathComponent)")
                return response.data.map {
                    CTBRouteStopRow(
                        routeName: $0.route.uppercased(),
                        direction: BusDirection(routeCode: $0.dir),
                        stopSequence: $0.seq.intValue,
                        stopId: $0.stop
                    )
                }
            }
        }

        do {
            let rows = try await task.value
            routeStore.clearAPIRouteStopsTask(route: route, direction: direction)
            return routeStore.updateAPIRouteStops(rows, route: route, direction: direction)
        } catch {
            routeStore.clearAPIRouteStopsTask(route: route, direction: direction)
            throw error
        }
    }

    /// 讀取指定 CTB 車站詳情，並寫入本機車站快取。
    /// - Parameters:
    ///   - stopId: 要查詢嘅 CTB 車站識別碼。
    /// - Returns: 找到完整站點資料時回傳 `StopInfo`；否則為 nil。
    func fetchStopInfo(stopId: String) async throws -> StopInfo? {
        if let stopInfo = routeStore.stopInfo(stopId: stopId) {
            return stopInfo
        }

        let safeStopId = stopId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stopId
        let response: CTBStopDetailResponse = try await fetch(path: "stop/\(safeStopId)")
        guard let stop = response.data.stop,
              let name = response.data.name_tc,
              let latitude = response.data.lat,
              let longitude = response.data.long else {
            return nil
        }

        let stopInfo = StopInfo(stop: stop, name_tc: name, lat: latitude, long: longitude, operatorCode: operatorCode)
        routeStore.updateStopInfo(stopInfo)
        return stopInfo
    }

    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - preferredStopId: 車站識別或車站資料。
    ///   - near: 此函式需要嘅輸入資料。
    /// - Returns: 格式化或查找後嘅文字。
    func matchedAPIStopId(route: String, direction: BusDirection, preferredStopId: String?, near location: CLLocation?) async -> String? {
        guard let location else { return nil }
        guard let rows = try? await fetchAPIRouteStops(route: route, direction: direction) else { return nil }
        if let preferredStopId,
           rows.contains(where: { $0.stopId == preferredStopId }) {
            return preferredStopId
        }
        if let cachedStopId = routeStore.matchedStopId(route: route, direction: direction, near: location) {
            return cachedStopId
        }

        let bestMatch = await withTaskGroup(of: (stopId: String, distance: CLLocationDistance)?.self) { group in
            for row in rows {
                group.addTask {
                    guard let stopInfo = try? await fetchStopInfo(stopId: row.stopId),
                          let stopLocation = Self.stopLocation(from: stopInfo) else { return nil }
                    return (row.stopId, location.distance(from: stopLocation))
                }
            }

            var bestMatch: (stopId: String, distance: CLLocationDistance)?
            for await match in group {
                guard let match else { continue }
                if bestMatch == nil || match.distance < bestMatch!.distance {
                    bestMatch = match
                }
            }
            return bestMatch
        }

        // CTB 匯入 CSV 嘅座標同 v2 車站 API 座標，就算同名車站都可能相差超過 200 米，
        // 所以呢度要比一般站柱配對用更闊嘅距離容許值。
        guard let bestMatch, bestMatch.distance <= 350 else { return nil }
        routeStore.updateMatchedStopId(bestMatch.stopId, route: route, direction: direction, near: location)
        return bestMatch.stopId
    }

    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - from: 此函式需要嘅輸入資料。
    /// - Returns: 可用嘅位置資料；沒有時為 nil。
    nonisolated static func stopLocation(from stopInfo: StopInfo) -> CLLocation? {
        guard let latitudeText = stopInfo.lat,
              let longitudeText = stopInfo.long,
              let latitude = Double(latitudeText),
              let longitude = Double(longitudeText) else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    /// 讀取指定 CTB 車站、路線同方向嘅 ETA，並使用短期快取避免重複請求。
    /// - Parameters:
    ///   - stopId: 要查詢嘅 CTB 車站識別碼。
    ///   - route: 要查詢嘅路線編號。
    ///   - direction: 要查詢嘅行車方向。
    /// - Returns: 已過濾同排序嘅 ETA 顯示資料列表。
    func fetchCTBETAs(stopId: String, route: String, direction: BusDirection) async throws -> [ETADisplayInfo] {
        if let cachedETAs = routeStore.cachedETAs(stopId: stopId, route: route, direction: direction) {
            return cachedETAs
        }

        let safeStopId = stopId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stopId
        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
        let task = routeStore.etaTaskOrCreate(stopId: stopId, route: route, direction: direction) {
            Task {
                let response: CTBETAResponse = try await fetch(path: "eta/CTB/\(safeStopId)/\(safeRoute)", reloadIgnoringCache: true)
                let formatter = ISO8601DateFormatter()
                let staleETAThreshold = Date().addingTimeInterval(-60)

                return response.data.compactMap { item -> ETADisplayInfo? in
                    if item.route.uppercased() != route.uppercased() { return nil }
                    if let itemDirection = item.dir, itemDirection != direction.routeCode { return nil }
                    guard let etaText = item.eta,
                          !etaText.isEmpty,
                          let etaDate = formatter.date(from: etaText),
                          etaDate >= staleETAThreshold else {
                        return nil
                    }

                    return ETADisplayInfo(etaDate: etaDate, remark: item.rmk_tc, companyCode: operatorCode.rawValue)
                }
                .sorted { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
            }
        }

        do {
            let etas = try await task.value
            routeStore.clearETATask(stopId: stopId, route: route, direction: direction)
            routeStore.updateETACache(etas, stopId: stopId, route: route, direction: direction)
            return etas
        } catch {
            routeStore.clearETATask(stopId: stopId, route: route, direction: direction)
            throw error
        }
    }

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
        print("[Performance] JSON decoding CTB \(path): \(Int(Date().timeIntervalSince(decodeStart) * 1_000))ms")
        return response
    }

    /// 按畫面需要排序並回傳結果。
    /// - Parameters:
    ///   - first: 此函式需要嘅輸入資料。
    ///   - second: 此函式需要嘅輸入資料。
    /// - Returns: 條件是否成立。
    func sortRouteSuggestions(_ first: RouteSuggestion, _ second: RouteSuggestion) -> Bool {
        if first.route == second.route {
            if first.bound == second.bound {
                return first.co < second.co
            }
            return first.bound > second.bound
        }
        return first.route.localizedStandardCompare(second.route) == .orderedAscending
    }

}

/// `CTBRouteResponse` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
private struct CTBRouteResponse: Decodable {
    let data: [CTBRouteAPIItem]
}

/// `CTBRouteAPIItem` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
private struct CTBRouteAPIItem: Decodable {
    let co: String?
    let route: String
    let orig_tc: String
    let dest_tc: String
}

/// `CTBRouteStopResponse` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
private struct CTBRouteStopResponse: Decodable {
    let data: [CTBRouteStopAPIItem]
}

/// `CTBRouteStopAPIItem` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
private struct CTBRouteStopAPIItem: Decodable {
    let route: String
    let dir: String
    let seq: FlexibleInt
    let stop: String
}

/// `CTBStopDetailResponse` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
private struct CTBStopDetailResponse: Decodable {
    let data: CTBStopDetailData
}

/// `CTBStopDetailData` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
private struct CTBStopDetailData: Decodable {
    let stop: String?
    let name_tc: String?
    let lat: String?
    let long: String?
}

/// `CTBETAResponse` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
private struct CTBETAResponse: Decodable {
    let data: [CTBETAItem]
}

/// `CTBETAItem` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
private struct CTBETAItem: Decodable {
    let route: String
    let dir: String?
    let eta: String?
    let rmk_tc: String?
}

/// `FlexibleInt` 列出此功能範圍會用到嘅固定選項。
private enum FlexibleInt: Decodable {
    case value(Int)

    var intValue: Int {
        switch self {
        case .value(let value):
            return value
        }
    }

    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - from: 此函式需要嘅輸入資料。
    /// - Returns: 無回傳值；完成物件初始化。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .value(intValue)
            return
        }
        let stringValue = try container.decode(String.self)
        self = .value(Int(stringValue) ?? 0)
    }
}

private final class CTBRouteStore {
    static let shared = CTBRouteStore()

    private(set) var stops: [StopInfo] = []
    private var routeList: [CTBRouteAPIItem] = []
    private var csvDirectionsByStopId: [String: [CTBRouteDirection]] = [:]
    private var companyCodeByRouteDirection: [String: String] = [:]
    private var apiRowsByRouteDirection: [String: [CTBRouteStopRow]] = [:]
    private var stopInfoById: [String: StopInfo] = [:]
    private var matchedStopIdByRouteDirectionLocation: [String: String] = [:]
    private var routeListTask: Task<[CTBRouteAPIItem], Error>?
    private var apiRowsTasksByRouteDirection: [String: Task<[CTBRouteStopRow], Error>] = [:]
    private var etaTasksByStopRouteDirection: [String: Task<[ETADisplayInfo], Error>] = [:]
    private var etaCacheByStopRouteDirection: [String: (updatedAt: Date, etas: [ETADisplayInfo])] = [:]
    private var hasLoadedCSVData = false
    private let etaCacheLifetime: TimeInterval = 12
    private let lock = NSLock()

    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；完成物件初始化。
    private init() { }

    /// 載入需要嘅資料並更新本機狀態或快取。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func routeListIfLoaded() -> [CTBRouteAPIItem]? {
        lock.lock()
        defer { lock.unlock() }
        return routeList.isEmpty ? nil : routeList
    }

    /// 更新相關狀態，令畫面或快取保持最新。
    /// - Parameters:
    ///   - routes: 路線編號或路線模型。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func updateRouteList(_ routes: [CTBRouteAPIItem]) -> [CTBRouteAPIItem] {
        lock.lock()
        defer { lock.unlock() }
        routeList = routes.map {
            CTBRouteAPIItem(co: $0.co, route: $0.route.uppercased(), orig_tc: $0.orig_tc, dest_tc: $0.dest_tc)
        }
        return routeList
    }

    /// 判斷指定條件是否成立。
    /// - Parameters:
    ///   - createTask: 時間或到站時間資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func routeListTaskOrCreate(_ createTask: () -> Task<[CTBRouteAPIItem], Error>) -> Task<[CTBRouteAPIItem], Error> {
        lock.lock()
        defer { lock.unlock() }
        if let routeListTask {
            return routeListTask
        }
        let task = createTask()
        routeListTask = task
        return task
    }

    /// 清除指定狀態或暫存資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func clearRouteListTask() {
        lock.lock()
        defer { lock.unlock() }
        routeListTask = nil
    }

    /// 載入需要嘅資料並更新本機狀態或快取。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func loadCSVDataIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasLoadedCSVData else { return }
        hasLoadedCSVData = true

        guard let csvURL = csvResourceURL() else {
            print("Bus route CSV resource not found in app bundle or project checkout.")
            return
        }
        
        if loadParsedCSVCache(for: csvURL) {
            return
        }
        
        guard let content = try? String(contentsOf: csvURL, encoding: .utf8) else {
            print("Unable to read bus route CSV resource.")
            return
        }

        let records = CSVParser.parse(content)
        guard let headerIndex = records.firstIndex(where: { record in
            record.contains("ROUTE_SEQ") && record.contains("ROUTE_NAMEC") && record.contains("COMPANY_CODE")
        }) else { return }
        let header = records[headerIndex]
        let indexes = Dictionary(header.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })

        var directionsByStopId: [String: [CTBRouteDirection]] = [:]
        var stopInfoById: [String: StopInfo] = stopInfoById
        var csvStopsById: [String: StopInfo] = [:]
        var csvRouteRows: [CTBCSVRouteRow] = []
        var terminalsByRouteDirection: [String: (origin: CTBCSVRouteRow, destination: CTBCSVRouteRow)] = [:]

        for record in records.dropFirst(headerIndex + 1) {
            guard let routeName = value("ROUTE_NAMEC", in: record, indexes: indexes),
                  let routeSequence = value("ROUTE_SEQ", in: record, indexes: indexes),
                  let direction = BusDirection(routeSequence: routeSequence),
                  let stopSequenceText = value("STOP_SEQ", in: record, indexes: indexes),
                  let stopSequence = Int(stopSequenceText),
                  let stopId = value("STOP_ID", in: record, indexes: indexes),
                  let stopName = value("STOP_NAMEC", in: record, indexes: indexes),
                  let longitude = value("Longitude", in: record, indexes: indexes),
                  let latitude = value("Latitude", in: record, indexes: indexes),
                  let companyCode = value("COMPANY_CODE", in: record, indexes: indexes) else {
                continue
            }

            let routeCode = routeName.uppercased()
            let cleanStopName = cleanStopName(stopName)
            let stopInfo = StopInfo(stop: stopId, name_tc: cleanStopName, lat: latitude, long: longitude, operatorCode: .ctb)
            let csvRouteRow = CTBCSVRouteRow(
                routeName: routeCode,
                direction: direction,
                stopSequence: stopSequence,
                stopId: stopId,
                stopName: cleanStopName,
                companyCode: companyCode
            )
            let routeDirectionKey = key(route: routeCode, direction: direction)
            
            companyCodeByRouteDirection[routeDirectionKey] = companyCode
            guard companyCode != BusOperator.kmb.rawValue else { continue }
            
            csvStopsById[stopId] = stopInfo
            stopInfoById[stopId] = stopInfo
            csvRouteRows.append(csvRouteRow)
            
            if let terminals = terminalsByRouteDirection[routeDirectionKey] {
                terminalsByRouteDirection[routeDirectionKey] = (
                    origin: stopSequence < terminals.origin.stopSequence ? csvRouteRow : terminals.origin,
                    destination: stopSequence > terminals.destination.stopSequence ? csvRouteRow : terminals.destination
                )
            } else {
                terminalsByRouteDirection[routeDirectionKey] = (origin: csvRouteRow, destination: csvRouteRow)
            }
        }
        
        for row in csvRouteRows {
            let terminals = terminalsByRouteDirection[key(route: row.routeName, direction: row.direction)]
            let directionModel = CTBRouteDirection(
                routeName: row.routeName,
                bound: row.direction,
                sourceStopId: row.stopId,
                originName: terminals?.origin.stopName ?? "起點站",
                destinationName: terminals?.destination.stopName ?? "終點站",
                companyCode: row.companyCode
            )
            directionsByStopId[row.stopId, default: []].append(directionModel)
        }

        self.stops = Array(csvStopsById.values)
        self.stopInfoById = stopInfoById
        self.csvDirectionsByStopId = directionsByStopId.mapValues { directions in
            Array(Set(directions)).sorted {
                if $0.routeName == $1.routeName { return $0.bound.routeCode < $1.bound.routeCode }
                return $0.routeName.localizedStandardCompare($1.routeName) == .orderedAscending
            }
        }
        saveParsedCSVCache(for: csvURL)
    }

    /// 整理或查找路線相關資料。
    /// - Parameters:
    ///   - servingStopId: 車站識別或車站資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func routeDirections(servingStopId stopId: String) -> [CTBRouteDirection] {
        lock.lock()
        defer { lock.unlock() }

        return enrichedDirections(csvDirectionsByStopId[stopId] ?? [])
    }
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - near: 此函式需要嘅輸入資料。
    ///   - limit: 最多回傳嘅項目數量。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func nearbyStops(near location: CLLocation, limit: Int) -> [StopInfo] {
        lock.lock()
        defer { lock.unlock() }
        return stops.compactMap { stopInfo -> (stopInfo: StopInfo, distance: CLLocationDistance)? in
            guard let stopLocation = stopLocation(from: stopInfo) else { return nil }
            return (stopInfo, location.distance(from: stopLocation))
        }
        .sorted { $0.distance < $1.distance }
        .prefix(limit)
        .map(\.stopInfo)
    }
    
    /// 整理或查找路線相關資料。
    /// - Parameters:
    ///   - near: 此函式需要嘅輸入資料。
    ///   - radius: 搜尋半徑。
    ///   - limitStops: 車站識別或車站資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func routeDirections(near location: CLLocation, radius: CLLocationDistance, limitStops: Int) -> [CTBRouteDirection] {
        lock.lock()
        defer { lock.unlock() }

        let nearbyStopIds = stops.compactMap { stopInfo -> (stopId: String, distance: CLLocationDistance)? in
            guard let stopLocation = stopLocation(from: stopInfo) else { return nil }
            let distance = location.distance(from: stopLocation)
            guard distance <= radius else { return nil }
            return (stopInfo.stop, distance)
        }
        .sorted { $0.distance < $1.distance }
        .prefix(limitStops)
        .map(\.stopId)

        var seenKeys = Set<String>()
        let directions = nearbyStopIds.flatMap { csvDirectionsByStopId[$0] ?? [] }.filter { direction in
            let key = "\(direction.routeName)-\(direction.bound.rawValue)-\(direction.companyCode)"
            return seenKeys.insert(key).inserted
        }
        return enrichedDirections(directions)
    }

    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - from: 此函式需要嘅輸入資料。
    /// - Returns: 可用嘅位置資料；沒有時為 nil。
    private func stopLocation(from stopInfo: StopInfo) -> CLLocation? {
        guard let latitudeText = stopInfo.lat,
              let longitudeText = stopInfo.long,
              let latitude = Double(latitudeText),
              let longitude = Double(longitudeText) else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - directions: 巴士方向資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    private func enrichedDirections(_ directions: [CTBRouteDirection]) -> [CTBRouteDirection] {
        directions
    }

    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func apiRouteStops(route: String, direction: BusDirection) -> [CTBRouteStopRow]? {
        lock.lock()
        defer { lock.unlock() }
        return apiRowsByRouteDirection[key(route: route.uppercased(), direction: direction)]
    }

    /// 更新相關狀態，令畫面或快取保持最新。
    /// - Parameters:
    ///   - rows: 要處理嘅資料集合。
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func updateAPIRouteStops(_ rows: [CTBRouteStopRow], route: String, direction: BusDirection) -> [CTBRouteStopRow] {
        lock.lock()
        defer { lock.unlock() }
        let sortedRows = rows.sorted { $0.stopSequence < $1.stopSequence }
        apiRowsByRouteDirection[key(route: route.uppercased(), direction: direction)] = sortedRows
        return sortedRows
    }

    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - createTask: 時間或到站時間資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func apiRouteStopsTaskOrCreate(route: String, direction: BusDirection, createTask: () -> Task<[CTBRouteStopRow], Error>) -> Task<[CTBRouteStopRow], Error> {
        lock.lock()
        defer { lock.unlock() }
        let taskKey = key(route: route, direction: direction)
        if let task = apiRowsTasksByRouteDirection[taskKey] {
            return task
        }
        let task = createTask()
        apiRowsTasksByRouteDirection[taskKey] = task
        return task
    }

    /// 清除指定狀態或暫存資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func clearAPIRouteStopsTask(route: String, direction: BusDirection) {
        lock.lock()
        defer { lock.unlock() }
        apiRowsTasksByRouteDirection[key(route: route, direction: direction)] = nil
    }

    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - stopId: 車站識別或車站資料。
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func cachedETAs(stopId: String, route: String, direction: BusDirection) -> [ETADisplayInfo]? {
        lock.lock()
        defer { lock.unlock() }
        guard let cacheEntry = etaCacheByStopRouteDirection[etaKey(stopId: stopId, route: route, direction: direction)],
              Date().timeIntervalSince(cacheEntry.updatedAt) <= etaCacheLifetime else {
            return nil
        }
        return cacheEntry.etas
    }

    /// 更新相關狀態，令畫面或快取保持最新。
    /// - Parameters:
    ///   - etas: 時間或到站時間資料。
    ///   - stopId: 車站識別或車站資料。
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func updateETACache(_ etas: [ETADisplayInfo], stopId: String, route: String, direction: BusDirection) {
        lock.lock()
        defer { lock.unlock() }
        etaCacheByStopRouteDirection[etaKey(stopId: stopId, route: route, direction: direction)] = (Date(), etas)
    }

    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - stopId: 車站識別或車站資料。
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - createTask: 時間或到站時間資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func etaTaskOrCreate(stopId: String, route: String, direction: BusDirection, createTask: () -> Task<[ETADisplayInfo], Error>) -> Task<[ETADisplayInfo], Error> {
        lock.lock()
        defer { lock.unlock() }
        let taskKey = etaKey(stopId: stopId, route: route, direction: direction)
        if let task = etaTasksByStopRouteDirection[taskKey] {
            return task
        }
        let task = createTask()
        etaTasksByStopRouteDirection[taskKey] = task
        return task
    }

    /// 清除指定狀態或暫存資料。
    /// - Parameters:
    ///   - stopId: 車站識別或車站資料。
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func clearETATask(stopId: String, route: String, direction: BusDirection) {
        lock.lock()
        defer { lock.unlock() }
        etaTasksByStopRouteDirection[etaKey(stopId: stopId, route: route, direction: direction)] = nil
    }

    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - stopId: 車站識別或車站資料。
    /// - Returns: 找到時回傳對應資料；沒有時為 nil。
    func stopInfo(stopId: String) -> StopInfo? {
        lock.lock()
        defer { lock.unlock() }
        return stopInfoById[stopId]
    }

    /// 更新相關狀態，令畫面或快取保持最新。
    /// - Parameters:
    ///   - stopInfo: 車站識別或車站資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func updateStopInfo(_ stopInfo: StopInfo) {
        lock.lock()
        defer { lock.unlock() }
        stopInfoById[stopInfo.stop] = stopInfo
    }
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - near: 此函式需要嘅輸入資料。
    /// - Returns: 格式化或查找後嘅文字。
    func matchedStopId(route: String, direction: BusDirection, near location: CLLocation) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return matchedStopIdByRouteDirectionLocation[locationKey(route: route, direction: direction, location: location)]
    }
    
    /// 更新相關狀態，令畫面或快取保持最新。
    /// - Parameters:
    ///   - stopId: 車站識別或車站資料。
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - near: 此函式需要嘅輸入資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func updateMatchedStopId(_ stopId: String, route: String, direction: BusDirection, near location: CLLocation) {
        lock.lock()
        defer { lock.unlock() }
        matchedStopIdByRouteDirectionLocation[locationKey(route: route, direction: direction, location: location)] = stopId
    }

    /// 整理或查找巴士公司顯示資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 格式化或查找後嘅文字。
    func companyCode(route: String, direction: BusDirection) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return companyCodeByRouteDirection[key(route: route.uppercased(), direction: direction)]
    }

    /// 載入需要嘅資料並更新本機狀態或快取。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    /// - Returns: 條件是否成立。
    private func loadParsedCSVCache(for csvURL: URL) -> Bool {
        guard let cacheURL = parsedCSVCacheURL(),
              let data = try? Data(contentsOf: cacheURL),
              let snapshot = try? JSONDecoder().decode(CTBParsedCSVSnapshot.self, from: data),
              snapshot.version == CTBParsedCSVSnapshot.currentVersion,
              snapshot.sourceFingerprint == csvFingerprint(for: csvURL),
              !snapshot.stops.isEmpty else {
            return false
        }
        
        self.stops = snapshot.stops
        self.stopInfoById = snapshot.stopInfoById
        self.csvDirectionsByStopId = snapshot.directionsByStopId
        self.companyCodeByRouteDirection = snapshot.companyCodeByRouteDirection
        return true
    }
    
    /// 解析輸入內容並轉成程式可用資料。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func saveParsedCSVCache(for csvURL: URL) {
        guard let cacheURL = parsedCSVCacheURL() else { return }
        do {
            let snapshot = CTBParsedCSVSnapshot(
                version: CTBParsedCSVSnapshot.currentVersion,
                sourceFingerprint: csvFingerprint(for: csvURL),
                stops: stops,
                stopInfoById: stopInfoById,
                directionsByStopId: csvDirectionsByStopId,
                companyCodeByRouteDirection: companyCodeByRouteDirection
            )
            let directoryURL = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: cacheURL, options: [.atomic])
        } catch {
            print("Failed to save parsed CTB CSV cache: \(error)")
        }
    }
    
    /// 解析輸入內容並轉成程式可用資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 找到時回傳對應資料；沒有時為 nil。
    private func parsedCSVCacheURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("KMB Time", isDirectory: true)
            .appendingPathComponent("ctb-parsed-csv-cache.json")
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    /// - Returns: 格式化或查找後嘅文字。
    private func csvFingerprint(for csvURL: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: csvURL.path) else {
            return csvURL.lastPathComponent
        }
        let fileSize = attributes[.size] as? NSNumber
        let modifiedAt = attributes[.modificationDate] as? Date
        return "\(csvURL.lastPathComponent)-\(fileSize?.int64Value ?? 0)-\(modifiedAt?.timeIntervalSince1970 ?? 0)"
    }

    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 找到時回傳對應資料；沒有時為 nil。
    private func csvResourceURL() -> URL? {
        let resourceNames = ["bus_routes_all_stops", "ctb_routes_all_stops"]
        
        for resourceName in resourceNames {
            if let rootURL = Bundle.main.url(forResource: resourceName, withExtension: "csv") {
                return rootURL
            }
            if let groupedURL = Bundle.main.url(forResource: resourceName, withExtension: "csv", subdirectory: "KMB Time") {
                return groupedURL
            }
        }
        
        if let resourceURL = Bundle.main.resourceURL {
            for resourceName in resourceNames {
                guard let enumerator = FileManager.default.enumerator(at: resourceURL, includingPropertiesForKeys: nil) else { continue }
                let fileName = "\(resourceName).csv"
                for case let fileURL as URL in enumerator where fileURL.lastPathComponent == fileName {
                    return fileURL
                }
            }
        }

        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let sourceRoots = [
            sourceFileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
            sourceFileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("KMB Time")
        ]
        for resourceName in resourceNames {
            for sourceRoot in sourceRoots {
                let url = sourceRoot.appendingPathComponent("\(resourceName).csv")
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }

        let fallbackPaths = resourceNames.flatMap { resourceName in
            [
                "KMB Time/\(resourceName).csv",
                "KMB Time/KMB Time/\(resourceName).csv"
            ]
        }
        for path in fallbackPaths {
            let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - name: 畫面顯示文字。
    ///   - in: 此函式需要嘅輸入資料。
    ///   - indexes: 此函式需要嘅輸入資料。
    /// - Returns: 格式化或查找後嘅文字。
    private func value(_ name: String, in record: [String], indexes: [String: Int]) -> String? {
        guard let index = indexes[name], index < record.count else { return nil }
        let trimmed = record[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 建立用於查找或快取嘅穩定 key。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 格式化或查找後嘅文字。
    private func key(route: String, direction: BusDirection) -> String {
        "\(route.uppercased())-\(direction.rawValue)"
    }
    
    /// 建立用於查找或快取嘅穩定 key。
    /// - Parameters:
    ///   - stopId: 車站識別或車站資料。
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 格式化或查找後嘅文字。
    private func etaKey(stopId: String, route: String, direction: BusDirection) -> String {
        "\(stopId)-\(route.uppercased())-\(direction.rawValue)"
    }
    
    /// 建立用於查找或快取嘅穩定 key。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - location: 用嚟計算距離嘅位置。
    /// - Returns: 格式化或查找後嘅文字。
    private func locationKey(route: String, direction: BusDirection, location: CLLocation) -> String {
        "\(key(route: route, direction: direction))-\(String(format: "%.5f", location.coordinate.latitude))-\(String(format: "%.5f", location.coordinate.longitude))"
    }

    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - rawName: 畫面顯示文字。
    /// - Returns: 格式化或查找後嘅文字。
    private func cleanStopName(_ rawName: String) -> String {
        let withoutBreaks = rawName.replacingOccurrences(of: "<br>", with: " ")
        let parts = withoutBreaks
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.last ?? withoutBreaks.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `CTBParsedCSVSnapshot` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
private struct CTBParsedCSVSnapshot: Codable {
    static let currentVersion = 1
    
    let version: Int
    let sourceFingerprint: String
    let stops: [StopInfo]
    let stopInfoById: [String: StopInfo]
    let directionsByStopId: [String: [CTBRouteDirection]]
    let companyCodeByRouteDirection: [String: String]
}

/// `CTBRouteDirection` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
private struct CTBRouteDirection: Codable, Hashable {
    let routeName: String
    let bound: BusDirection
    let sourceStopId: String
    let originName: String
    let destinationName: String
    let companyCode: String
}

/// `CTBCSVRouteRow` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
private struct CTBCSVRouteRow {
    let routeName: String
    let direction: BusDirection
    let stopSequence: Int
    let stopId: String
    let stopName: String
    let companyCode: String
}

/// `CTBRouteStopRow` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
private struct CTBRouteStopRow {
    let routeName: String
    let direction: BusDirection
    let stopSequence: Int
    let stopId: String
}

/// `CSVParser` 列出此功能範圍會用到嘅固定選項。
private enum CSVParser {
    /// 解析輸入內容並轉成程式可用資料。
    /// - Parameters:
    ///   - content: 此函式需要嘅輸入資料。
    /// - Returns: 格式化或查找後嘅文字。
    static func parse(_ content: String) -> [[String]] {
        let normalizedContent = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isInsideQuotes = false
        var iterator = normalizedContent.makeIterator()

        while let character = iterator.next() {
            switch character {
            case "\"":
                if isInsideQuotes {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append(next)
                        } else {
                            isInsideQuotes = false
                            handleNonQuote(next, row: &row, field: &field, rows: &rows)
                        }
                    } else {
                        isInsideQuotes = false
                    }
                } else {
                    isInsideQuotes = true
                }
            default:
                if isInsideQuotes {
                    field.append(character)
                } else {
                    handleNonQuote(character, row: &row, field: &field, rows: &rows)
                }
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - character: 此函式需要嘅輸入資料。
    ///   - row: 此函式需要嘅輸入資料。
    ///   - field: 此函式需要嘅輸入資料。
    ///   - rows: 要處理嘅資料集合。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private static func handleNonQuote(_ character: Character, row: inout [String], field: inout String, rows: inout [[String]]) {
        switch character {
        case ",":
            row.append(field)
            field = ""
        case "\n":
            row.append(field)
            rows.append(row)
            row = []
            field = ""
        case "\r":
            break
        default:
            field.append(character)
        }
    }
}

/// 擴充 `BusDirection`，加入此檔案負責嘅相關功能。
private extension BusDirection {
    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - routeSequence: 路線編號或路線模型。
    /// - Returns: 無回傳值；完成物件初始化。
    init?(routeSequence: String) {
        switch routeSequence.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1":
            self = .outbound
        case "2":
            self = .inbound
        default:
            return nil
        }
    }

    var apiRouteStopPathComponent: String {
        switch self {
        case .outbound:
            return "outbound"
        case .inbound:
            return "inbound"
        }
    }
}
