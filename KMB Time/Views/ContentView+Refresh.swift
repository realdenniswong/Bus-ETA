/// 檔案用途：集中處理可見資料重新整理同過期狀態清理。
import SwiftUI

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    /// 重新整理目前畫面需要嘅資料。
    /// - Parameters:
    ///   - rebuildNearbyWhenEmpty: 此函式需要嘅輸入資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func refreshVisibleData(rebuildNearbyWhenEmpty: Bool = false) async {
        if activeTimer != nil {
            await syncActiveTimer()
        }
        
        if selectedTab == 0 {
            if isNavigatingToRoute && !displayData.isEmpty && !showCustomKeyboard {
                await searchRoute(route: searchText.uppercased(), direction: selectedDirection, company: selectedCompany, findNearest: false, shouldScroll: false, isRefresh: true)
            } else if !isNavigatingToRoute && !showCustomKeyboard {
                if !nearbyStops.isEmpty {
                    await refreshNearbyETAs()
                } else if rebuildNearbyWhenEmpty, let location = locationManager.location {
                    await updateNearbyStops(userLocation: location)
                }
            }
        } else if selectedTab == 1 {
            await updateFavoriteETAs()
        }
    }
    
    /// 清除指定狀態或暫存資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func clearRouteDetailState() {
        searchText = ""
        displayData = []
        highlightedStopId = nil
        showCustomKeyboard = false
    }
    
    /// 清除指定狀態或暫存資料。
    /// - Parameters:
    ///   - referenceDate: 時間或到站時間資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func clearExpiredTimerIfNeeded(referenceDate: Date) {
        guard let timer = activeTimer else { return }
        let secondsLeft = timer.etaDate.timeIntervalSince(referenceDate)
        if secondsLeft <= -10 {
            withAnimation { activeTimer = nil }
            Task { await endLiveActivity() }
            locationManager.stopBackgroundTracking()
        }
    }
}
