/// 檔案用途：集中定義 API 回應、畫面顯示模型、收藏狀態同計時器模型。

import CoreLocation
import Foundation

// MARK: - 供應方回應資料物件

/// `StopResponse` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct StopResponse: Codable {
    let data: [StopInfo]
}

/// `RouteStopResponse` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct RouteStopResponse: Codable {
    let data: [RouteStop]
}

/// `KMBRoutesResponse` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct KMBRoutesResponse: Codable {
    let data: [RouteItem]
}

/// `StopETAResponse` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct StopETAResponse: Codable {
    let data: [StopETAItem]
}

/// `RouteItem` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct RouteItem: Codable {
    let route: String
    let bound: String
    let orig_tc: String
    let dest_tc: String
}

/// `RouteStop` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct RouteStop: Codable {
    let seq: String
    let stop: String
}

/// `StopETAItem` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct StopETAItem: Codable {
    let co: String
    let route: String
    let dir: String
    let service_type: Int
    let dest_tc: String
    let eta_seq: Int
    let eta: String?
    let rmk_tc: String?
    let stop: String?
    let seq: Int?
}

// MARK: - 應用程式顯示模型

/// `StopInfo` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct StopInfo: Codable {
    let stop: String
    let name_tc: String
    let lat: String?
    let long: String?
    let operatorCode: BusOperator?

    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - stop: 車站識別或車站資料。
    ///   - name_tc: 畫面顯示文字。
    ///   - lat: 此函式需要嘅輸入資料。
    ///   - long: 此函式需要嘅輸入資料。
    ///   - operatorCode: 巴士公司代碼。
    /// - Returns: 無回傳值；完成物件初始化。
    init(stop: String, name_tc: String, lat: String?, long: String?, operatorCode: BusOperator? = nil) {
        self.stop = stop
        self.name_tc = name_tc
        self.lat = lat
        self.long = long
        self.operatorCode = operatorCode
    }

    /// `CodingKeys` 列出此功能範圍會用到嘅固定選項。
    private enum CodingKeys: String, CodingKey {
        case stop
        case name_tc
        case lat
        case long
        case operatorCode
    }

    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - from: 此函式需要嘅輸入資料。
    /// - Returns: 無回傳值；完成物件初始化。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stop = try container.decode(String.self, forKey: .stop)
        name_tc = try container.decode(String.self, forKey: .name_tc)
        lat = try container.decodeIfPresent(String.self, forKey: .lat)
        long = try container.decodeIfPresent(String.self, forKey: .long)
        operatorCode = try container.decodeIfPresent(BusOperator.self, forKey: .operatorCode)
    }
}

/// 擴充 `StopInfo`，加入此檔案負責嘅相關功能。
extension StopInfo {
    var identityKey: String {
        "\(operatorCode?.rawValue ?? "UNKNOWN")-\(stop)"
    }

    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - with: 此函式需要嘅輸入資料。
    /// - Returns: 計算後嘅 `StopInfo`。
    func tagged(with operatorCode: BusOperator) -> StopInfo {
        StopInfo(stop: stop, name_tc: name_tc, lat: lat, long: long, operatorCode: operatorCode)
    }

    /// 由 provider 緯度同經度文字解析出嚟嘅站點位置。
    var clLocation: CLLocation? {
        guard let lat, let long,
              let latitude = Double(lat),
              let longitude = Double(long) else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
}

/// `ETADisplayInfo` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct ETADisplayInfo: Identifiable, Hashable {
    let id = UUID()
    let etaDate: Date?
    let remark: String?
    var companyCode: String = "KMB"
}

/// `StopDisplayModel` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct StopDisplayModel: Identifiable {
    var id: String { "\(seq)-\(stopId)" }
    let seq: Int
    let stopId: String
    let stopNameTc: String
    let etas: [ETADisplayInfo]
    var location: CLLocation? = nil
    var operatorStopIds: [String: String] = [:]
}

/// `NearbyStopModel` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct NearbyStopModel: Identifiable {
    let id = UUID()
    let stopInfo: StopInfo
    let distance: CLLocationDistance
    var routes: [NearbyRouteModel] = []
    var hasFetchedRoutes = false
}

/// `NearbyRouteModel` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct NearbyRouteModel: Identifiable {
    let id = UUID()
    let co: String
    let route: String
    let directionCode: String
    let destNameTc: String
    var displayStopName: String? = nil
    var displayStopId: String? = nil
    let etas: [ETADisplayInfo]
    var detailDirectionCode: String? = nil
    var operatorStopIds: [String: String] = [:]
}

/// `RouteSuggestion` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct RouteSuggestion: Codable, Hashable, Identifiable {
    let id = UUID()
    let co: String
    let route: String
    let bound: String
    let origin: String
    let destination: String

    /// `CodingKeys` 列出此功能範圍會用到嘅固定選項。
    private enum CodingKeys: String, CodingKey {
        case co
        case route
        case bound
        case origin
        case destination
    }
}

/// `ActiveTimerModel` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct ActiveTimerModel: Identifiable, Equatable {
    let id = UUID()
    let routeName: String
    let company: String
    let destination: String
    var etaDate: Date
    var targetAlertDate: Date
    let startTime: Date
    let stopId: String
    let direction: String
    let stationName: String
    let operatorStopIds: [String: String]
}

/// `FavoriteStatusModel` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct FavoriteStatusModel: Equatable {
    let etas: [ETADisplayInfo]
    let distance: CLLocationDistance
    let stopName: String
    let stopId: String
    let operatorStopIds: [String: String]

    init(etas: [ETADisplayInfo], distance: CLLocationDistance, stopName: String, stopId: String = "", operatorStopIds: [String: String] = [:]) {
        self.etas = etas
        self.distance = distance
        self.stopName = stopName
        self.stopId = stopId
        self.operatorStopIds = operatorStopIds
    }

    static func == (lhs: FavoriteStatusModel, rhs: FavoriteStatusModel) -> Bool {
        lhs.distance == rhs.distance &&
        lhs.stopName == rhs.stopName &&
        lhs.stopId == rhs.stopId &&
        lhs.operatorStopIds == rhs.operatorStopIds &&
        lhs.etas.first?.etaDate == rhs.etas.first?.etaDate
    }
}
