import SwiftUI

extension ContentView {
    /// Refreshes whichever screen is currently visible during timer ticks or app foregrounding.
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
