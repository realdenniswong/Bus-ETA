import CoreLocation
import Foundation

/// Citybus/CTB implementation backed by official DATA.GOV.HK v2 APIs.
///
/// CTB does not expose one all-stops or all-route-stops endpoint. The provider uses:
/// - `route/CTB` for search suggestions.
/// - `route-stop/CTB/{route}/{outbound|inbound}` for route detail rows.
/// - `stop/{stopId}` and `eta/CTB/{stopId}/{route}` for stop names, coordinates, and live ETAs.
/// - The bundled CSV only for nearby-stop discovery and KMB+CTB joint-route tagging.
struct CTBETAProvider: BusETAProvider {
    static let shared = CTBETAProvider()

    let operatorCode: BusOperator = .ctb

    private let baseURL = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/")!
    private let jsonDecoder = JSONDecoder()
    private let routeStore = CTBRouteStore.shared

    private init() { }

    func fetchRouteSuggestions() async throws -> [RouteSuggestion] {
        let routes = try await loadRouteList()
        routeStore.loadCSVDataIfNeeded()

        return routes.flatMap { route in
            [BusDirection.outbound, .inbound].map { direction in
                RouteSuggestion(
                    co: routeStore.companyCode(route: route.route, direction: direction) ?? route.co ?? operatorCode.rawValue,
                    route: route.route.uppercased(),
                    bound: direction.routeCode,
                    origin: direction == .outbound ? route.orig_tc : route.dest_tc,
                    destination: direction == .outbound ? route.dest_tc : route.orig_tc
                )
            }
        }
        .sorted(by: sortRouteSuggestions)
    }

    func fetchStops() async throws -> [StopInfo] {
        routeStore.loadCSVDataIfNeeded()
        return routeStore.stops
    }

    func fetchNearbyRoutes(forStopId stopId: String) async throws -> [NearbyRouteModel] {
        _ = try await loadRouteList()
        routeStore.loadCSVDataIfNeeded()

        let targetStopInfo = routeStore.stopInfo(stopId: stopId)
        let directions = routeStore.routeDirections(servingStopId: stopId)
        let models = await nearbyRouteModels(for: directions, near: targetStopInfo?.clLocation)

        return models.sorted {
            if $0.route == $1.route { return $0.directionCode < $1.directionCode }
            return $0.route.localizedStandardCompare($1.route) == .orderedAscending
        }
    }

    func fetchTimetableRows(route: String, direction: BusDirection, stopNameById: [String: String]) async throws -> [StopDisplayModel] {
        let rows = try await fetchAPIRouteStops(route: route, direction: direction)
        return await withTaskGroup(of: StopDisplayModel.self) { group in
            for row in rows.sorted(by: { $0.stopSequence < $1.stopSequence }) {
                group.addTask {
                    async let stopInfo = try? fetchStopInfo(stopId: row.stopId)
                    async let etas = (try? fetchCTBETAs(stopId: row.stopId, route: route, direction: direction)) ?? []
                    let resolvedStopInfo = await stopInfo
                    let resolvedETAs = await etas
                    return StopDisplayModel(
                        seq: row.stopSequence,
                        stopId: row.stopId,
                        stopNameTc: resolvedStopInfo?.name_tc ?? stopNameById[row.stopId] ?? "未知車站",
                        etas: Array(resolvedETAs.prefix(3)),
                        location: resolvedStopInfo.flatMap { Self.stopLocation(from: $0) }
                    )
                }
            }

            var displayRows: [StopDisplayModel] = []
            for await row in group {
                displayRows.append(row)
            }
            return displayRows.sorted { $0.seq < $1.seq }
        }
    }

    func fetchFavoriteStatus(for favorite: FavoriteRoute, context: RouteStopLookupContext) async throws -> FavoriteStatusModel? {
        let direction = BusDirection(rawValue: favorite.direction) ?? .outbound
        let rows = try await fetchAPIRouteStops(route: favorite.route, direction: direction)

        var nearestRow: CTBRouteStopRow?
        var nearestStopInfo: StopInfo?
        var nearestDistance: CLLocationDistance = .infinity

        for row in rows {
            guard let stopInfo = try? await fetchStopInfo(stopId: row.stopId),
                  let rowLocation = Self.stopLocation(from: stopInfo) else { continue }
            let distance = context.userLocation.distance(from: rowLocation)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestRow = row
                nearestStopInfo = stopInfo
            }
        }

