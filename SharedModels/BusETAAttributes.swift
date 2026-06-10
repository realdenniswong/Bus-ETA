/// 檔案用途：定義即時活動共享屬性，供 app 同 widget extension 使用。
import ActivityKit
import Foundation

/// `BusETAAttributes` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct BusETAAttributes: ActivityAttributes {
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
}
