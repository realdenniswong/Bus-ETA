import CoreLocation
import Foundation

/// Supported bus operators.
///
/// Add a new case here only when the app is ready to display and persist that operator.
enum BusOperator: String, Codable, CaseIterable, Identifiable {
    case kmb = "KMB"
    case ctb = "CTB"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .kmb:
            return "九巴"
        case .ctb:
            return "城巴"
        }
    }
}

/// App-level direction value shared by providers and views.
///
/// Providers convert this value to whichever API parameter their company uses.
enum BusDirection: String, Codable, CaseIterable {
    case outbound
    case inbound
    
    var routeCode: String {
        switch self {
        case .outbound:
            return "O"
        case .inbound:
            return "I"
        }
    }
    
    init(routeCode: String) {
        self = routeCode.uppercased().hasPrefix("O") ? .outbound : .inbound
    }
}

/// Nearest stop lookup context used when a provider must choose one stop for a route.
struct RouteStopLookupContext {
    let userLocation: CLLocation
    let stopInfoById: [String: StopInfo]
}

/// A plug-in shaped adapter for one bus company's ETA API.
///
/// `ContentView` should depend on this protocol, not on provider-specific URLs or response DTOs.
/// To add CTB later, create `CTBETAProvider: BusETAProvider` and map CTB payloads into these
/// existing app models.
protocol BusETAProvider {
    var operatorCode: BusOperator { get }
    
    /// Fetches route directions shown in the search suggestion list.
    ///
    /// - Returns: Route suggestions already tagged with this provider's operator code.
    func fetchRouteSuggestions() async throws -> [RouteSuggestion]
    
    /// Fetches all stops known to this provider.
    ///
    /// - Returns: Stops with usable coordinates for nearby-stop calculations.
    func fetchStops() async throws -> [StopInfo]
    
    /// Fetches dashboard route cards for a single stop.
    ///
    /// - Parameter stopId: Provider-specific stop identifier.
    /// - Returns: Route cards sorted and ready for dashboard rendering.
    func fetchNearbyRoutes(forStopId stopId: String) async throws -> [NearbyRouteModel]
    
    /// Fetches the route-detail timetable rows for one route direction.
    ///
    /// - Parameters:
    ///   - route: Provider-specific route number.
    ///   - direction: App-level direction value.
    ///   - stopNameById: Cached stop-name lookup built from `fetchStops()`.
    /// - Returns: Stop rows sorted by sequence.
    func fetchTimetableRows(route: String, direction: BusDirection, stopNameById: [String: String]) async throws -> [StopDisplayModel]
    
    /// Builds the favourites-tab status for one saved route.
    ///
    /// - Parameters:
    ///   - favorite: Saved route/direction pair.
    ///   - context: User location and stop cache used to choose the nearest stop.
    /// - Returns: Status row for the favourites tab, or `nil` when the route has no usable stop.
    func fetchFavoriteStatus(for favorite: FavoriteRoute, context: RouteStopLookupContext) async throws -> FavoriteStatusModel?
    
    /// Fetches ETAs for a tracked timer stop.
    ///
    /// - Parameters:
    ///   - route: Route number tracked by the timer.
    ///   - direction: Direction tracked by the timer.
    ///   - stopId: Stop id tracked by the timer.
    /// - Returns: Upcoming ETAs sorted by arrival time.
    func fetchTimerETAs(route: String, direction: BusDirection, stopId: String) async throws -> [ETADisplayInfo]
}
