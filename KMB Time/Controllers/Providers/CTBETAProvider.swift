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
        var models: [NearbyRouteModel] = []

        for direction in directions {
            let apiStopId = await matchedAPIStopId(
                route: direction.routeName,
                direction: direction.bound,
                near: targetStopInfo?.clLocation
            )
            let etas: [ETADisplayInfo]
            if let apiStopId {
                etas = (try? await fetchCTBETAs(stopId: apiStopId, route: direction.routeName, direction: direction.bound)) ?? []
            } else {
                etas = []
            }

            models.append(
                NearbyRouteModel(
                    co: direction.companyCode,
                    route: direction.routeName,
                    directionCode: direction.bound.routeCode,
                    destNameTc: direction.destinationName,
                    etas: Array(etas.prefix(3))
                )
            )
        }

        return models.sorted {
            if $0.route == $1.route { return $0.directionCode < $1.directionCode }
            return $0.route.localizedStandardCompare($1.route) == .orderedAscending
        }
    }

    func fetchTimetableRows(route: String, direction: BusDirection, stopNameById: [String: String]) async throws -> [StopDisplayModel] {
        let rows = try await fetchAPIRouteStops(route: route, direction: direction)
        var displayRows: [StopDisplayModel] = []

        for row in rows.sorted(by: { $0.stopSequence < $1.stopSequence }) {
            let stopInfo = try? await fetchStopInfo(stopId: row.stopId)
            let etas = (try? await fetchCTBETAs(stopId: row.stopId, route: route, direction: direction)) ?? []
            displayRows.append(
                StopDisplayModel(
                    seq: row.stopSequence,
                    stopId: row.stopId,
                    stopNameTc: stopInfo?.name_tc ?? stopNameById[row.stopId] ?? "未知車站",
                    etas: Array(etas.prefix(3)),
                    location: stopInfo?.clLocation
                )
            )
        }

        return displayRows
    }

    func fetchFavoriteStatus(for favorite: FavoriteRoute, context: RouteStopLookupContext) async throws -> FavoriteStatusModel? {
        let direction = BusDirection(rawValue: favorite.direction) ?? .outbound
        let rows = try await fetchAPIRouteStops(route: favorite.route, direction: direction)

        var nearestRow: CTBRouteStopRow?
        var nearestStopInfo: StopInfo?
        var nearestDistance: CLLocationDistance = .infinity

        for row in rows {
            guard let stopInfo = try? await fetchStopInfo(stopId: row.stopId),
                  let rowLocation = stopInfo.clLocation else { continue }
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
    func loadRouteList() async throws -> [CTBRouteAPIItem] {
        if let routes = routeStore.routeListIfLoaded() {
            return routes
        }

        let response: CTBRouteResponse = try await fetch(path: "route/CTB")
        return routeStore.updateRouteList(response.data)
    }

    func fetchAPIRouteStops(route: String, direction: BusDirection) async throws -> [CTBRouteStopRow] {
        if let rows = routeStore.apiRouteStops(route: route, direction: direction) {
            return rows
        }

        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
        let response: CTBRouteStopResponse = try await fetch(path: "route-stop/CTB/\(safeRoute)/\(direction.apiRouteStopPathComponent)")
        let rows = response.data.map {
            CTBRouteStopRow(
                routeName: $0.route.uppercased(),
                direction: BusDirection(routeCode: $0.dir),
                stopSequence: $0.seq.intValue,
                stopId: $0.stop
            )
        }
        return routeStore.updateAPIRouteStops(rows, route: route, direction: direction)
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
        guard let rows = try? await fetchAPIRouteStops(route: route, direction: direction) else { return nil }

        var bestStopId: String?
        var bestDistance: CLLocationDistance = .infinity

        for row in rows {
            guard let stopInfo = try? await fetchStopInfo(stopId: row.stopId),
                  let stopLocation = stopInfo.clLocation else { continue }
            let distance = location.distance(from: stopLocation)
            if distance < bestDistance {
                bestDistance = distance
                bestStopId = row.stopId
            }
        }

        return bestDistance <= 100 ? bestStopId : nil
    }

    func fetchCTBETAs(stopId: String, route: String, direction: BusDirection) async throws -> [ETADisplayInfo] {
        let safeStopId = stopId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stopId
        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
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

            var remarkParts = ["城巴"]
            if let remark = item.rmk_tc, !remark.isEmpty {
                remarkParts.append(remark)
            }
            return ETADisplayInfo(etaDate: etaDate, remark: remarkParts.joined(separator: " "), companyCode: operatorCode.rawValue)
        }
        .sorted { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
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
    private var hasLoadedCSVData = false
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

    func loadCSVDataIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasLoadedCSVData else { return }
        hasLoadedCSVData = true

        guard let csvURL = Bundle.main.url(forResource: "ctb_routes_all_stops", withExtension: "csv"),
              let content = try? String(contentsOf: csvURL, encoding: .utf8) else {
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

        let routeInfoByRoute = Dictionary(routeList.map { ($0.route.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return (csvDirectionsByStopId[stopId] ?? []).map { direction in
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

    func companyCode(route: String, direction: BusDirection) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return companyCodeByRouteDirection[key(route: route.uppercased(), direction: direction)]
    }

    private func value(_ name: String, in record: [String], indexes: [String: Int]) -> String? {
        guard let index = indexes[name], index < record.count else { return nil }
        let trimmed = record[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func key(route: String, direction: BusDirection) -> String {
        "\(route.uppercased())-\(direction.rawValue)"
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
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isInsideQuotes = false
        var iterator = content.makeIterator()

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
