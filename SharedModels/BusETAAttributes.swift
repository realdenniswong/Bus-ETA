import ActivityKit
import Foundation

struct BusETAAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var etaDate: Date
        var remainingSeconds: Int
    }

    var routeName: String
    var destination: String
    var stationName: String // <--- ADD THIS LINE
    var startTime: Date
}
