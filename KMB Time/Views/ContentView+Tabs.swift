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
                await loadAllStops()
                await loadAllRoutes()
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
            List {
                if favoritesManager.favoriteRoutes.isEmpty {
                    Text("您尚未加入任何常用路線。")
                        .foregroundColor(.secondary)
                        .padding()
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(sortedFavorites) { favorite in
                        favoriteRouteButton(favorite)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                favoriteSwipeActions(favorite)
                            }
                    }
                    .onDelete { indexSet in
                        favoritesManager.favoriteRoutes.remove(atOffsets: indexSet)
                    }
                }
            }
            .navigationTitle("常用路線")
            .padding(.top, 16)
            .background(themeBackground)
            .scrollContentBackground(.hidden)
            .refreshable {
                await updateFavoriteETAs()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        Task { await updateFavoriteETAs() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
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
    
    @ViewBuilder
    func favoriteRouteButton(_ favorite: FavoriteRoute) -> some View {
        let company = companyCode(for: favorite)
        Button(action: { openFavoriteRoute(favorite) }) {
            HStack(alignment: .center, spacing: 12) {
                Text(favorite.route)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(KMBRouteTheme.foregroundColor(route: favorite.route, company: company, allRoutes: allRoutes))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 64, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(KMBRouteTheme.backgroundColor(route: favorite.route, company: company, allRoutes: allRoutes)))
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("往")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(favorite.destNameTc)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let status = favoriteStatus[favorite.id] {
                            Text("\(status.stopName) • \(formatDistance(status.distance))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            Text("正在尋找最近車站...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                if let status = favoriteStatus[favorite.id] {
                    etaCountdownView(etas: status.etas)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    func companyCode(for favorite: FavoriteRoute) -> String {
        if favorite.company != BusOperator.kmb.rawValue {
            return favorite.company
        }
        let bound = (BusDirection(rawValue: favorite.direction) ?? .outbound).routeCode
        let matches = allRoutes.filter { suggestion in
            suggestion.route == favorite.route.uppercased() && suggestion.bound == bound
        }
        if matches.count == 1 {
            return matches[0].co
        }
        return matches.first(where: { $0.co == "KMB+CTB" })?.co ?? favorite.company
    }
    
    @ViewBuilder
    func favoriteSwipeActions(_ favorite: FavoriteRoute) -> some View {
        Button(role: .destructive) {
            if let index = favoritesManager.favoriteRoutes.firstIndex(where: { $0.id == favorite.id }) {
                favoritesManager.favoriteRoutes.remove(at: index)
            }
        } label: {
            Label("刪除", systemImage: "trash")
        }
        
        if let status = favoriteStatus[favorite.id],
           let firstEta = status.etas.first(where: { $0.etaDate?.timeIntervalSince(Date()) ?? 0 > 120 }),
           let etaDate = firstEta.etaDate {
            Button {
                prepareTimerAlert(route: favorite.route, destination: favorite.destNameTc, stationName: status.stopName, stopId: "", direction: favorite.direction, etaDate: etaDate)
            } label: {
                Label("設定提示", systemImage: "bell.fill")
            }
            .tint(.blue)
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
