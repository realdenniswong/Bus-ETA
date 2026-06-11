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

    /// 讀取只屬於 KMB+CTB 聯營嘅路線建議。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 已整理同排序嘅聯營路線建議列表。
    func fetchRouteSuggestions() async throws -> [RouteSuggestion] {
        try await ctbProvider.fetchRouteSuggestions().filter { $0.co == "KMB+CTB" }
    }

    /// 同時讀取 KMB 同 CTB 車站資料並合併。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 兩間公司合併後嘅車站資料列表。
    func fetchStops() async throws -> [StopInfo] {
        async let kmbStops = kmbProvider.fetchStops()
        async let ctbStops = ctbProvider.fetchStops()
        return try await kmbStops + ctbStops
    }

    /// 讀取指定車站嘅 KMB 同 CTB 附近路線，再合併成聯營路線顯示資料。
    /// - Parameters:
    ///   - forStopId: 要查詢嘅車站識別碼。
    /// - Returns: 已合併同排序嘅聯營附近路線列表。
    func fetchNearbyRoutes(forStopId stopId: String) async throws -> [NearbyRouteModel] {
        async let kmbRoutes = kmbProvider.fetchNearbyRoutes(forStopId: stopId)
        async let ctbRoutes = ctbProvider.fetchNearbyRoutes(forStopId: stopId)
        return try await mergedNearbyRoutes(kmbRoutes: kmbRoutes, ctbRoutes: ctbRoutes)
    }

    /// 用車站座標輔助讀取 KMB 同 CTB 附近路線，再合併成聯營路線顯示資料。
    /// - Parameters:
    ///   - for: 作為查詢基準嘅車站資料。
    /// - Returns: 已合併同排序嘅聯營附近路線列表。
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

    /// 讀取並合併 KMB 同 CTB 同一路線方向嘅站序同 ETA。
    /// - Parameters:
    ///   - route: 要查詢嘅路線編號。
    ///   - direction: 要查詢嘅行車方向。
    ///   - stopNameById: 以車站識別碼索引嘅站名對照表。
    /// - Returns: 已按站序合併嘅時間表顯示列。
    func fetchTimetableRows(route: String, direction: BusDirection, stopNameById: [String: String]) async throws -> [StopDisplayModel] {
        async let kmbRows = kmbProvider.fetchTimetableRows(route: route, direction: direction, stopNameById: stopNameById)
        async let ctbRows = ctbProvider.fetchTimetableRows(route: route, direction: direction, stopNameById: stopNameById)
        return try await mergedTimetableRows(kmbRows: kmbRows, ctbRows: ctbRows)
    }

    /// 同時查找 KMB 同 CTB 收藏狀態，並合併最近站點距離同 ETA。
    /// - Parameters:
    ///   - for: 要更新狀態嘅收藏路線。
    ///   - context: 查找站點同位置所需嘅上下文資料。
    /// - Returns: 找到有效站點時回傳合併後收藏狀態；否則為 nil。
    func fetchFavoriteStatus(for favorite: FavoriteRoute, context: RouteStopLookupContext) async throws -> FavoriteStatusModel? {
        async let kmbStatus = try? kmbProvider.fetchFavoriteStatus(for: favorite, context: context)
        async let ctbStatus = try? ctbProvider.fetchFavoriteStatus(for: favorite, context: context)
        return await mergedFavoriteStatus(kmbStatus: kmbStatus, ctbStatus: ctbStatus)
    }

    /// 同時讀取 KMB 同 CTB 指定站點嘅倒數計時 ETA，再合併排序。
    /// - Parameters:
    ///   - route: 要查詢嘅路線編號。
    ///   - direction: 要查詢嘅行車方向。
    ///   - stopId: 要查詢嘅車站識別碼。
    /// - Returns: 已合併、過濾同排序嘅 ETA 顯示資料列表。
    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String) async throws -> [ETADisplayInfo] {
        try await fetchTimerETAs(route: route, direction: direction, stopId: stopId, operatorStopIds: [:])
    }

    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String, operatorStopIds: [String: String]) async throws -> [ETADisplayInfo] {
        let kmbStopId = operatorStopIds[BusOperator.kmb.rawValue] ?? stopId
        let ctbStopId = operatorStopIds[BusOperator.ctb.rawValue] ?? stopId
        async let kmbETAs = (try? kmbProvider.fetchTimerETAs(route: route, direction: direction, stopId: kmbStopId)) ?? []
        async let ctbETAs = (try? ctbProvider.fetchTimerETAs(route: route, direction: direction, stopId: ctbStopId)) ?? []
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
            detailDirectionCode: kmbRoute.detailDirectionCode ?? kmbRoute.directionCode,
            operatorStopIds: mergedStopIds(kmbRoute.operatorStopIds, ctbRoute?.operatorStopIds ?? [:])
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
                location: kmbRow.location,
                operatorStopIds: mergedStopIds(kmbRow.operatorStopIds, matchedCTBRow.operatorStopIds)
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
            stopName: kmbStatus?.stopName ?? baseStatus.stopName,
            stopId: kmbStatus?.stopId ?? baseStatus.stopId,
            operatorStopIds: mergedStopIds(kmbStatus?.operatorStopIds ?? [:], ctbStatus?.operatorStopIds ?? [:])
        )
    }

    /// 合併每間營辦商對應嘅車站識別碼，右方資料會補齊或覆蓋左方同名 key。
    /// - Parameters:
    ///   - lhs: 第一份營辦商車站 key。
    ///   - rhs: 第二份營辦商車站 key。
    /// - Returns: 合併後嘅營辦商車站 key。
    func mergedStopIds(_ lhs: [String: String], _ rhs: [String: String]) -> [String: String] {
        lhs.merging(rhs) { _, new in new }
    }

    /// 按畫面需要排序並回傳結果。
    /// - Parameters:
    ///   - etas: 時間或到站時間資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func sortedETAs(_ etas: [ETADisplayInfo]) -> [ETADisplayInfo] {
        let staleETAThreshold = Date().addingTimeInterval(-60)
        return etas
            .filter { ($0.etaDate ?? Date.distantPast) >= staleETAThreshold }
            .sorted { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
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
