import SwiftUI

extension ContentView {
    /// Refreshes whichever screen is currently visible during the 30-second timer tick.
    func refreshVisibleData() async {
        if activeTimer != nil {
            await syncActiveTimer()
        }
        
        if selectedTab == 0 {
            if isNavigatingToRoute && !displayData.isEmpty && !showCustomKeyboard {
                await searchRoute(route: searchText.uppercased(), direction: selectedDirection, company: selectedCompany, findNearest: false, shouldScroll: false, isRefresh: true)
            } else if !isNavigatingToRoute && !nearbyStops.isEmpty && !showCustomKeyboard {
                await refreshNearbyETAs()
            }
        } else if selectedTab == 1 {
            await updateFavoriteETAs()
        }
    }
    
    /// Clears route-detail UI state after the navigation stack returns to the dashboard.
    func clearRouteDetailState() {
        searchText = ""
        displayData = []
        highlightedStopId = nil
        showCustomKeyboard = false
    }
    
    /// Removes an active timer after its ETA has passed far enough to be considered stale.
    func clearExpiredTimerIfNeeded(referenceDate: Date) {
        guard let timer = activeTimer else { return }
        let secondsLeft = timer.etaDate.timeIntervalSince(referenceDate)
        if secondsLeft <= -10 {
            withAnimation { activeTimer = nil }
            endLiveActivity()
            locationManager.stopBackgroundTracking()
        }
    }
}
