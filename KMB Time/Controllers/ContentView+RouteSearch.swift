/// 檔案用途：處理路線搜尋、provider 選擇同站點高亮邏輯。
import CoreLocation
import SwiftUI

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    /// 擷取指定路線嘅時間表列，並發布到路線詳情 UI。
    /// - Parameters:
    ///   - route: 使用者輸入或從建議選取嘅路線號碼。
    ///   - direction: 可選路線方向覆寫；無提供時使用目前選取方向。
    ///   - company: 可選營辦商覆寫；否則由建議目錄同已選營辦商推算。
    ///   - findNearest: 為 `true` 時，會高亮最接近使用者目前位置嘅列。
    ///   - targetStopCode: 從收藏或附近路線開啟後，可選擇要高亮嘅站點代碼。
    ///   - shouldScroll: 載入後觸發路線詳情列表捲動到高亮列。
    ///   - isRefresh: 重新整理可見資料時，保持現有列同載入狀態穩定。
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
    
    /// 根據已解析嘅營辦商代碼選擇對應 ETA provider。
    /// - Parameter company: 營辦商代碼，例如 `KMB`、`CTB` 或 `KMB+CTB`。
    /// - Returns: 負責為該營辦商擷取時間表、收藏或計時器 ETA 資料嘅 provider。
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
    
    /// 從符合營辦商代碼嘅 provider 擷取所選路線站點列。
    /// - Parameters:
    ///   - route: 要載入嘅路線號碼。
    ///   - direction: 路線嘅去程或回程方向。
    ///   - company: 已解析營辦商代碼，用嚟選擇 KMB、CTB 或聯營資料。
    /// - Returns: 已補本站名同 ETA 顯示資料嘅時間表列。
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

    
    /// 解析路線搜尋完成後應該高亮邊一個站點列。
    /// - Parameters:
    ///   - rows: 所選路線同方向返回嘅時間表列。
    ///   - findNearest: 啟用時使用使用者目前位置選擇最近列。
    ///   - targetStopCode: 來自收藏、附近路線或深層連結選取嘅偏好站點代碼。
    /// - Returns: 要高亮嘅列識別碼；無合適配對時返回 `nil`。
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
    
    /// 跨營辦商比較站名之前，移除站名尾段嘅站柱或月台文字。
    /// - Parameter stopName: 原始中文站名，可能以括號 metadata 作結。
    /// - Returns: 適合做相等比較嘅標準化站名。
    private func normalizedStopName(_ stopName: String) -> String {
        stopName.replacingOccurrences(
            of: "\\s*\\([^)]+\\)\\s*$",
            with: "",
            options: .regularExpression
        )
    }
    
    /// 計算參考位置到時間表列站點嘅距離。
    /// - Parameters:
    ///   - location: 作為距離起點嘅使用者位置或目標站點位置。
    ///   - stop: 需要從列、字典或完整站點列表解析站點位置嘅時間表列。
    /// - Returns: 以米為單位嘅距離；站點無可用座標時返回 `.infinity`。
    private func distanceFromLocation(_ location: CLLocation, to stop: StopDisplayModel) -> CLLocationDistance {
        let stopLocation = stop.location ?? stopInfoDictionary[stop.stopId]?.clLocation ?? allStops.first(where: { $0.stop == stop.stopId })?.clLocation
        return stopLocation.map { location.distance(from: $0) } ?? .infinity
    }
}
