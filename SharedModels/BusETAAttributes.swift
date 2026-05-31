import ActivityKit
import SwiftUI

struct BusETAAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about the bus progress
        var etaDate: Date
        var remainingSeconds: Int
    }

    // Fixed non-changing properties about the bus route
    var routeName: String
    var destination: String
    var startTime: Date
}
