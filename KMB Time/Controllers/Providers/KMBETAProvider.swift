import CoreLocation
import Foundation

/// KMB implementation of `BusETAProvider`.
///
/// This file is the only place that should know KMB endpoint paths and KMB response filtering rules.
struct KMBETAProvider: BusETAProvider {
    static let shared = KMBETAProvider()
    
    let operatorCode: BusOperator = .kmb
    
    private let baseURL = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/")!
    private let jsonDecoder = JSONDecoder()
    
    private init() { }
    
    /// Fetches all KMB route directions and maps them into search suggestions.
    func fetchRouteSuggestions() async throws -> [RouteSuggestion] {
        let response: KMBRoutesResponse = try await fetch(path: "route/")
        return response.data
            .map { route in
                RouteSuggestion(
                    co: operatorCode.rawValue,
                    route: route.route,
                    bound: route.bound,
                    origin: route.orig_tc,
                    destination: route.dest_tc
                )
            }
            .sorted(by: sortRouteSuggestions)
    }
    
    /// Fetches KMB stops, keeping only stops with valid coordinates.
    func fetchStops() async throws -> [StopInfo] {
        let response: StopResponse = try await fetch(path: "stop/")
        return response.data.compactMap { stop in
            guard let latitudeText = stop.lat,
                  let longitudeText = stop.long,
                  let latitude = Double(latitudeText),
                  let longitude = Double(longitudeText),
                  latitude != 0.0,
                  longitude != 0.0 else {
                return nil
            }
            return stop.tagged(with: operatorCode)
        }
    }
    
    /// Fetches KMB ETA rows for a stop and groups them by route/direction for dashboard cards.
    func fetchNearbyRoutes(forStopId stopId: String) async throws -> [NearbyRouteModel] {
        let response: StopETAResponse = try await fetch(path: "stop-eta/\(stopId)", reloadIgnoringCache: true)
        let etaItemsByRouteDirection = Dictionary(grouping: response.data.filter { $0.service_type == 1 }) { etaItem in
            "\(etaItem.route)-\(etaItem.dir)"
        }
        
        let routes = etaItemsByRouteDirection.compactMap { routeDirectionKey, etaItems -> NearbyRouteModel? in
            guard let firstEtaItem = etaItems.first else { return nil }
            let routeDirectionParts = routeDirectionKey.components(separatedBy: "-")
            guard routeDirectionParts.count >= 2 else { return nil }
            
            return NearbyRouteModel(
                co: operatorCode.rawValue,
                route: routeDirectionParts[0],
                directionCode: routeDirectionParts[1],
                destNameTc: firstEtaItem.dest_tc,
                etas: sortedDisplayETAs(from: etaItems)
            )
        }
        
        return routes.sorted { $0.route.localizedStandardCompare($1.route) == .orderedAscending }
    }
    
    /// Fetches ordered route stops and attaches up to three ETAs to each stop row.
    func fetchTimetableRows(route: String, direction: BusDirection, stopNameById: [String: String]) async throws -> [StopDisplayModel] {
        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
        let routeStopResponse: RouteStopResponse = try await fetch(path: "route-stop/\(safeRoute)/\(direction.rawValue)/1", reloadIgnoringCache: true)
        
        var rows: [StopDisplayModel] = []
        for routeStop in routeStopResponse.data {
            let stopId = routeStop.stop
            let stopSequence = Int(routeStop.seq) ?? 0
            let stopName = stopNameById[stopId] ?? "未知車站"
            let etaItems = try? await fetchStopETAItems(stopId: stopId)
            let matchingETAs = sortedDisplayETAs(
                from: etaItems ?? [],
                route: route,
                directionCode: direction.routeCode
            )
            
            rows.append(
                StopDisplayModel(
                    seq: stopSequence,
                    stopId: stopId,
                    stopNameTc: stopName,
                    etas: Array(matchingETAs.prefix(3))
                )
            )
        }
        
        return rows.sorted { $0.seq < $1.seq }
    }
    