        guard let nearestRow, let nearestStopInfo else { return nil }
        let etas = try await fetchCTBETAs(stopId: nearestRow.stopId, route: favorite.route, direction: direction)
        return FavoriteStatusModel(etas: Array(etas.prefix(3)), distance: nearestDistance, stopName: nearestStopInfo.name_tc)
    }

    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String) async throws -> [ETADisplayInfo] {
        try await fetchCTBETAs(stopId: stopId, route: route, direction: direction)
    }
}

extension CTBETAProvider {
    func nearbyStops(near location: CLLocation, limit: Int) async throws -> [StopInfo] {
        routeStore.loadCSVDataIfNeeded()
        return routeStore.nearbyStops(near: location, limit: limit)
    }

    func fetchNearbyRoutes(near location: CLLocation) async throws -> [NearbyRouteModel] {
        _ = try await loadRouteList()
        routeStore.loadCSVDataIfNeeded()
        let directions = routeStore.routeDirections(near: location, radius: 120, limitStops: 3)
        let models = await nearbyRouteModels(for: directions, near: location)

        return models.sorted {
            if $0.route == $1.route { return $0.directionCode < $1.directionCode }
            return $0.route.localizedStandardCompare($1.route) == .orderedAscending
        }
    }

    func isJointRoute(route: String, direction: BusDirection) -> Bool {
        routeStore.loadCSVDataIfNeeded()
        return routeStore.companyCode(route: route, direction: direction) == "KMB+CTB"
    }

    func companyCode(route: String, direction: BusDirection) -> String? {
        routeStore.loadCSVDataIfNeeded()
        return routeStore.companyCode(route: route, direction: direction)
    }
}

private extension CTBETAProvider {
    func nearbyRouteModels(for directions: [CTBRouteDirection], near location: CLLocation?) async -> [NearbyRouteModel] {
        await withTaskGroup(of: NearbyRouteModel.self) { group in
            for direction in directions {
                group.addTask {
                    await nearbyRouteModel(for: direction, near: location)
                }
            }
            
            var models: [NearbyRouteModel] = []
            for await model in group {
                models.append(model)
            }
            return models
        }
    }
    
    func nearbyRouteModel(for direction: CTBRouteDirection, near location: CLLocation?) async -> NearbyRouteModel {
        let apiStopId = await matchedAPIStopId(
            route: direction.routeName,
            direction: direction.bound,
            near: location
        )
        let etas: [ETADisplayInfo]
        let matchedStopName: String?
        if let apiStopId {
            matchedStopName = (try? await fetchStopInfo(stopId: apiStopId))?.name_tc
            etas = (try? await fetchCTBETAs(stopId: apiStopId, route: direction.routeName, direction: direction.bound)) ?? []
        } else {
            matchedStopName = nil
            etas = []
        }
        
        return NearbyRouteModel(
            co: direction.companyCode,
            route: direction.routeName,
            directionCode: direction.bound.routeCode,
            destNameTc: direction.destinationName,
            displayStopName: direction.companyCode == BusOperator.ctb.rawValue ? matchedStopName : nil,
            etas: Array(etas.prefix(3))
        )
    }
    
    func loadRouteList() async throws -> [CTBRouteAPIItem] {
        if let routes = routeStore.routeListIfLoaded() {
            return routes
        }

        let task = routeStore.routeListTaskOrCreate {
            Task {
                let response: CTBRouteResponse = try await fetch(path: "route/CTB")
                return response.data
            }
        }

        do {
            let routes = try await task.value
            routeStore.clearRouteListTask()
            return routeStore.updateRouteList(routes)
        } catch {
            routeStore.clearRouteListTask()
            throw error
        }
    }

