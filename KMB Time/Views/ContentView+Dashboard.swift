import SwiftUI
import UserNotifications

extension ContentView {
    var dashboardContentView: some View {
        ZStack {
            List {
                searchBarView
                
                if let timer = activeTimer {
                    activeTimerCardView(timer: timer)
                }
                
                if !searchText.isEmpty {
                    suggestionsSectionView
                } else {
                    nearbyDashboardSectionView
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(themeBackground)
            .listSectionSpacing(.custom(16))
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    if showCustomKeyboard {
                        dismissKeyboardSafe()
                    }
                }
            )
        }
        .overlay(alignment: .bottom) {
            if showCustomKeyboard {
                customKeyboardOverlay
            }
        }
        .navigationTitle(showCustomKeyboard ? "搜尋路線" : "九巴到站預報")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { dashboardToolbar }
    }
    
    var searchBarView: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color(UIColor.systemGray))
                .font(.system(size: 17))
            
            Text(searchText.isEmpty ? "輸入路線 (例如 1A)" : searchText)
                .foregroundColor(searchText.isEmpty ? Color(UIColor.placeholderText) : .primary)
                .font(.system(size: 17))
                .frame(maxWidth: .infinity, alignment: .leading)
            
            if !searchText.isEmpty {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Color(UIColor.systemGray3))
                    .font(.system(size: 17))
                    .padding(.trailing, 2)
                    .padding(.vertical, 8)
                    .onTapGesture {
                        searchText = ""
                    }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(Color(UIColor.systemGray5))
        .cornerRadius(20)
        .padding(.top, 16)
        .listRowBackground(themeBackground)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .onTapGesture {
            withAnimation(.spring()) {
                showCustomKeyboard = true
            }
        }
    }
    
    var suggestionsSectionView: some View {
        SuggestionsSectionView(
            suggestions: searchSuggestions,
            allRoutes: allRoutes,
            onSelected: { suggestion, _ in
                openSuggestedRoute(suggestion)
            }
        )
    }
    
    func activeTimerCardView(timer: ActiveTimerModel) -> some View {
        ActiveTimerCardView(
            timer: timer,
            currentTime: currentTime,
            onCancel: {
                withAnimation(.easeInOut(duration: 0.3)) {
                    activeTimer = nil
                }
                endLiveActivity()
                locationManager.stopBackgroundTracking()
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["KMBTimeAlarm"])
            }
        )
        .id("ActiveTimerCard")
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
    
    var nearbyDashboardSectionView: some View {
        NearbyDashboardSectionView(
            locationManager: locationManager,
            expandedStopIds: $expandedStopIds,
            viewMode: $dashboardViewMode,
            allStops: allStops,
            nearbyStops: nearbyStops,
            currentTime: currentTime,
            allRoutes: allRoutes,
            onRequestLocation: { locationManager.requestLocation() },
            onRouteSelected: { route, stopInfo in
                openNearbyDashboardRoute(route, stopInfo: stopInfo)
            },
            onSetTimer: { route, stopInfo in
                if let firstEta = route.etas.first(where: { $0.etaDate ?? Date.distantFuture > Date() }), let etaDate = firstEta.etaDate {
                    prepareTimerAlert(
                        route: route.route.uppercased(),
                        destination: route.destNameTc,
                        stationName: stopInfo.name_tc,
                        stopId: stopInfo.stop,
                        direction: route.directionCode == "O" ? "outbound" : "inbound",
                        company: route.co,
                        etaDate: etaDate
                    )
                }
            },
            onShowToast: { message in
                showToast(message)
            }
        )
    }
    
    var customKeyboardOverlay: some View {
        CustomKeyboardView(
            text: $searchText,
            validKeys: validNextKeys,
            onSearch: {
                showCustomKeyboard = false
                isNavigatingToRoute = true
                Task { await searchRoute(route: searchText.uppercased(), direction: selectedDirection, findNearest: true, shouldScroll: true) }
            },
            onDismiss: { dismissKeyboardSafe() }
        )
        .transition(.offset(y: 300))
    }
    
    @ToolbarContentBuilder
    var dashboardToolbar: some ToolbarContent {
        if !showCustomKeyboard {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isSearchingNearby {
                    ProgressView()
                } else {
                    Button(action: refreshLocationAndNearbyStops) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .medium))
                    }
                }
                
                if !nearbyStops.isEmpty {
                    dashboardViewModeMenu
                }
            }
        }
    }
    
    var dashboardViewModeMenu: some View {
        Menu {
            Picker("顯示模式", selection: $dashboardViewMode) {
                Label("按巴士站", systemImage: "mappin.and.ellipse").tag(DashboardViewMode.byStation)
                Label("按車站名稱", systemImage: "building.2.crop.circle").tag(DashboardViewMode.byStationName)
                Label("全部路線", systemImage: "list.bullet").tag(DashboardViewMode.allBuses)
            }
        } label: {
            Image(systemName: dashboardModeIconName)
                .font(.system(size: 16, weight: .medium))
        }
    }
    
    var dashboardModeIconName: String {
        switch dashboardViewMode {
        case .byStation:
            return "rectangle.grid.1x2"
        case .byStationName:
            return "building.2.crop.circle"
        case .allBuses:
            return "list.bullet"
        }
    }
    
    /// Requests a fresh device location and refreshes nearby stops when a location is already available.
    func refreshLocationAndNearbyStops() {
        locationManager.requestLocation()
        Task {
            if let location = locationManager.location {
                await updateNearbyStops(userLocation: location)
            }
        }
    }
    
    /// Opens the route-detail screen from a search suggestion row.
    ///
    /// - Parameter suggestion: Selected KMB route direction from `searchSuggestions`.
    func openSuggestedRoute(_ suggestion: RouteSuggestion) {
        showCustomKeyboard = false
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            searchText = suggestion.route
            let newDirection = suggestion.bound.uppercased().hasPrefix("O") ? "outbound" : "inbound"
            selectedDirection = newDirection
            isNavigatingToRoute = true
            
            Task {
                await searchRoute(
                    route: suggestion.route.uppercased(),
                    direction: newDirection,
                    company: suggestion.co,
                    findNearest: true,
                    shouldScroll: true
                )
            }
        }
    }
    
    /// Opens the route-detail screen from a nearby dashboard route row.
    ///
    /// - Parameters:
    ///   - route: Route row selected from the nearby dashboard.
    ///   - stopInfo: Dashboard stop used as the target highlight in the timetable.
    func openNearbyDashboardRoute(_ route: NearbyRouteModel, stopInfo: StopInfo) {
        let newDirection = route.directionCode == "O" ? "outbound" : "inbound"
        selectedDirection = newDirection
        searchText = route.route
        isNavigatingToRoute = true
        
        Task {
            await searchRoute(
                route: route.route,
                direction: newDirection,
                company: route.co,
                findNearest: false,
                targetStopCode: stopInfo.stop,
                shouldScroll: true
            )
        }
    }
    
    /// Fills the pending timer fields before showing the confirmation alert.
    ///
    /// - Parameters:
    ///   - route: KMB route number selected by the user.
    ///   - destination: Route destination shown in the alert and Live Activity.
    ///   - stationName: Stop name shown in the alert and Live Activity.
    ///   - stopId: KMB stop id used for future ETA refreshes.
    ///   - direction: KMB API direction string, either `outbound` or `inbound`.
    ///   - etaDate: ETA that the user wants to track.
    func prepareTimerAlert(route: String, destination: String, stationName: String, stopId: String, direction: String, company: String = BusOperator.kmb.rawValue, etaDate: Date) {
        timerTargetDate = etaDate
        timerRouteName = route.uppercased()
        timerCompany = company
        timerStationName = stationName
        timerStopId = stopId
        timerDirection = direction
        timerDestination = destination
        showingAddTimerAlert = true
    }
}
