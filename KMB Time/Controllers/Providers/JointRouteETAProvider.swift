import CoreLocation
import Foundation

/// Coordinates KMB and CTB ETA providers for joint KMB+CTB routes.
///
/// Joint route rows keep KMB stop context for navigation and reminders, while ETA lists include
/// both KMB and CTB arrivals when a matching CTB row can be resolved.
struct JointRouteETAProvider: BusETAProvider {
    static let shared = JointRouteETAProvider()
    
    let operatorCode: BusOperator = .kmb
    
    private let kmbProvider = KMBETAProvider.shared
    private let ctbProvider = CTBETAProvider.shared
    
    private init() { }
    
    func fetchRouteSuggestions() async throws -> [RouteSuggestion] {
        try await ctbProvider.fetchRouteSuggestions().filter { $0.co == "KMB+CTB" }
    }
    
    func fetchStops() async throws -> [StopInfo] {
        async let kmbStops = kmbProvider.fetchStops()
        async let ctbStops = ctbProvider.fetchStops()
        return try await kmbStops + ctbStops
    }
    
    func fetchNearbyRoutes(forStopId stopId: String) async throws -> [NearbyRouteModel] {
        async let kmbRoutes = kmbProvider.fetchNearbyRoutes(forStopId: stopId)
        async let ctbRoutes = ctbProvider.fetchNearbyRoutes(forStopId: stopId)
        return try await mergedNearbyRoutes(kmbRoutes: kmbRoutes, ctbRoutes: ctbRoutes)
    }
    
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
    
    func fetchTimetableRows(route: String, direction: BusDirection, stopNameById: [String: String]) async throws -> [StopDisplayModel] {
        async let kmbRows = kmbProvider.fetchTimetableRows(route: route, direction: direction, stopNameById: stopNameById)
        async let ctbRows = ctbProvider.fetchTimetableRows(route: route, direction: direction, stopNameById: stopNameById)
        return try await mergedTimetableRows(kmbRows: kmbRows, ctbRows: ctbRows)
    }
    
    func fetchFavoriteStatus(for favorite: FavoriteRoute, context: RouteStopLookupContext) async throws -> FavoriteStatusModel? {
        async let kmbStatus = try? kmbProvider.fetchFavoriteStatus(for: favorite, context: context)
        async let ctbStatus = try? ctbProvider.fetchFavoriteStatus(for: favorite, context: context)
        return await mergedFavoriteStatus(kmbStatus: kmbStatus, ctbStatus: ctbStatus)
    }
    
    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String) async throws -> [ETADisplayInfo] {
        async let kmbETAs = (try? kmbProvider.fetchTimerETAs(route: route, direction: direction, stopId: stopId)) ?? []
        async let ctbETAs = (try? ctbProvider.fetchTimerETAs(route: route, direction: direction, stopId: stopId)) ?? []
        return await sortedETAs(kmbETAs + ctbETAs)
    }
}

private extension JointRouteETAProvider {
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
    
    func jointRoute(kmbRoute: NearbyRouteModel, ctbRoute: NearbyRouteModel?) -> NearbyRouteModel {
        NearbyRouteModel(
            co: "KMB+CTB",
            route: kmbRoute.route,
            directionCode: kmbRoute.directionCode,
            destNameTc: kmbRoute.destNameTc,
            displayStopName: kmbRoute.displayStopName,
            displayStopId: kmbRoute.displayStopId,
            etas: Array(sortedETAs(kmbRoute.etas + (ctbRoute?.etas ?? [])).prefix(3)),
            detailDirectionCode: kmbRoute.detailDirectionCode ?? kmbRoute.directionCode
        )
    }
    
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
                location: kmbRow.location
            )
        }
        .sorted { $0.seq < $1.seq }
    }
    
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
    
    func mergedFavoriteStatus(kmbStatus: FavoriteStatusModel?, ctbStatus: FavoriteStatusModel?) -> FavoriteStatusModel? {
        guard let baseStatus = kmbStatus ?? ctbStatus else { return nil }
        let etas = sortedETAs((kmbStatus?.etas ?? []) + (ctbStatus?.etas ?? []))
        let distance = min(kmbStatus?.distance ?? .infinity, ctbStatus?.distance ?? .infinity)
        return FavoriteStatusModel(
            etas: Array(etas.prefix(3)),
            distance: distance,
            stopName: kmbStatus?.stopName ?? baseStatus.stopName
        )
    }
    
    func sortedETAs(_ etas: [ETADisplayInfo]) -> [ETADisplayInfo] {
        etas.sorted { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
    }
    
    nonisolated static func location(from stopInfo: StopInfo) -> CLLocation? {
        guard let latitudeText = stopInfo.lat,
              let longitudeText = stopInfo.long,
              let latitude = Double(latitudeText),
              let longitude = Double(longitudeText) else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
    
    func normalizedStopName(_ stopName: String) -> String {
        stopName.replacingOccurrences(
            of: "\\s*\\([^)]+\\)\\s*$",
            with: "",
            options: .regularExpression
        )
    }
}
