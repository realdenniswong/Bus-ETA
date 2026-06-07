//
//  ContentView.swift
//  KMB Time
//
//  Created by Dennis Wong on 6/4/26.
//

import SwiftUI
import CoreLocation
import Combine
import UserNotifications
import ActivityKit

// MARK: - Models
struct FavoriteETA {
    let stopName: String
    let etaDate: Date?
}

// MARK: - View Modes
enum DashboardViewMode {
    case byStation
    case byStationName
    case allBuses
}

// MARK: - User Interface View (Coordinator)
struct ContentView: View {
    @State var selectedTab = 0 // 🌟 NEW: Track current tab for navigation
    
    @State var searchText = ""
    @State var selectedDirection = "outbound"
    @State var selectedCompany = "KMB" // 🌟 NEW: 記錄目前選擇的巴士公司
    
    @State var stopDictionary: [String: String] = [:]
    @State var stopInfoDictionary: [String: StopInfo] = [:]
    @State var displayData: [StopDisplayModel] = []
    
    @State var allRoutes: [RouteSuggestion] = []
    
    @State var isLoading = false
    @State var systemMessage = "搜尋九巴路線 (例如 1A, 281A)"
    
    @StateObject var locationManager = LocationManager()
    @StateObject var favoritesManager = FavoritesManager()
    
    @State var allStops: [StopInfo] = []
    @State var nearbyStops: [NearbyStopModel] = []
    @State var expandedStopIds: Set<String> = []
    @State var isSearchingNearby = false
    
    @State var dashboardViewMode: DashboardViewMode = .allBuses
    
    @State var timerStationName = ""
    
    let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State var currentTime = Date()
    
    @State var activeTimer: ActiveTimerModel? = nil
    @State var showingAddTimerAlert = false
    @State var timerTargetDate: Date? = nil
    @State var timerRouteName = ""
    @State var timerDestination = ""
    @State var timerStopId = ""
    @State var timerDirection = ""
    
    @State var highlightedStopId: String? = nil
    @State var scrollTriggerId: UUID = UUID()
    
    @State var showCustomKeyboard = false
    
    @State var isNavigatingToRoute = false
    @State var dashboardScrollTarget: String? = nil
    
    @State private var toastMessage: String? = nil // 🌟 NEW: Toast state
    
    @Environment(\.scenePhase) var scenePhase
    
    var searchSuggestions: [RouteSuggestion] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.uppercased()
        return allRoutes.filter { $0.route.uppercased().hasPrefix(query) }.prefix(30).map { $0 }
    }
    
    var validNextKeys: Set<String>? {
        guard !allRoutes.isEmpty else { return nil }
        
        let query = searchText.uppercased()
        if query.isEmpty { return Set(allRoutes.compactMap { $0.route.first.map(String.init) }) }
        
        var nextKeys = Set<String>()
        for suggestion in allRoutes {
            let route = suggestion.route.uppercased()
            if route.hasPrefix(query) && route.count > query.count {
                let index = route.index(route.startIndex, offsetBy: query.count)
                nextKeys.insert(String(route[index]))
            }
        }
        return nextKeys
    }
    
    init() {
        UISegmentedControl.appearance().backgroundColor = .clear
    }
    
    private func dismissKeyboardSafe() {
        withAnimation(.spring()) { showCustomKeyboard = false }
        // 🛑 Removed the code that clears `searchText`.
        // Now the user keeps their search query when scrolling to dismiss!
    }
    
    var themeBackground: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
    
    private func showToast(_ message: String) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        withAnimation(.spring()) {
            self.toastMessage = message
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring()) {
                if self.toastMessage == message {
                    self.toastMessage = nil
                }
            }
        }
    }
    
    // MARK: - Main Body
    var body: some View {
        TabView(selection: $selectedTab) {
            mainDashboardTab
                .tag(0)
            favoritesTab
                .tag(1)
        }
        .alert(activeTimer == nil ? "設定巴士抵站提醒" : "替換巴士抵站提醒", isPresented: $showingAddTimerAlert) {
            alertButtons
        } message: {
            alertMessage
        }
        .overlay(alignment: .top) {
            if let message = toastMessage {
                Text(message)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color(white: 0.15, opacity: 0.95))
                    .cornerRadius(25)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 16)
                    .zIndex(1)
            }
        }
        .environmentObject(favoritesManager)
    }
}