    func fetchAPIRouteStops(route: String, direction: BusDirection) async throws -> [CTBRouteStopRow] {
        if let rows = routeStore.apiRouteStops(route: route, direction: direction) {
            return rows
        }

        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
        let task = routeStore.apiRouteStopsTaskOrCreate(route: route, direction: direction) {
            Task {
                let response: CTBRouteStopResponse = try await fetch(path: "route-stop/CTB/\(safeRoute)/\(direction.apiRouteStopPathComponent)")
                return response.data.map {
                    CTBRouteStopRow(
                        routeName: $0.route.uppercased(),
                        direction: BusDirection(routeCode: $0.dir),
                        stopSequence: $0.seq.intValue,
                        stopId: $0.stop
                    )
                }
            }
        }

        do {
            let rows = try await task.value
            routeStore.clearAPIRouteStopsTask(route: route, direction: direction)
            return routeStore.updateAPIRouteStops(rows, route: route, direction: direction)
        } catch {
            routeStore.clearAPIRouteStopsTask(route: route, direction: direction)
            throw error
        }
    }

    func fetchStopInfo(stopId: String) async throws -> StopInfo? {
        if let stopInfo = routeStore.stopInfo(stopId: stopId) {
            return stopInfo
        }

        let safeStopId = stopId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stopId
        let response: CTBStopDetailResponse = try await fetch(path: "stop/\(safeStopId)")
        guard let stop = response.data.stop,
              let name = response.data.name_tc,
              let latitude = response.data.lat,
              let longitude = response.data.long else {
            return nil
        }

        let stopInfo = StopInfo(stop: stop, name_tc: name, lat: latitude, long: longitude)
        routeStore.updateStopInfo(stopInfo)
        return stopInfo
    }

    func matchedAPIStopId(route: String, direction: BusDirection, near location: CLLocation?) async -> String? {
        guard let location else { return nil }
        if let cachedStopId = routeStore.matchedStopId(route: route, direction: direction, near: location) {
            return cachedStopId
        }
        guard let rows = try? await fetchAPIRouteStops(route: route, direction: direction) else { return nil }

        let bestMatch = await withTaskGroup(of: (stopId: String, distance: CLLocationDistance)?.self) { group in
            for row in rows {
                group.addTask {
                    guard let stopInfo = try? await fetchStopInfo(stopId: row.stopId),
                          let stopLocation = Self.stopLocation(from: stopInfo) else { return nil }
                    return (row.stopId, location.distance(from: stopLocation))
                }
            }

            var bestMatch: (stopId: String, distance: CLLocationDistance)?
            for await match in group {
                guard let match else { continue }
                if bestMatch == nil || match.distance < bestMatch!.distance {
                    bestMatch = match
                }
            }
            return bestMatch
        }

        // CTB's imported CSV coordinates can differ from v2 stop API coordinates by over 200m
        // for the same named stop, so keep this wider than normal pole matching.
        guard let bestMatch, bestMatch.distance <= 350 else { return nil }
        routeStore.updateMatchedStopId(bestMatch.stopId, route: route, direction: direction, near: location)
        return bestMatch.stopId
    }

