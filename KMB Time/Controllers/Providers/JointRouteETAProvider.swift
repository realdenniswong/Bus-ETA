/// 檔案用途：合併 KMB 同 CTB 聯營路線資料，提供統一顯示模型。
import CoreLocation
import Foundation

/// `JointRouteETAProvider` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct JointRouteETAProvider: BusETAProvider {
    static let shared = JointRouteETAProvider()
    
    let operatorCode: BusOperator = .kmb
    
    private let kmbProvider = KMBETAProvider.shared
    private let ctbProvider = CTBETAProvider.shared
    
    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；完成物件初始化。
    private init() { }
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func fetchRouteSuggestions() async throws -> [RouteSuggestion] {
        try await ctbProvider.fetchRouteSuggestions().filter { $0.co == "KMB+CTB" }
    }
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func fetchStops() async throws -> [StopInfo] {
        async let kmbStops = kmbProvider.fetchStops()
        async let ctbStops = ctbProvider.fetchStops()
        return try await kmbStops + ctbStops
    }
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - forStopId: 車站識別或車站資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func fetchNearbyRoutes(forStopId stopId: String) async throws -> [NearbyRouteModel] {
        async let kmbRoutes = kmbProvider.fetchNearbyRoutes(forStopId: stopId)
        async let ctbRoutes = ctbProvider.fetchNearbyRoutes(forStopId: stopId)
        return try await mergedNearbyRoutes(kmbRoutes: kmbRoutes, ctbRoutes: ctbRoutes)
    }
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func fetchNearbyRoutes(for stopInfo: StopInfo) async throws -> [NearbyRouteModel] {
        async let kmbRoutes = kmbProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)
        async let ctbRoutes: [NearbyRouteModel] = {
            if let stopLocation = Self.location(from: stopInfo) {
                return try await ctbProvider.fetchNearbyRoutes(near: stopLocation)
            }
            return try await ctbProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)
        }()
        return try await mergedNearbyRoutes(kmbRoutes: kmbRoutes, ctbRoutes: ctbRoutes)
    }
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - stopNameById: 車站識別或車站資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func fetchTimetableRows(route: String, direction: BusDirection, stopNameById: [String: String]) async throws -> [StopDisplayModel] {
        async let kmbRows = kmbProvider.fetchTimetableRows(route: route, direction: direction, stopNameById: stopNameById)
        async let ctbRows = ctbProvider.fetchTimetableRows(route: route, direction: direction, stopNameById: stopNameById)
        return try await mergedTimetableRows(kmbRows: kmbRows, ctbRows: ctbRows)
    }
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    ///   - context: 查找站點同位置所需嘅上下文資料。
    /// - Returns: 找到時回傳對應資料；沒有時為 nil。
    func fetchFavoriteStatus(for favorite: FavoriteRoute, context: RouteStopLookupContext) async throws -> FavoriteStatusModel? {
        async let kmbStatus = try? kmbProvider.fetchFavoriteStatus(for: favorite, context: context)
        async let ctbStatus = try? ctbProvider.fetchFavoriteStatus(for: favorite, context: context)
        return await mergedFavoriteStatus(kmbStatus: kmbStatus, ctbStatus: ctbStatus)
    }
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - stopId: 車站識別或車站資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String) async throws -> [ETADisplayInfo] {
        async let kmbETAs = (try? kmbProvider.fetchTimerETAs(route: route, direction: direction, stopId: stopId)) ?? []
        async let ctbETAs = (try? ctbProvider.fetchTimerETAs(route: route, direction: direction, stopId: stopId)) ?? []
        return await sortedETAs(kmbETAs + ctbETAs)
    }
}