// MARK: - Tabs
extension ContentView {
    private var mainDashboardTab: some View {
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
                    searchText = ""
                    displayData = []
                    highlightedStopId = nil
                    showCustomKeyboard = false
                    
                    if let loc = self.locationManager.location {
                        Task { await updateNearbyStops(userLocation: loc) }
                    }
                }
            }
            .onReceive(refreshTimer) { _ in
                Task {
                    if activeTimer != nil { await syncActiveTimer() }
                    
                    // Dashboard Auto-refresh (只限於路線詳情頁時重新載入)
                    if selectedTab == 0 {
                        if isNavigatingToRoute && !displayData.isEmpty && !showCustomKeyboard {
                            await searchRoute(route: searchText.uppercased(), direction: selectedDirection, findNearest: false, shouldScroll: false, isRefresh: true)
                        }
                    }
                }
            }
            .onReceive(clockTimer) { _ in
                currentTime = Date()
                if let timer = activeTimer {
                    let secondsLeft = timer.etaDate.timeIntervalSince(currentTime)
                    if secondsLeft <= -10 {
                        activeTimer = nil
                        endLiveActivity()
                        self.locationManager.stopBackgroundTracking()
                    }
                }
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
            .onChange(of: locationManager.location) { oldValue, newValue in
                if let location = newValue, !locationManager.isBackgroundTracking {
                    Task { await updateNearbyStops(userLocation: location) }
                }
            }
            .onChange(of: locationManager.backgroundHeartbeat) { oldValue, newValue in
                if let timer = activeTimer {
                    let secondsLeft = timer.etaDate.timeIntervalSince(Date())
                    if secondsLeft <= -10 {
                        withAnimation { activeTimer = nil }
                        endLiveActivity()
                        self.locationManager.stopBackgroundTracking()
                    }
                }
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    reconnectActiveLiveActivity()
                    locationManager.requestLocation()
                    if !isNavigatingToRoute {
                        Task {
                            if let loc = locationManager.location {
                                await updateNearbyStops(userLocation: loc)
                            }
                        }
                    }
                }
            }
        }
        //當 showCustomKeyboard 係 true 嗰陣隱藏 Tab Bar
        .toolbar(showCustomKeyboard ? .hidden : .visible, for: .tabBar)
        //加個動畫令 Tab Bar 消失/出現嗰陣順滑啲
        .animation(.easeInOut(duration: 0.2), value: showCustomKeyboard)
        .tabItem {
            Label("到站預報", systemImage: "bus.fill")
        }
    }
    
    private var favoritesTab: some View {
            NavigationStack {
                List {
                    if favoritesManager.favoriteRoutes.isEmpty {
                        Text("您尚未加入任何常用路線。")
                            .foregroundColor(.secondary)
                            .padding()
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(favoritesManager.favoriteRoutes) { fav in
                            Button(action: {
                                selectedTab = 0
                                
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    searchText = fav.route
                                    selectedDirection = fav.direction
                                    isNavigatingToRoute = true
                                    Task { await searchRoute(route: fav.route, direction: fav.direction, findNearest: true, shouldScroll: true) }
                                }
                            }) {
                                HStack(alignment: .center, spacing: 12) {
                                    Text(fav.route)
                                        .font(.system(.body, design: .rounded))
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.5)
                                        .frame(width: 64, height: 36)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.65, green: 0.08, blue: 0.12)))
                                    
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                                            Text("往")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Text(fav.destNameTc)
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    // 🌟 完全移除 ETA UI 與載入狀態
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
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
                // 🌟 移除了 .toolbar, .onReceive, .onAppear, .onChange, .refreshable 中關於 ETA 更新的代碼
            }
            .tabItem {
                Label("常用路線", systemImage: "star.fill")
            }
        }
}