    nonisolated static func stopLocation(from stopInfo: StopInfo) -> CLLocation? {
        guard let latitudeText = stopInfo.lat,
              let longitudeText = stopInfo.long,
              let latitude = Double(latitudeText),
              let longitude = Double(longitudeText) else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    func fetchCTBETAs(stopId: String, route: String, direction: BusDirection) async throws -> [ETADisplayInfo] {
        if let cachedETAs = routeStore.cachedETAs(stopId: stopId, route: route, direction: direction) {
            return cachedETAs
        }

        let safeStopId = stopId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stopId
        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
        let task = routeStore.etaTaskOrCreate(stopId: stopId, route: route, direction: direction) {
            Task {
                let response: CTBETAResponse = try await fetch(path: "eta/CTB/\(safeStopId)/\(safeRoute)", reloadIgnoringCache: true)
                let formatter = ISO8601DateFormatter()

                return response.data.compactMap { item -> ETADisplayInfo? in
                    if item.route.uppercased() != route.uppercased() { return nil }
                    if let itemDirection = item.dir, itemDirection != direction.routeCode { return nil }
                    guard let etaText = item.eta,
                          !etaText.isEmpty,
                          let etaDate = formatter.date(from: etaText) else {
                        return nil
                    }

                    return ETADisplayInfo(etaDate: etaDate, remark: item.rmk_tc, companyCode: operatorCode.rawValue)
                }
                .sorted { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
            }
        }

        do {
            let etas = try await task.value
            routeStore.clearETATask(stopId: stopId, route: route, direction: direction)
            routeStore.updateETACache(etas, stopId: stopId, route: route, direction: direction)
            return etas
        } catch {
            routeStore.clearETATask(stopId: stopId, route: route, direction: direction)
            throw error
        }
    }

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

    func sortRouteSuggestions(_ first: RouteSuggestion, _ second: RouteSuggestion) -> Bool {
        if first.route == second.route {
            if first.bound == second.bound {
                return first.co < second.co
            }
            return first.bound > second.bound
        }
        return first.route.localizedStandardCompare(second.route) == .orderedAscending
    }

}

private struct CTBRouteResponse: Decodable {
    let data: [CTBRouteAPIItem]
}

private struct CTBRouteAPIItem: Decodable {
    let co: String?
    let route: String
    let orig_tc: String
    let dest_tc: String
}

private struct CTBRouteStopResponse: Decodable {
    let data: [CTBRouteStopAPIItem]
}

private struct CTBRouteStopAPIItem: Decodable {
    let route: String
    let dir: String
    let seq: FlexibleInt
    let stop: String
}

private struct CTBStopDetailResponse: Decodable {
    let data: CTBStopDetailData
}

private struct CTBStopDetailData: Decodable {
    let stop: String?
    let name_tc: String?
    let lat: String?
    let long: String?
}

private struct CTBETAResponse: Decodable {
    let data: [CTBETAItem]
}

private struct CTBETAItem: Decodable {
    let route: String
    let dir: String?
    let eta: String?
    let rmk_tc: String?
}

private enum FlexibleInt: Decodable {
    case value(Int)

    var intValue: Int {
        switch self {
        case .value(let value):
            return value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .value(intValue)
            return
        }
        let stringValue = try container.decode(String.self)
        self = .value(Int(stringValue) ?? 0)
    }
}

private final class CTBRouteStore {
    static let shared = CTBRouteStore()

    private(set) var stops: [StopInfo] = []
    private var routeList: [CTBRouteAPIItem] = []
    private var csvDirectionsByStopId: [String: [CTBRouteDirection]] = [:]
    private var companyCodeByRouteDirection: [String: String] = [:]
    private var apiRowsByRouteDirection: [String: [CTBRouteStopRow]] = [:]
    private var stopInfoById: [String: StopInfo] = [:]
    private var matchedStopIdByRouteDirectionLocation: [String: String] = [:]
    private var routeListTask: Task<[CTBRouteAPIItem], Error>?
    private var apiRowsTasksByRouteDirection: [String: Task<[CTBRouteStopRow], Error>] = [:]
    private var etaTasksByStopRouteDirection: [String: Task<[ETADisplayInfo], Error>] = [:]
    private var etaCacheByStopRouteDirection: [String: (updatedAt: Date, etas: [ETADisplayInfo])] = [:]
    private var hasLoadedCSVData = false
    private let etaCacheLifetime: TimeInterval = 12
    private let lock = NSLock()

    private init() { }

    func routeListIfLoaded() -> [CTBRouteAPIItem]? {
        lock.lock()
        defer { lock.unlock() }
        return routeList.isEmpty ? nil : routeList
    }

    func updateRouteList(_ routes: [CTBRouteAPIItem]) -> [CTBRouteAPIItem] {
        lock.lock()
        defer { lock.unlock() }
        routeList = routes.map {
            CTBRouteAPIItem(co: $0.co, route: $0.route.uppercased(), orig_tc: $0.orig_tc, dest_tc: $0.dest_tc)
        }
        return routeList
    }

    func routeListTaskOrCreate(_ createTask: () -> Task<[CTBRouteAPIItem], Error>) -> Task<[CTBRouteAPIItem], Error> {
        lock.lock()
        defer { lock.unlock() }
        if let routeListTask {
            return routeListTask
        }
        let task = createTask()
        routeListTask = task
        return task
    }

    func clearRouteListTask() {
        lock.lock()
        defer { lock.unlock() }
        routeListTask = nil
    }

    func loadCSVDataIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasLoadedCSVData else { return }
        hasLoadedCSVData = true

        guard let csvURL = csvResourceURL(),
              let content = try? String(contentsOf: csvURL, encoding: .utf8) else {
            print("CTB CSV resource not found in app bundle or project checkout.")
            return
        }

        let records = CSVParser.parse(content)
        guard let headerIndex = records.firstIndex(where: { record in
            record.contains("ROUTE_SEQ") && record.contains("ROUTE_NAMEC") && record.contains("COMPANY_CODE")
        }) else { return }
        let header = records[headerIndex]
        let indexes = Dictionary(header.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })

        var directionsByStopId: [String: [CTBRouteDirection]] = [:]
        var stopInfoById: [String: StopInfo] = stopInfoById
        var csvStopsById: [String: StopInfo] = [:]

        for record in records.dropFirst(headerIndex + 1) {
            guard let routeName = value("ROUTE_NAMEC", in: record, indexes: indexes),
                  let routeSequence = value("ROUTE_SEQ", in: record, indexes: indexes),
                  let direction = BusDirection(routeSequence: routeSequence),
                  let stopId = value("STOP_ID", in: record, indexes: indexes),
                  let stopName = value("STOP_NAMEC", in: record, indexes: indexes),
                  let longitude = value("Longitude", in: record, indexes: indexes),
                  let latitude = value("Latitude", in: record, indexes: indexes),
                  let companyCode = value("COMPANY_CODE", in: record, indexes: indexes) else {
                continue
            }

            let routeCode = routeName.uppercased()
            let cleanStopName = cleanStopName(stopName)
            let stopInfo = StopInfo(stop: stopId, name_tc: cleanStopName, lat: latitude, long: longitude)
            csvStopsById[stopId] = stopInfo
            stopInfoById[stopId] = stopInfo
            companyCodeByRouteDirection[key(route: routeCode, direction: direction)] = companyCode

            let directionModel = CTBRouteDirection(
                routeName: routeCode,
                bound: direction,
                originName: direction == .outbound ? "起點站" : "終點站",
                destinationName: direction == .outbound ? "終點站" : "起點站",
                companyCode: companyCode
            )
            directionsByStopId[stopId, default: []].append(directionModel)
        }

        self.stops = Array(csvStopsById.values)
        self.stopInfoById = stopInfoById
        self.csvDirectionsByStopId = directionsByStopId.mapValues { directions in
            Array(Set(directions)).sorted {
                if $0.routeName == $1.routeName { return $0.bound.routeCode < $1.bound.routeCode }
                return $0.routeName.localizedStandardCompare($1.routeName) == .orderedAscending
            }
        }
    }

