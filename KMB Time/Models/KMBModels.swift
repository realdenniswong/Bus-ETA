//
//  KMBModels.swift
//  KMB Time
//
//  Created by Dennis Wong on 6/4/26.
//

import Foundation
import CoreLocation

// MARK: - Data Models
struct StopResponse: Codable { let data: [StopInfo] }
struct StopInfo: Codable {
    let stop: String
    let name_tc: String
    let lat: String?
    let long: String?
}

extension StopInfo {
    var clLocation: CLLocation? {
        guard let latStr = lat, let longStr = long,
              let latitude = Double(latStr), let longitude = Double(longStr) else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
}

struct RouteStopResponse: Codable { let data: [RouteStop] }
struct RouteStop: Codable {
    let seq: String
    let stop: String
}

// 🌟 共用 ETA 模型 (九巴與城巴的 JSON 結構相容)
struct ETAResponse: Codable { let data: [ETAItem] }
struct ETAItem: Codable {
    let seq: Int
    let dir: String
    let eta: String?
    let rmk_tc: String?
}

struct ETADisplayInfo: Identifiable, Hashable {
    let id = UUID()
    let etaDate: Date?
    let remark: String?
}

struct StopDisplayModel: Identifiable {
    var id: String { "\(seq)-\(stopId)" }
    let seq: Int
    let stopId: String
    let stopNameTc: String
    let etas: [ETADisplayInfo]
    var location: CLLocation? = nil // 🌟 新增：用於城巴計算最近車站
}

struct NearbyStopModel: Identifiable {
    let id = UUID()
    let stopInfo: StopInfo
    let distance: CLLocationDistance
    var routes: [NearbyRouteModel] = []
}

struct NearbyRouteModel: Identifiable {
    let id = UUID()
    let route: String
    let directionCode: String // "O" or "I"
    let destNameTc: String
    let etas: [ETADisplayInfo]
}

struct StopETAResponse: Codable {
    let data: [StopETAItem]
}

struct StopETAItem: Codable {
    let co: String
    let route: String
    let dir: String
    let service_type: Int
    let dest_tc: String
    let eta_seq: Int
    let eta: String?
    let rmk_tc: String?
}

// MARK: - Route Suggestion Models
struct AllRoutesResponse: Codable { let data: [RouteItem] }
struct RouteItem: Codable {
    let route: String
    let bound: String    // "O" (Outbound) or "I" (Inbound)
    let orig_tc: String  // Origin Station
    let dest_tc: String  // Destination Station
}

struct RouteSuggestion: Hashable {
    let co: String       // 🌟 新增："KMB" 或 "CTB"
    let route: String
    let bound: String
    let origin: String
    let destination: String
}

// MARK: - Active Timer Model
struct ActiveTimerModel: Identifiable, Equatable {
    let id = UUID()
    let routeName: String
    let destination: String
    var etaDate: Date
    var targetAlertDate: Date
    let startTime: Date
    let stopId: String
    let direction: String
    let stationName: String
}

// MARK: - 城巴 (CTB) 專用 Models 🌟
struct CTBRouteResponse: Codable { let data: [CTBRouteItem] }
struct CTBRouteItem: Codable {
    let route: String
    let orig_tc: String
    let dest_tc: String
}

struct CTBRouteStopResponse: Codable { let data: [CTBRouteStop] }
struct CTBRouteStop: Codable {
    let seq: Int
    let stop: String
}

struct CTBStopResponse: Codable { let data: StopInfo }