    /// Finds the nearest stop for one favourite route and returns its current ETA status.
    func fetchFavoriteStatus(for favorite: FavoriteRoute, context: RouteStopLookupContext) async throws -> FavoriteStatusModel? {
        let direction = BusDirection(rawValue: favorite.direction) ?? .outbound
        let safeRoute = favorite.route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? favorite.route
        let routeStopResponse: RouteStopResponse = try await fetch(path: "route-stop/\(safeRoute)/\(direction.rawValue)/1")
        
        var nearestStopId: String?
        var nearestStopName = "未知車站"
        var nearestDistance: CLLocationDistance = .infinity
        
        for routeStop in routeStopResponse.data {
            guard let stopInfo = context.stopInfoById[routeStop.stop],
                  let stopLocation = stopInfo.clLocation else {
                continue
            }
            
            let distance = context.userLocation.distance(from: stopLocation)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestStopId = routeStop.stop
                nearestStopName = stopInfo.name_tc
            }
        }
        
        guard let nearestStopId else { return nil }
        let etaItems = try await fetchStopETAItems(stopId: nearestStopId)
        let etas = sortedDisplayETAs(from: etaItems, route: favorite.route, directionCode: direction.routeCode)
        return FavoriteStatusModel(etas: Array(etas.prefix(3)), distance: nearestDistance, stopName: nearestStopName)
    }
    
    /// Fetches sorted ETAs for a timer's route, direction, and stop.
    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String) async throws -> [ETADisplayInfo] {
        let etaItems = try await fetchStopETAItems(stopId: stopId)
        return sortedDisplayETAs(from: etaItems, route: route, directionCode: direction.routeCode)
    }
}

private extension KMBETAProvider {
    /// Fetches and decodes one KMB API path.
    ///
    /// - Parameters:
    ///   - path: Path appended to the KMB base URL.
    ///   - reloadIgnoringCache: Whether to bypass URL cache for live ETA data.
    /// - Returns: Decoded response DTO.
    func fetch<Response: Decodable>(path: String, reloadIgnoringCache: Bool = false) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        if reloadIgnoringCache {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return try jsonDecoder.decode(Response.self, from: data)
    }
    
    /// Fetches raw stop ETA DTOs for one KMB stop.
    func fetchStopETAItems(stopId: String) async throws -> [StopETAItem] {
        let response: StopETAResponse = try await fetch(path: "stop-eta/\(stopId)", reloadIgnoringCache: true)
        return response.data
    }
    
    /// Converts KMB ETA DTOs into app display ETA models.
    ///
    /// - Parameters:
    ///   - items: Raw KMB ETA DTOs.
    ///   - route: Optional route filter.
    ///   - directionCode: Optional `O`/`I` direction filter.
    /// - Returns: Arrival times sorted by date.
    func sortedDisplayETAs(from items: [StopETAItem], route: String? = nil, directionCode: String? = nil) -> [ETADisplayInfo] {
        let formatter = ISO8601DateFormatter()
        return items.compactMap { item -> ETADisplayInfo? in
            if let route, item.route != route { return nil }
            if let directionCode, item.dir != directionCode { return nil }
            guard item.service_type == 1,
                  let etaText = item.eta,
                  !etaText.isEmpty,
                  let etaDate = formatter.date(from: etaText) else {
                return nil
            }
            return ETADisplayInfo(etaDate: etaDate, remark: item.rmk_tc, companyCode: operatorCode.rawValue)
        }
        .sorted { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
    }
    
    /// Natural route suggestion sort shared by provider output.
    func sortRouteSuggestions(_ first: RouteSuggestion, _ second: RouteSuggestion) -> Bool {
        if first.route == second.route {
            return first.bound > second.bound
        }
        return first.route.localizedStandardCompare(second.route) == .orderedAscending
    }
}