    func routeDirections(servingStopId stopId: String) -> [CTBRouteDirection] {
        lock.lock()
        defer { lock.unlock() }

        return enrichedDirections(csvDirectionsByStopId[stopId] ?? [])
    }
    
    func nearbyStops(near location: CLLocation, limit: Int) -> [StopInfo] {
        lock.lock()
        defer { lock.unlock() }
        return stops.compactMap { stopInfo -> (stopInfo: StopInfo, distance: CLLocationDistance)? in
            guard let stopLocation = stopLocation(from: stopInfo) else { return nil }
            return (stopInfo, location.distance(from: stopLocation))
        }
        .sorted { $0.distance < $1.distance }
        .prefix(limit)
        .map(\.stopInfo)
    }
    
    func routeDirections(near location: CLLocation, radius: CLLocationDistance, limitStops: Int) -> [CTBRouteDirection] {
        lock.lock()
        defer { lock.unlock() }

        let nearbyStopIds = stops.compactMap { stopInfo -> (stopId: String, distance: CLLocationDistance)? in
            guard let stopLocation = stopLocation(from: stopInfo) else { return nil }
            let distance = location.distance(from: stopLocation)
            guard distance <= radius else { return nil }
            return (stopInfo.stop, distance)
        }
        .sorted { $0.distance < $1.distance }
        .prefix(limitStops)
        .map(\.stopId)

        var seenKeys = Set<String>()
        let directions = nearbyStopIds.flatMap { csvDirectionsByStopId[$0] ?? [] }.filter { direction in
            let key = "\(direction.routeName)-\(direction.bound.rawValue)-\(direction.companyCode)"
            return seenKeys.insert(key).inserted
        }
        return enrichedDirections(directions)
    }

