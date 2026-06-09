import CoreLocation
import SwiftUI

extension ContentView {
    /// Loads the stop-by-stop timetable for one route direction.
    func searchRoute(route: String, direction: String? = nil, company: String? = nil, findNearest: Bool = false, targetStopCode: String? = nil, shouldScroll: Bool = false, isRefresh: Bool = false) async {
        guard !route.isEmpty else { return }
        
        let selectedBusDirection = BusDirection(rawValue: direction ?? selectedDirection) ?? .outbound
        let routeCompany = company ?? resolvedCompanyForSearch(route: route, direction: selectedBusDirection)
        
        await MainActor.run {
            if let direction {
                self.selectedDirection = direction
            }
            self.selectedCompany = routeCompany
            if !isRefresh {
                isLoading = true
                displayData = []
                highlightedStopId = nil
            }
        }
        
        do {
            let timetableRows = try await fetchTimetableRows(
                route: route,
                direction: selectedBusDirection,
                company: routeCompany
            )
            let highlightStopId = highlightedStopIdForRouteSearch(
                rows: timetableRows,
                findNearest: findNearest,
                targetStopCode: targetStopCode
            )
            
            await MainActor.run {
                self.highlightedStopId = highlightStopId
                if timetableRows.isEmpty {
                    systemMessage = "沒有找到路線 \(route) 的 \(selectedBusDirection.rawValue == "outbound" ? "去程" : "回程") 班次數據。"
                    if !isRefresh { displayData = [] }
                } else {
                    displayData = timetableRows
                }
                if shouldScroll { self.scrollTriggerId = UUID() }
                if !isRefresh { isLoading = false }
            }
        } catch {
            await MainActor.run {
                systemMessage = "無法加載數據或找不到此路線。"
                if !isRefresh {
                    displayData = []
                    isLoading = false
                }
            }
        }
    }
    
    func providerForCompany(_ company: String) -> BusETAProvider {
        switch company {
        case "KMB+CTB":
            return jointRouteETAProvider
        case BusOperator.ctb.rawValue:
            return ctbETAProvider
        default:
            return kmbETAProvider
        }
    }
    
    func providerForRoute(route: String, direction: BusDirection) -> BusETAProvider {
        providerForCompany(companyCodeForRoute(route: route, direction: direction) ?? BusOperator.kmb.rawValue)
    }
    
    private func fetchTimetableRows(route: String, direction: BusDirection, company: String) async throws -> [StopDisplayModel] {
        switch company {
        case BusOperator.ctb.rawValue:
            return try await ctbETAProvider.fetchTimetableRows(route: route, direction: direction, stopNameById: stopDictionary)
        case "KMB+CTB":
            return try await jointRouteETAProvider.fetchTimetableRows(route: route, direction: direction, stopNameById: stopDictionary)
        default:
            return try await kmbETAProvider.fetchTimetableRows(route: route, direction: direction, stopNameById: stopDictionary)
        }
    }
    
    private func resolvedCompanyForSearch(route: String, direction: BusDirection) -> String {
        if routeHasCompany(route: route, direction: direction, company: selectedCompany) {
            return selectedCompany
        }
        return companyCodeForRoute(route: route, direction: direction) ?? BusOperator.kmb.rawValue
    }
    
    private func companyCodeForRoute(route: String, direction: BusDirection) -> String? {
        let matchingSuggestions = routeSuggestions(route: route, direction: direction)
        if matchingSuggestions.count == 1 {
            return matchingSuggestions.first?.co
        }
        if let jointSuggestion = matchingSuggestions.first(where: { $0.co == "KMB+CTB" }) {
            return jointSuggestion.co
        }
        return ctbETAProvider.companyCode(route: route, direction: direction)
    }
    
    private func routeHasCompany(route: String, direction: BusDirection, company: String) -> Bool {
        routeSuggestions(route: route, direction: direction).contains { $0.co == company }
    }
    
    private func routeSuggestions(route: String, direction: BusDirection) -> [RouteSuggestion] {
        let normalizedRoute = route.uppercased()
        let bound = direction.routeCode
        return allRoutes.filter { $0.route == normalizedRoute && $0.bound == bound }
    }
    
    private func highlightedStopIdForRouteSearch(rows: [StopDisplayModel], findNearest: Bool, targetStopCode: String?) -> String? {
        if findNearest, let userLocation = locationManager.location {
            return rows.min { firstCandidate, secondCandidate in
                let firstDistance = distanceFromLocation(userLocation, to: firstCandidate)
                let secondDistance = distanceFromLocation(userLocation, to: secondCandidate)
                return firstDistance < secondDistance
            }?.id
        }
        
        guard let targetStopCode else {
            return highlightedStopId
        }
        
        if let exactMatch = rows.first(where: { $0.stopId == targetStopCode }) {
            return exactMatch.id
        }
        
        let targetStopName = normalizedStopName(stopInfoDictionary[targetStopCode]?.name_tc ?? "")
        if let nameMatch = rows.first(where: { row in
            !targetStopName.isEmpty && normalizedStopName(row.stopNameTc) == targetStopName
        }) {
            return nameMatch.id
        }
        
        guard let targetLocation = stopInfoDictionary[targetStopCode]?.clLocation else { return nil }
        return rows.min { firstCandidate, secondCandidate in
            let firstDistance = distanceFromLocation(targetLocation, to: firstCandidate)
            let secondDistance = distanceFromLocation(targetLocation, to: secondCandidate)
            return firstDistance < secondDistance
        }?.id
    }
    
    private func normalizedStopName(_ stopName: String) -> String {
        stopName.replacingOccurrences(
            of: "\\s*\\([^)]+\\)\\s*$",
            with: "",
            options: .regularExpression
        )
    }
    
    private func distanceFromLocation(_ location: CLLocation, to stop: StopDisplayModel) -> CLLocationDistance {
        let stopLocation = stop.location ?? stopInfoDictionary[stop.stopId]?.clLocation ?? allStops.first(where: { $0.stop == stop.stopId })?.clLocation
        return stopLocation.map { location.distance(from: $0) } ?? .infinity
    }
}