// MARK: - Dashboard Components
extension ContentView {
    private var dashboardContentView: some View {
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
            if showCustomKeyboard { customKeyboardOverlay }
        }
        .navigationTitle(showCustomKeyboard ? "搜尋路線" : "九巴到站預報")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { dashboardToolbar }
    }
    
    private var searchBarView: some View {
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
            withAnimation(.spring()) { showCustomKeyboard = true }
        }
    }
    
    private func activeTimerCardView(timer: ActiveTimerModel) -> some View {
        ActiveTimerCardView(
            timer: timer,
            currentTime: currentTime,
            onCancel: {
                withAnimation(.easeInOut(duration: 0.3)) { activeTimer = nil }
                endLiveActivity()
                self.locationManager.stopBackgroundTracking()
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["KMBTimeAlarm"])
            }
        )
        .id("ActiveTimerCard")
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
    
    private var suggestionsSectionView: some View {
        SuggestionsSectionView(
            searchSuggestions: searchSuggestions,
            onSuggestionTapped: { suggestion in
                showCustomKeyboard = false
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    searchText = suggestion.route
                    selectedCompany = suggestion.co // 🌟 記住用戶點擊的是城巴還是九巴
                    
                    let isOutbound = suggestion.bound.uppercased().hasPrefix("O")
                    let newDir = isOutbound ? "outbound" : "inbound"
                    
                    selectedDirection = newDir
                    isNavigatingToRoute = true
                    
                    // 🌟 將公司 (company) 傳入搜尋函數中
                    Task { await searchRoute(route: suggestion.route.uppercased(), direction: newDir, company: suggestion.co, findNearest: true, shouldScroll: true) }
                }
            }
        )
    }
    
    private var nearbyDashboardSectionView: some View {
        NearbyDashboardSectionView(
            locationManager: locationManager,
            expandedStopIds: $expandedStopIds,
            viewMode: $dashboardViewMode,
            allStops: allStops,
            nearbyStops: nearbyStops,
            currentTime: currentTime,
            onRequestLocation: { locationManager.requestLocation() },
            onRouteSelected: { route, stopInfo in
                let newDir = route.directionCode == "O" ? "outbound" : "inbound"
                selectedDirection = newDir
                searchText = route.route
                
                isNavigatingToRoute = true
                Task { await searchRoute(route: route.route, direction: newDir, findNearest: false, targetStopCode: stopInfo.stop, shouldScroll: true) }
            },
            onSetTimer: { route, stopInfo in
                timerTargetDate = route.etas.first?.etaDate
                timerRouteName = route.route
                timerDestination = route.destNameTc
                timerStationName = stopInfo.name_tc
                timerStopId = stopInfo.stop
                timerDirection = route.directionCode == "O" ? "outbound" : "inbound"
                showingAddTimerAlert = true
            },
            onShowToast: { message in
                showToast(message)
            }
        )
    }
    
    private var customKeyboardOverlay: some View {
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
    private var dashboardToolbar: some ToolbarContent {
        if !showCustomKeyboard {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isSearchingNearby {
                    ProgressView()
                } else {
                    Button(action: {
                        locationManager.requestLocation()
                        Task {
                            if let loc = locationManager.location {
                                await updateNearbyStops(userLocation: loc)
                            }
                        }
                    }) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .medium))
                    }
                }
                
                if !nearbyStops.isEmpty {
                    Menu {
                        Picker("顯示模式", selection: $dashboardViewMode) {
                            Label("按巴士站", systemImage: "mappin.and.ellipse").tag(DashboardViewMode.byStation)
                            Label("按車站名稱", systemImage: "building.2.crop.circle").tag(DashboardViewMode.byStationName)
                            Label("全部路線", systemImage: "list.bullet").tag(DashboardViewMode.allBuses)
                        }
                    } label: {
                        Image(systemName: dashboardViewMode == .byStation ? "rectangle.grid.1x2" : (dashboardViewMode == .byStationName ? "building.2.crop.circle" : "list.bullet"))
                            .font(.system(size: 16, weight: .medium))
                    }
                }
            }
        }
    }
}

