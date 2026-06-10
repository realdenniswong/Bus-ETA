//
//  KMBModels.swift
//  KMB Time
//
//  Created by Dennis Wong on 6/4/26.
//

import CoreLocation
import Foundation

// MARK: - Provider Response DTOs

/// Generic stop-list response shape used by the current KMB provider.
struct StopResponse: Codable {
    let data: [StopInfo]
}

/// Generic route-stop response shape used by the current KMB provider.
struct RouteStopResponse: Codable {
    let data: [RouteStop]
}

/// KMB route-list response.
struct KMBRoutesResponse: Codable {
    let data: [RouteItem]
}

/// KMB stop ETA response.
struct StopETAResponse: Codable {
    let data: [StopETAItem]
}

/// KMB route direction DTO.
struct RouteItem: Codable {
    let route: String
    let bound: String
    let orig_tc: String
    let dest_tc: String
}

/// KMB route-stop DTO.
struct RouteStop: Codable {
    let seq: String
    let stop: String
}

/// KMB stop ETA DTO.
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
}

// MARK: - App Display Models

/// Stop model used by provider caches, nearby dashboard, and route matching.
struct StopInfo: Codable {
    let stop: String
    let name_tc: String
    let lat: String?
    let long: String?
    let operatorCode: BusOperator?
    
    init(stop: String, name_tc: String, lat: String?, long: String?, operatorCode: BusOperator? = nil) {
        self.stop = stop
        self.name_tc = name_tc
        self.lat = lat
        self.long = long
        self.operatorCode = operatorCode
    }
    
    private enum CodingKeys: String, CodingKey {
        case stop
        case name_tc
        case lat
        case long
        case operatorCode
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stop = try container.decode(String.self, forKey: .stop)
        name_tc = try container.decode(String.self, forKey: .name_tc)
        lat = try container.decodeIfPresent(String.self, forKey: .lat)
        long = try container.decodeIfPresent(String.self, forKey: .long)
        operatorCode = try container.decodeIfPresent(BusOperator.self, forKey: .operatorCode)
    }
}

extension StopInfo {
    var identityKey: String {
        "\(operatorCode?.rawValue ?? "UNKNOWN")-\(stop)"
    }
    
    func tagged(with operatorCode: BusOperator) -> StopInfo {
        StopInfo(stop: stop, name_tc: name_tc, lat: lat, long: long, operatorCode: operatorCode)
    }
    
    /// Stop location parsed from provider latitude/longitude strings.
    var clLocation: CLLocation? {
        guard let lat, let long,
              let latitude = Double(lat),
              let longitude = Double(long) else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
}

/// One ETA value prepared for SwiftUI display.
struct ETADisplayInfo: Identifiable, Hashable {
    let id = UUID()
    let etaDate: Date?
    let remark: String?
    var companyCode: String = "KMB"
}

/// One stop row in the route-detail timetable.
struct StopDisplayModel: Identifiable {
    var id: String { "\(seq)-\(stopId)" }
    let seq: Int
    let stopId: String
    let stopNameTc: String
    let etas: [ETADisplayInfo]
    var location: CLLocation? = nil
}

/// One nearby stop row with the routes currently serving it.
struct NearbyStopModel: Identifiable {
    let id = UUID()
    let stopInfo: StopInfo
    let distance: CLLocationDistance
    var routes: [NearbyRouteModel] = []
    var hasFetchedRoutes = false
}

/// One route card shown in the nearby dashboard.
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
}

/// One route direction shown in search suggestions.
struct RouteSuggestion: Codable, Hashable, Identifiable {
    let id = UUID()
    let co: String
    let route: String
    let bound: String
    let origin: String
    let destination: String
    
    private enum CodingKeys: String, CodingKey {
        case co
        case route
        case bound
        case origin
        case destination
    }
}

/// Active timer state mirrored into local notifications and Live Activity.
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
}

/// Favourites-tab live status for one saved route.
struct FavoriteStatusModel: Equatable {
    let etas: [ETADisplayInfo]
    let distance: CLLocationDistance
    let stopName: String
    
    static func == (lhs: FavoriteStatusModel, rhs: FavoriteStatusModel) -> Bool {
        lhs.distance == rhs.distance &&
        lhs.stopName == rhs.stopName &&
        lhs.etas.first?.etaDate == rhs.etas.first?.etaDate
    }
}
