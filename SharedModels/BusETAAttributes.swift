/// 檔案用途：定義即時活動共享屬性，供 app 同 widget extension 使用。
import ActivityKit
import Foundation

/// `BusETAAttributes` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
nonisolated struct BusETAAttributes: ActivityAttributes {
    /// `ContentState` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
    public struct ContentState: Codable, Hashable {
        var etaDate: Date
        var remainingSeconds: Int
    }

    var routeName: String
    var company: String
    var destination: String
    var stationName: String
    var startTime: Date
    var stopId: String
    var direction: String
    var operatorStopIds: [String: String]

    init(routeName: String, company: String, destination: String, stationName: String, startTime: Date, stopId: String = "", direction: String = "", operatorStopIds: [String: String] = [:]) {
        self.routeName = routeName
        self.company = company
        self.destination = destination
        self.stationName = stationName
        self.startTime = startTime
        self.stopId = stopId
        self.direction = direction
        self.operatorStopIds = operatorStopIds
    }

    private enum CodingKeys: String, CodingKey {
        case routeName
        case company
        case destination
        case stationName
        case startTime
        case stopId
        case direction
        case operatorStopIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        routeName = try container.decode(String.self, forKey: .routeName)
        company = try container.decode(String.self, forKey: .company)
        destination = try container.decode(String.self, forKey: .destination)
        stationName = try container.decode(String.self, forKey: .stationName)
        startTime = try container.decode(Date.self, forKey: .startTime)
        stopId = try container.decodeIfPresent(String.self, forKey: .stopId) ?? ""
        direction = try container.decodeIfPresent(String.self, forKey: .direction) ?? ""
        operatorStopIds = try container.decodeIfPresent([String: String].self, forKey: .operatorStopIds) ?? [:]
    }
}
