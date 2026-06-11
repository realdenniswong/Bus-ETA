/// 檔案用途：定義巴士公司、方向同 ETA provider 共用介面。
import CoreLocation
import Foundation

/// `BusOperator` 列出此功能範圍會用到嘅固定選項。
enum BusOperator: String, Codable, CaseIterable, Identifiable {
    case kmb = "KMB"
    case ctb = "CTB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kmb:
            return "九巴"
        case .ctb:
            return "城巴"
        }
    }
}

/// `BusDirection` 列出此功能範圍會用到嘅固定選項。
enum BusDirection: String, Codable, CaseIterable {
    case outbound
    case inbound

    var routeCode: String {
        switch self {
        case .outbound:
            return "O"
        case .inbound:
            return "I"
        }
    }

    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - routeCode: 路線編號或路線模型。
    /// - Returns: 無回傳值；完成物件初始化。
    init(routeCode: String) {
        self = routeCode.uppercased().hasPrefix("O") ? .outbound : .inbound
    }
}

/// `RouteStopLookupContext` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct RouteStopLookupContext {
    let userLocation: CLLocation
    let stopInfoById: [String: StopInfo]
}

/// `BusETAProvider` 定義此功能範圍需要遵守嘅介面。
protocol BusETAProvider {
    var operatorCode: BusOperator { get }

    /// 讀取可供搜尋同顯示嘅路線建議。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 已整理同排序嘅路線建議列表。
    func fetchRouteSuggestions() async throws -> [RouteSuggestion]

    /// 讀取 provider 可用嘅車站基本資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 已整理嘅車站資料列表。
    func fetchStops() async throws -> [StopInfo]

    /// 讀取指定車站目前服務緊嘅附近路線同 ETA。
    /// - Parameters:
    ///   - forStopId: 要查詢嘅車站識別碼。
    /// - Returns: 已整理嘅附近路線顯示資料列表。
    func fetchNearbyRoutes(forStopId stopId: String) async throws -> [NearbyRouteModel]

    /// 讀取指定路線方向嘅站序、站名同每站 ETA。
    /// - Parameters:
    ///   - route: 要查詢嘅路線編號。
    ///   - direction: 要查詢嘅行車方向。
    ///   - stopNameById: 以車站識別碼索引嘅站名對照表。
    /// - Returns: 已按站序整理嘅時間表顯示列。
    func fetchTimetableRows(route: String, direction: BusDirection, stopNameById: [String: String]) async throws -> [StopDisplayModel]

    /// 查找收藏路線最近用戶位置嘅上車站、距離同 ETA。
    /// - Parameters:
    ///   - for: 要更新狀態嘅收藏路線。
    ///   - context: 查找站點同位置所需嘅上下文資料。
    /// - Returns: 找到最近有效站點時回傳收藏狀態；否則為 nil。
    func fetchFavoriteStatus(for favorite: FavoriteRoute, context: RouteStopLookupContext) async throws -> FavoriteStatusModel?

    /// 讀取指定路線、方向同車站嘅倒數計時 ETA。
    /// - Parameters:
    ///   - route: 要查詢嘅路線編號。
    ///   - direction: 要查詢嘅行車方向。
    ///   - stopId: 要查詢嘅車站識別碼。
    /// - Returns: 已過濾同排序嘅 ETA 顯示資料列表。
    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String) async throws -> [ETADisplayInfo]

    /// 讀取指定路線、方向同每間營辦商車站識別碼嘅倒數計時 ETA。
    /// - Parameters:
    ///   - route: 要查詢嘅路線編號。
    ///   - direction: 要查詢嘅行車方向。
    ///   - stopId: 後備車站識別碼。
    ///   - operatorStopIds: 以營辦商代碼索引嘅車站識別碼。
    /// - Returns: 已過濾同排序嘅 ETA 顯示資料列表。
    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String, operatorStopIds: [String: String]) async throws -> [ETADisplayInfo]
}

extension BusETAProvider {
    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String, operatorStopIds: [String: String]) async throws -> [ETADisplayInfo] {
        try await fetchTimerETAs(route: route, direction: direction, stopId: operatorStopIds[operatorCode.rawValue] ?? stopId)
    }
}