/// 擴充 `JointRouteETAProvider`，加入此檔案負責嘅相關功能。
private extension JointRouteETAProvider {
    /// 合併多個資料來源並回傳統一結果。
    /// - Parameters:
    ///   - kmbRoutes: 路線編號或路線模型。
    ///   - ctbRoutes: 路線編號或路線模型。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func mergedNearbyRoutes(kmbRoutes: [NearbyRouteModel], ctbRoutes: [NearbyRouteModel]) -> [NearbyRouteModel] {
        kmbRoutes.compactMap { kmbRoute in
            let direction = BusDirection(routeCode: kmbRoute.directionCode)
            guard ctbProvider.isJointRoute(route: kmbRoute.route, direction: direction) else {
                return nil
            }
            let matchedCTBRoute = matchingCTBRoute(for: kmbRoute, in: ctbRoutes)
            return jointRoute(kmbRoute: kmbRoute, ctbRoute: matchedCTBRoute)
        }
        .sorted {
            if $0.route == $1.route { return $0.directionCode < $1.directionCode }
            return $0.route.localizedStandardCompare($1.route) == .orderedAscending
        }
    }
    
    /// 整理或查找路線相關資料。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    ///   - in: 此函式需要嘅輸入資料。
    /// - Returns: 找到時回傳對應資料；沒有時為 nil。
    func matchingCTBRoute(for kmbRoute: NearbyRouteModel, in ctbRoutes: [NearbyRouteModel]) -> NearbyRouteModel? {
        ctbRoutes.first { candidate in
            candidate.co == "KMB+CTB" &&
            candidate.route.uppercased() == kmbRoute.route.uppercased() &&
            normalizedStopName(candidate.destNameTc) == normalizedStopName(kmbRoute.destNameTc)
        } ?? ctbRoutes.first { candidate in
            candidate.co == "KMB+CTB" &&
            candidate.route.uppercased() == kmbRoute.route.uppercased() &&
            candidate.directionCode == kmbRoute.directionCode
        }
    }
    
    /// 整理或查找路線相關資料。
    /// - Parameters:
    ///   - kmbRoute: 路線編號或路線模型。
    ///   - ctbRoute: 路線編號或路線模型。
    /// - Returns: 計算後嘅 `NearbyRouteModel`。
    func jointRoute(kmbRoute: NearbyRouteModel, ctbRoute: NearbyRouteModel?) -> NearbyRouteModel {
        NearbyRouteModel(
            co: "KMB+CTB",
            route: kmbRoute.route,
            directionCode: kmbRoute.directionCode,
            destNameTc: kmbRoute.destNameTc,
            displayStopName: kmbRoute.displayStopName,
            displayStopId: kmbRoute.displayStopId,
            etas: Array(sortedETAs(kmbRoute.etas + (ctbRoute?.etas ?? [])).prefix(3)),
            detailDirectionCode: kmbRoute.detailDirectionCode ?? kmbRoute.directionCode
        )
    }
    
    /// 合併多個資料來源並回傳統一結果。
    /// - Parameters:
    ///   - kmbRows: 要處理嘅資料集合。
    ///   - ctbRows: 要處理嘅資料集合。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func mergedTimetableRows(kmbRows: [StopDisplayModel], ctbRows: [StopDisplayModel]) -> [StopDisplayModel] {
        let ctbRowsByName = Dictionary(grouping: ctbRows) { normalizedStopName($0.stopNameTc) }
        let ctbRowsBySequence = Dictionary(grouping: ctbRows) { $0.seq }
        return kmbRows.map { kmbRow in
            let matchedCTBRow = ctbRowsByName[normalizedStopName(kmbRow.stopNameTc)]?.first
                ?? nearestCTBRow(to: kmbRow.location, from: ctbRows)
                ?? ctbRowsBySequence[kmbRow.seq]?.first
            guard let matchedCTBRow else { return kmbRow }
            return StopDisplayModel(
                seq: kmbRow.seq,
                stopId: kmbRow.stopId,
                stopNameTc: kmbRow.stopNameTc,
                etas: Array(sortedETAs(kmbRow.etas + matchedCTBRow.etas).prefix(3)),
                location: kmbRow.location
            )
        }
        .sorted { $0.seq < $1.seq }
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - to: 此函式需要嘅輸入資料。
    ///   - from: 此函式需要嘅輸入資料。
    /// - Returns: 找到時回傳對應資料；沒有時為 nil。
    func nearestCTBRow(to location: CLLocation?, from rows: [StopDisplayModel]) -> StopDisplayModel? {
        guard let location else { return nil }
        let candidate = rows.min { first, second in
            let firstDistance = first.location.map { location.distance(from: $0) } ?? .infinity
            let secondDistance = second.location.map { location.distance(from: $0) } ?? .infinity
            return firstDistance < secondDistance
        }
        guard let candidate, let candidateLocation = candidate.location, location.distance(from: candidateLocation) <= 100 else {
            return nil
        }
        return candidate
    }
    
    /// 合併多個資料來源並回傳統一結果。
    /// - Parameters:
    ///   - kmbStatus: 此函式需要嘅輸入資料。
    ///   - ctbStatus: 此函式需要嘅輸入資料。
    /// - Returns: 找到時回傳對應資料；沒有時為 nil。
    func mergedFavoriteStatus(kmbStatus: FavoriteStatusModel?, ctbStatus: FavoriteStatusModel?) -> FavoriteStatusModel? {
        guard let baseStatus = kmbStatus ?? ctbStatus else { return nil }
        let etas = sortedETAs((kmbStatus?.etas ?? []) + (ctbStatus?.etas ?? []))
        let distance = min(kmbStatus?.distance ?? .infinity, ctbStatus?.distance ?? .infinity)
        return FavoriteStatusModel(
            etas: Array(etas.prefix(3)),
            distance: distance,
            stopName: kmbStatus?.stopName ?? baseStatus.stopName
        )
    }
    
    /// 按畫面需要排序並回傳結果。
    /// - Parameters:
    ///   - etas: 時間或到站時間資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func sortedETAs(_ etas: [ETADisplayInfo]) -> [ETADisplayInfo] {
        etas.sorted { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - from: 此函式需要嘅輸入資料。
    /// - Returns: 可用嘅位置資料；沒有時為 nil。
    nonisolated static func location(from stopInfo: StopInfo) -> CLLocation? {
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
    ///   - stopName: 車站識別或車站資料。
    /// - Returns: 格式化或查找後嘅文字。
    func normalizedStopName(_ stopName: String) -> String {
        stopName.replacingOccurrences(
            of: "\\s*\\([^)]+\\)\\s*$",
            with: "",
            options: .regularExpression
        )
    }
}
