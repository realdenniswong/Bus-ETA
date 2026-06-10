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
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func fetchRouteSuggestions() async throws -> [RouteSuggestion]
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func fetchStops() async throws -> [StopInfo]
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - forStopId: 車站識別或車站資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func fetchNearbyRoutes(forStopId stopId: String) async throws -> [NearbyRouteModel]
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - stopNameById: 車站識別或車站資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func fetchTimetableRows(route: String, direction: BusDirection, stopNameById: [String: String]) async throws -> [StopDisplayModel]
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    ///   - context: 查找站點同位置所需嘅上下文資料。
    /// - Returns: 找到時回傳對應資料；沒有時為 nil。
    func fetchFavoriteStatus(for favorite: FavoriteRoute, context: RouteStopLookupContext) async throws -> FavoriteStatusModel?
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - stopId: 車站識別或車站資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String) async throws -> [ETADisplayInfo]
}
