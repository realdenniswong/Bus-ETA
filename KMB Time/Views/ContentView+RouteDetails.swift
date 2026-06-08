import SwiftUI

extension ContentView {
    var routeDetailView: some View {
        ScrollViewReader { routeProxy in
            ZStack {
                List {
                    directionPicker
                    timetableSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(themeBackground)
                
                routeDetailOverlay
            }
            .navigationTitle(routeDetailNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { routeDetailToolbar }
            .onChange(of: scrollTriggerId) { _ in
                scrollToHighlightedStop(using: routeProxy)
            }
        }
    }
    
    var routeDetailNavigationTitle: String {
        guard !searchText.isEmpty else { return "路線資料" }
        return "\(searchText.uppercased()) · \(routeDetailCompanyName)"
    }
    
    var routeDetailCompanyName: String {
        switch selectedCompany {
        case "KMB+CTB":
            return "聯營"
        case BusOperator.ctb.rawValue:
            return "城巴"
        default:
            return "九巴"
        }
    }
    
    var directionPicker: some View {
        Picker("Direction", selection: $selectedDirection) {
            Text("去程 (Outbound)").tag("outbound")
            Text("回程 (Inbound)").tag("inbound")
        }
        .pickerStyle(.segmented)
        .padding(.top, 12)
        .onChange(of: selectedDirection) { newValue in
            if !searchText.isEmpty {
                Task { await searchRoute(route: searchText.uppercased(), direction: newValue, company: selectedCompany, findNearest: true, shouldScroll: true) }
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
    
    var timetableSection: some View {
        TimetableSectionView(
            displayData: displayData,
            highlightedStopId: highlightedStopId,
            currentTime: currentTime,
            onSetTimer: { stop, etaDate in
                prepareRouteDetailTimerAlert(stop: stop, etaDate: etaDate)
            }
        )
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
    
    @ViewBuilder
    var routeDetailOverlay: some View {
        if isLoading {
            ProgressView("正在獲取數據...")
        } else if displayData.isEmpty && !searchText.isEmpty {
            Text(systemMessage)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
    }
    
    @ToolbarContentBuilder
    var routeDetailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            favoriteToolbarButton
            refreshRouteButton
        }
    }
    
    var favoriteToolbarButton: some View {
        let isFavorite = favoritesManager.isFavorite(route: searchText.uppercased(), direction: selectedDirection)
        return Button(action: toggleCurrentRouteFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundColor(isFavorite ? .orange : .primary)
        }
    }
    
    @ViewBuilder
    var refreshRouteButton: some View {
        if isLoading {
            ProgressView()
        } else {
            Button(action: {
                Task {
                    await searchRoute(route: searchText.uppercased(), direction: selectedDirection, company: selectedCompany, findNearest: false, shouldScroll: false, isRefresh: true)
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
            }
        }
    }
    
    /// Prepares the reminder alert from a timetable row selected in route detail.
    ///
    /// - Parameters:
    ///   - stop: Timetable stop row selected by the user.
    ///   - etaDate: ETA chosen for reminder tracking.
    func prepareRouteDetailTimerAlert(stop: StopDisplayModel, etaDate: Date) {
        let boundPrefix = selectedDirection == "outbound" ? "O" : "I"
        let matchedRoute = allRoutes.first(where: { $0.route == searchText.uppercased() && $0.bound == boundPrefix })
        
        prepareTimerAlert(
            route: searchText.uppercased(),
            destination: matchedRoute?.destination ?? "終點站",
            stationName: stop.stopNameTc,
            stopId: stop.stopId,
            direction: selectedDirection == "outbound" ? "outbound" : "inbound",
            etaDate: etaDate
        )
    }
    
    /// Adds or removes the currently visible route direction from favourites.
    func toggleCurrentRouteFavorite() {
        let isFavorite = favoritesManager.isFavorite(route: searchText.uppercased(), direction: selectedDirection)
        let boundPrefix = selectedDirection == "outbound" ? "O" : "I"
        let matchedRoute = allRoutes.first(where: { $0.route == searchText.uppercased() && $0.bound == boundPrefix })
        let destination = matchedRoute?.destination ?? "終點站"
        
        favoritesManager.toggleFavorite(route: searchText.uppercased(), direction: selectedDirection, destName: destination)
        showToast(isFavorite ? "已從常用路線移除" : "已加入常用路線")
    }
    
    /// Scrolls the route-detail timetable to the row selected by search, dashboard, or nearest-stop logic.
    ///
    /// - Parameter proxy: `ScrollViewReader` proxy for the route-detail list.
    func scrollToHighlightedStop(using proxy: ScrollViewProxy) {
        guard let target = highlightedStopId else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }
}
