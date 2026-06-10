/// 檔案用途：處理路線搜尋、provider 選擇同站點高亮邏輯。
import CoreLocation
import SwiftUI

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    /// 按照輸入條件搜尋路線並準備顯示結果。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - company: 巴士公司代碼。
    ///   - findNearest: 控制此流程是否啟用嘅設定。
    ///   - targetStopCode: 車站識別或車站資料。
    ///   - shouldScroll: 此函式需要嘅輸入資料。
    ///   - isRefresh: 控制此流程是否啟用嘅設定。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func searchRoute(route: String, direction: String? = nil, company: String? = nil, findNearest: Bool = false, targetStopCode: String? = nil, shouldScroll: Bool = false, isRefresh: Bool = false) async {
        guard !route.isEmpty else { return }
        
        let selectedBusDirection = BusDirection(rawValue: direction ?? selectedDirection) ?? .outbound
        let routeCompany = company ?? routeSuggestionCatalog.resolvedCompany(
            route: route,
            direction: selectedBusDirection,
            preferredCompany: selectedCompany
        )
        
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
    
    /// 根據路線或公司選擇合適資料提供者。
    /// - Parameters:
    ///   - company: 巴士公司代碼。
    /// - Returns: 計算後嘅 `BusETAProvider`。
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
    
    /// 根據路線或公司選擇合適資料提供者。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 計算後嘅 `BusETAProvider`。
    func providerForRoute(route: String, direction: BusDirection) -> BusETAProvider {
        providerForCompany(routeSuggestionCatalog.companyCode(route: route, direction: direction) ?? BusOperator.kmb.rawValue)
    }
    
    /// 向資料來源讀取相關巴士資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - company: 巴士公司代碼。
    /// - Returns: 符合條件並已整理嘅資料列表。
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

    
    /// 按照輸入條件搜尋路線並準備顯示結果。
    /// - Parameters:
    ///   - rows: 要處理嘅資料集合。
    ///   - findNearest: 控制此流程是否啟用嘅設定。
    ///   - targetStopCode: 車站識別或車站資料。
    /// - Returns: 格式化或查找後嘅文字。
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
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - stopName: 車站識別或車站資料。
    /// - Returns: 格式化或查找後嘅文字。
    private func normalizedStopName(_ stopName: String) -> String {
        stopName.replacingOccurrences(
            of: "\\s*\\([^)]+\\)\\s*$",
            with: "",
            options: .regularExpression
        )
    }
    
    /// 判斷指定條件是否成立。
    /// - Parameters:
    ///   - location: 用嚟計算距離嘅位置。
    ///   - to: 此函式需要嘅輸入資料。
    /// - Returns: 可用嘅位置資料；沒有時為 nil。
    private func distanceFromLocation(_ location: CLLocation, to stop: StopDisplayModel) -> CLLocationDistance {
        let stopLocation = stop.location ?? stopInfoDictionary[stop.stopId]?.clLocation ?? allStops.first(where: { $0.stop == stop.stopId })?.clLocation
        return stopLocation.map { location.distance(from: $0) } ?? .infinity
    }
}
