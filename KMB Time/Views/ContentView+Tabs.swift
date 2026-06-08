import SwiftUI
import CoreLocation
import UserNotifications

extension ContentView {
    var mainDashboardTab: some View {
        NavigationStack {
            ScrollViewReader { dashboardProxy in
                dashboardContentView
                    .onChange(of: dashboardScrollTarget) { target in
                        if let targetId = target {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                withAnimation(.spring()) {
                                    dashboardProxy.scrollTo(targetId, anchor: .top)
                                }
                            }
                            dashboardScrollTarget = nil
                        }
                    }
            }
            .navigationDestination(isPresented: $isNavigatingToRoute) {
                routeDetailView
            }
            .onChange(of: isNavigatingToRoute) { isNavigating in
                if !isNavigating {
                    clearRouteDetailState()
                    
                    if let location = locationManager.location {
                        Task { await updateNearbyStops(userLocation: location) }
                    }
                }
            }
            .onReceive(refreshTimer) { _ in
                Task { await refreshVisibleData() }
            }
            .onReceive(clockTimer) { _ in
                currentTime = Date()
                clearExpiredTimerIfNeeded(referenceDate: currentTime)
            }
            .task {
                async let stopsLoad: Void = loadAllStops()
                async let routesLoad: Void = loadAllRoutes()
                _ = await (stopsLoad, routesLoad)
                reconnectActiveLiveActivity()
                
                if locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways {
                    locationManager.requestLocation()
                }
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
            .onChange(of: locationManager.location) { _, newValue in
                if let location = newValue, !locationManager.isBackgroundTracking {
                    Task { await updateNearbyStops(userLocation: location) }
                }
            }
            .onChange(of: locationManager.backgroundHeartbeat) { _, _ in
                clearExpiredTimerIfNeeded(referenceDate: Date())
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    reconnectActiveLiveActivity()
                    locationManager.requestLocation()
                    if !isNavigatingToRoute {
                        Task {
                            if let location = locationManager.location {
                                await updateNearbyStops(userLocation: location)
                            }
                        }
                    }
                }
            }
        }
        .toolbar(showCustomKeyboard ? .hidden : .visible, for: .tabBar)
        .animation(.easeInOut(duration: 0.2), value: showCustomKeyboard)
        .tabItem {
            Label("到站預報", systemImage: "bus.fill")
        }
    }
    
    var favoritesTab: some View {
        NavigationStack {
            FavoritesView(
                favoritesManager: favoritesManager,
                favoriteStatus: favoriteStatus,
                allRoutes: allRoutes,
                currentTime: currentTime,
                onOpenFavorite: { favorite in
                    openFavoriteRoute(favorite)
                },
                onSetTimer: { favorite, status, etaDate, company in
                    prepareTimerAlert(
                        route: favorite.route,
                        destination: favorite.destNameTc,
                        stationName: status.stopName,
                        stopId: "",
                        direction: favorite.direction,
                        company: company,
                        etaDate: etaDate
                    )
                },
                onRefresh: {
                    await updateFavoriteETAs()
                }
            )
        }
        .task {
            if selectedTab == 1 {
                await updateFavoriteETAs()
            }
        }
        .onChange(of: selectedTab) { newValue in
            if newValue == 1 {
                Task { await updateFavoriteETAs() }
            }
        }
        .tabItem {
            Label("常用路線", systemImage: "star.fill")
        }
    }
    
    /// Opens a saved favourite route in the route-detail screen.
    ///
    /// - Parameter favorite: Saved favourite selected from the favourites tab.
    func openFavoriteRoute(_ favorite: FavoriteRoute) {
        selectedTab = 0
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            searchText = favorite.route
            selectedDirection = favorite.direction
            isNavigatingToRoute = true
            Task { await searchRoute(route: favorite.route, direction: favorite.direction, findNearest: true, shouldScroll: true) }
        }
    }
    
    /// Refreshes whichever screen is currently visible during the 30-second timer tick.
    ///
    /// This keeps route details, nearby dashboard ETAs, favourites, and the active timer current
    /// without forcing every part of the app to reload on every tick.
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
    ///
    /// - Parameter referenceDate: Time used to calculate whether the tracked ETA has expired.
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