// MARK: - Route Details
extension ContentView {
    private var routeDetailView: some View {
        ScrollViewReader { routeProxy in
            ZStack {
                List {
                    Picker("Direction", selection: $selectedDirection) {
                        Text("去程 (Outbound)").tag("outbound")
                        Text("回程 (Inbound)").tag("inbound")
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 12)
                    .onChange(of: selectedDirection) { newValue in
                        if !searchText.isEmpty {
                            Task { await searchRoute(route: searchText.uppercased(), direction: newValue, findNearest: true, shouldScroll: true) }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    
                    TimetableSectionView(
                        displayData: displayData,
                        highlightedStopId: highlightedStopId,
                        currentTime: currentTime,
                        onSetTimer: { stop, etaDate in
                            timerTargetDate = etaDate
                            timerRouteName = searchText.uppercased()
                            timerStationName = stop.stopNameTc
                            timerStopId = stop.stopId
                            timerDirection = selectedDirection == "outbound" ? "outbound" : "inbound"
                            
                            let boundPrefix = selectedDirection == "outbound" ? "O" : "I"
                            let matchedRoute = allRoutes.first(where: { $0.route == timerRouteName && $0.bound == boundPrefix })
                            timerDestination = matchedRoute?.destination ?? "終點站"
                            
                            showingAddTimerAlert = true
                        }
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(themeBackground)
                
                if isLoading {
                    ProgressView("正在獲取數據...")
                } else if displayData.isEmpty && !searchText.isEmpty {
                    Text(systemMessage)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .navigationTitle(searchText.isEmpty ? "路線資料" : searchText.uppercased())
            .navigationBarTitleDisplayMode(.inline)
            
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    let isFav = favoritesManager.isFavorite(route: searchText.uppercased(), direction: selectedDirection)
                    Button(action: {
                        let boundPrefix = selectedDirection == "outbound" ? "O" : "I"
                        let matchedRoute = allRoutes.first(where: { $0.route == searchText.uppercased() && $0.bound == boundPrefix })
                        let dest = matchedRoute?.destination ?? "終點站"
                        
                        favoritesManager.toggleFavorite(route: searchText.uppercased(), direction: selectedDirection, destName: dest)
                        showToast(isFav ? "已從常用路線移除" : "已加入常用路線")
                    }) {
                        Image(systemName: isFav ? "star.fill" : "star")
                            .foregroundColor(isFav ? .orange : .primary)
                    }
                    
                    if isLoading {
                        ProgressView()
                    } else {
                        Button(action: {
                            Task {
                                await searchRoute(route: searchText.uppercased(), direction: selectedDirection, findNearest: false, shouldScroll: false, isRefresh: true)
                            }
                        }) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .medium))
                        }
                    }
                }
            }
            .onChange(of: scrollTriggerId) { _ in
                if let target = highlightedStopId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                            routeProxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Alerts
extension ContentView {
    @ViewBuilder
    private var alertButtons: some View {
        Button(activeTimer == nil ? "設定提醒" : "確認替換", role: .none) {
            if let etaDate = timerTargetDate {
                if activeTimer != nil { endLiveActivity() }
                
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    if granted {
                        scheduleLocalNotification(
                            routeName: timerRouteName,
                            destination: timerDestination,
                            alertDate: etaDate.addingTimeInterval(-120)
                        )
                    }
                }
                
                startLiveActivity(routeName: timerRouteName, destination: timerDestination, stationName: timerStationName, etaDate: etaDate, startTime: Date())
                self.locationManager.startBackgroundTracking()
                withAnimation {
                    activeTimer = ActiveTimerModel(
                        routeName: timerRouteName,
                        destination: timerDestination,
                        etaDate: etaDate,
                        targetAlertDate: etaDate.addingTimeInterval(-120),
                        startTime: Date(),
                        stopId: timerStopId,
                        direction: timerDirection,
                        stationName: timerStationName
                    )
                }
                
                isNavigatingToRoute = false
                dashboardScrollTarget = "ActiveTimerCard"
            }
        }
        Button("取消", role: .cancel) {}
    }
    
    @ViewBuilder
    private var alertMessage: some View {
        if let existing = activeTimer {
            Text("您目前已為 \(existing.routeName) 設定了提醒。確定要取消舊提醒，並為 \(timerRouteName) 重新設定嗎？\n\n系統將在巴士預計抵達前 2 分鐘（即 \(formattedTime(timerTargetDate?.addingTimeInterval(-120) ?? Date()))）提醒您。")
        } else {
            Text("您是否要為 \(timerRouteName) 路線設定提醒？\n\n系統將在巴士預計抵達前 2 分鐘（即 \(formattedTime(timerTargetDate?.addingTimeInterval(-120) ?? Date()))）提醒您。")
        }
    }
}