    private func stopLocation(from stopInfo: StopInfo) -> CLLocation? {
        guard let latitudeText = stopInfo.lat,
              let longitudeText = stopInfo.long,
              let latitude = Double(latitudeText),
              let longitude = Double(longitudeText) else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    private func enrichedDirections(_ directions: [CTBRouteDirection]) -> [CTBRouteDirection] {
        let routeInfoByRoute = Dictionary(routeList.map { ($0.route.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return directions.map { direction in
            guard let routeInfo = routeInfoByRoute[direction.routeName] else { return direction }
            return CTBRouteDirection(
                routeName: direction.routeName,
                bound: direction.bound,
                originName: direction.bound == .outbound ? routeInfo.orig_tc : routeInfo.dest_tc,
                destinationName: direction.bound == .outbound ? routeInfo.dest_tc : routeInfo.orig_tc,
                companyCode: direction.companyCode
            )
        }
    }

    func apiRouteStops(route: String, direction: BusDirection) -> [CTBRouteStopRow]? {
        lock.lock()
        defer { lock.unlock() }
        return apiRowsByRouteDirection[key(route: route.uppercased(), direction: direction)]
    }

    func updateAPIRouteStops(_ rows: [CTBRouteStopRow], route: String, direction: BusDirection) -> [CTBRouteStopRow] {
        lock.lock()
        defer { lock.unlock() }
        let sortedRows = rows.sorted { $0.stopSequence < $1.stopSequence }
        apiRowsByRouteDirection[key(route: route.uppercased(), direction: direction)] = sortedRows
        return sortedRows
    }

    func apiRouteStopsTaskOrCreate(route: String, direction: BusDirection, createTask: () -> Task<[CTBRouteStopRow], Error>) -> Task<[CTBRouteStopRow], Error> {
        lock.lock()
        defer { lock.unlock() }
        let taskKey = key(route: route, direction: direction)
        if let task = apiRowsTasksByRouteDirection[taskKey] {
            return task
        }
        let task = createTask()
        apiRowsTasksByRouteDirection[taskKey] = task
        return task
    }

    func clearAPIRouteStopsTask(route: String, direction: BusDirection) {
        lock.lock()
        defer { lock.unlock() }
        apiRowsTasksByRouteDirection[key(route: route, direction: direction)] = nil
    }

    func cachedETAs(stopId: String, route: String, direction: BusDirection) -> [ETADisplayInfo]? {
        lock.lock()
        defer { lock.unlock() }
        guard let cacheEntry = etaCacheByStopRouteDirection[etaKey(stopId: stopId, route: route, direction: direction)],
              Date().timeIntervalSince(cacheEntry.updatedAt) <= etaCacheLifetime else {
            return nil
        }
        return cacheEntry.etas
    }

    func updateETACache(_ etas: [ETADisplayInfo], stopId: String, route: String, direction: BusDirection) {
        lock.lock()
        defer { lock.unlock() }
        etaCacheByStopRouteDirection[etaKey(stopId: stopId, route: route, direction: direction)] = (Date(), etas)
    }

    func etaTaskOrCreate(stopId: String, route: String, direction: BusDirection, createTask: () -> Task<[ETADisplayInfo], Error>) -> Task<[ETADisplayInfo], Error> {
        lock.lock()
        defer { lock.unlock() }
        let taskKey = etaKey(stopId: stopId, route: route, direction: direction)
        if let task = etaTasksByStopRouteDirection[taskKey] {
            return task
        }
        let task = createTask()
        etaTasksByStopRouteDirection[taskKey] = task
        return task
    }

    func clearETATask(stopId: String, route: String, direction: BusDirection) {
        lock.lock()
        defer { lock.unlock() }
        etaTasksByStopRouteDirection[etaKey(stopId: stopId, route: route, direction: direction)] = nil
    }

    func stopInfo(stopId: String) -> StopInfo? {
        lock.lock()
        defer { lock.unlock() }
        return stopInfoById[stopId]
    }

    func updateStopInfo(_ stopInfo: StopInfo) {
        lock.lock()
        defer { lock.unlock() }
        stopInfoById[stopInfo.stop] = stopInfo
    }
    
    func matchedStopId(route: String, direction: BusDirection, near location: CLLocation) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return matchedStopIdByRouteDirectionLocation[locationKey(route: route, direction: direction, location: location)]
    }
    
    func updateMatchedStopId(_ stopId: String, route: String, direction: BusDirection, near location: CLLocation) {
        lock.lock()
        defer { lock.unlock() }
        matchedStopIdByRouteDirectionLocation[locationKey(route: route, direction: direction, location: location)] = stopId
    }

    func companyCode(route: String, direction: BusDirection) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return companyCodeByRouteDirection[key(route: route.uppercased(), direction: direction)]
    }

    private func csvResourceURL() -> URL? {
        if let rootURL = Bundle.main.url(forResource: "ctb_routes_all_stops", withExtension: "csv") {
            return rootURL
        }
        if let groupedURL = Bundle.main.url(forResource: "ctb_routes_all_stops", withExtension: "csv", subdirectory: "KMB Time") {
            return groupedURL
        }
        if let resourceURL = Bundle.main.resourceURL,
           let enumerator = FileManager.default.enumerator(at: resourceURL, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "ctb_routes_all_stops.csv" {
                return fileURL
            }
        }

        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let sourceRelativeURLs = [
            sourceFileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ctb_routes_all_stops.csv"),
            sourceFileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("KMB Time/ctb_routes_all_stops.csv")
        ]
        for url in sourceRelativeURLs where FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let fallbackPaths = [
            "KMB Time/ctb_routes_all_stops.csv",
            "KMB Time/KMB Time/ctb_routes_all_stops.csv"
        ]
        for path in fallbackPaths {
            let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func value(_ name: String, in record: [String], indexes: [String: Int]) -> String? {
        guard let index = indexes[name], index < record.count else { return nil }
        let trimmed = record[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func key(route: String, direction: BusDirection) -> String {
        "\(route.uppercased())-\(direction.rawValue)"
    }
    
    private func etaKey(stopId: String, route: String, direction: BusDirection) -> String {
        "\(stopId)-\(route.uppercased())-\(direction.rawValue)"
    }
    
    private func locationKey(route: String, direction: BusDirection, location: CLLocation) -> String {
        "\(key(route: route, direction: direction))-\(String(format: "%.5f", location.coordinate.latitude))-\(String(format: "%.5f", location.coordinate.longitude))"
    }

    private func cleanStopName(_ rawName: String) -> String {
        let withoutBreaks = rawName.replacingOccurrences(of: "<br>", with: " ")
        let parts = withoutBreaks
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.last ?? withoutBreaks.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CTBRouteDirection: Hashable {
    let routeName: String
    let bound: BusDirection
    let originName: String
    let destinationName: String
    let companyCode: String
}

private struct CTBRouteStopRow {
    let routeName: String
    let direction: BusDirection
    let stopSequence: Int
    let stopId: String
}

private enum CSVParser {
    static func parse(_ content: String) -> [[String]] {
        let normalizedContent = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isInsideQuotes = false
        var iterator = normalizedContent.makeIterator()

        while let character = iterator.next() {
            switch character {
            case "\"":
                if isInsideQuotes {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append(next)
                        } else {
                            isInsideQuotes = false
                            handleNonQuote(next, row: &row, field: &field, rows: &rows)
                        }
                    } else {
                        isInsideQuotes = false
                    }
                } else {
                    isInsideQuotes = true
                }
            default:
                if isInsideQuotes {
                    field.append(character)
                } else {
                    handleNonQuote(character, row: &row, field: &field, rows: &rows)
                }
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func handleNonQuote(_ character: Character, row: inout [String], field: inout String, rows: inout [[String]]) {
        switch character {
        case ",":
            row.append(field)
            field = ""
        case "\n":
            row.append(field)
            rows.append(row)
            row = []
            field = ""
        case "\r":
            break
        default:
            field.append(character)
        }
    }
}

private extension BusDirection {
    init?(routeSequence: String) {
        switch routeSequence.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1":
            self = .outbound
        case "2":
            self = .inbound
        default:
            return nil
        }
    }

    var apiRouteStopPathComponent: String {
        switch self {
        case .outbound:
            return "outbound"
        case .inbound:
            return "inbound"
        }
    }
}
