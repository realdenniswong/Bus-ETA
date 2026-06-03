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

// MARK: - User Interface View (Coordinator)
struct ContentView: View {
    @State var searchText = ""
    @State var selectedDirection = "outbound"
    
    @State var stopDictionary: [String: String] = [:]
    @State var stopInfoDictionary: [String: StopInfo] = [:]
    @State var displayData: [StopDisplayModel] = []
    
    @State var allRoutes: [RouteSuggestion] = []
    
    @State var isLoading = false
    @State var systemMessage = "搜尋九巴路線 (例如 1A, 281A)"
    
    @StateObject var locationManager = LocationManager()
    @State var allStops: [StopInfo] = []
    @State var nearbyStops: [NearbyStopModel] = []
    @State var expandedStopIds: Set<String> = []
    @State var isSearchingNearby = false
    
    // 🌟 NEW: Track the user's preferred layout for the dashboard
    @State var dashboardViewMode: DashboardViewMode = .byStation
    
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
    
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    // 1. Native-Looking Custom Search Bar
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(Color(UIColor.systemGray))
                            .font(.system(size: 17))
                        
                        Text(searchText.isEmpty ? "輸入路線 (例如 1A)" : searchText)
                            .foregroundColor(searchText.isEmpty ? Color(UIColor.placeholderText) : .primary)
                            .font(.system(size: 17))
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                    
                    // 2. Active Timer Card View
                    if let timer = activeTimer {
                        ActiveTimerCardView(
                            timer: timer,
                            currentTime: currentTime,
                            onCancel: {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    activeTimer = nil
                                }
                                endLiveActivity()
                                self.locationManager.stopBackgroundTracking()
                                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["KMBTimeAlarm"])
                            }
                        )
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                    
                    // 3. Main Content Sections
                    if showCustomKeyboard && !searchText.isEmpty {
                        SuggestionsSectionView(
                            searchSuggestions: searchSuggestions,
                            onSuggestionTapped: { suggestion in
                                searchText = suggestion.route
                                let isOutbound = suggestion.bound.uppercased().hasPrefix("O")
                                let newDir = isOutbound ? "outbound" : "inbound"
                                
                                withAnimation(.spring()) {
                                    showCustomKeyboard = false
                                }
                                
                                Task { await searchRoute(route: suggestion.route.uppercased(), direction: newDir, findNearest: true, shouldScroll: true) }
                            }
                        )
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        
                    } else if searchText.isEmpty {
                        NearbyDashboardSectionView(
                            locationManager: locationManager,
                            expandedStopIds: $expandedStopIds,
                            viewMode: $dashboardViewMode, // 🌟 NEW: Passing the binding to the sub-view
                            isSearchingNearby: isSearchingNearby,
                            allStops: allStops,
                            nearbyStops: nearbyStops,
                            currentTime: currentTime,
                            onRequestLocation: { locationManager.requestLocation() },
                            onRouteSelected: { route, stopInfo in
                                let newDir = route.directionCode == "O" ? "outbound" : "inbound"
                                selectedDirection = newDir
                                searchText = route.route
                                
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
                            }
                        )
                        
                    } else {
                        Picker("Direction", selection: $selectedDirection) {
                            Text("去程 (Outbound)").tag("outbound")
                            Text("回程 (Inbound)").tag("inbound")
                        }
                        .pickerStyle(.segmented)
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
                            currentTime: currentTime
                        )
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(themeBackground)
                .listSectionSpacing(.custom(16))
                
                // 4. Custom Keyboard Overlay
                .overlay(alignment: .bottom) {
                    if showCustomKeyboard {
                        CustomKeyboardView(
                            text: $searchText,
                            validKeys: validNextKeys,
                            onSearch: {
                                showCustomKeyboard = false
                                Task { await searchRoute(route: searchText.uppercased(), direction: selectedDirection, findNearest: true, shouldScroll: true) }
                            },
                            onDismiss: {
                                withAnimation(.spring()) { showCustomKeyboard = false }
                            }
                        )
                        .transition(.move(edge: .bottom))
                    }
                }
                .navigationTitle(searchText.isEmpty ? "九巴到站預報" : (showCustomKeyboard ? "搜尋路線" : "路線資料"))
                .navigationBarTitleDisplayMode(.large)
                .overlay {
                    if !showCustomKeyboard {
                        if isLoading {
                            ProgressView("正在獲取數據...")
                        } else if displayData.isEmpty && !searchText.isEmpty {
                            Text(systemMessage)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                }
                .toolbar {
                    if !searchText.isEmpty {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button(action: {
                                searchText = ""
                                displayData = []
                                highlightedStopId = nil
                                withAnimation { showCustomKeyboard = false }
                                
                                if let loc = self.locationManager.location {
                                    Task { await updateNearbyStops(userLocation: loc) }
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .fontWeight(.bold)
                                    Text("返回")
                                }
                            }
                        }
                    }
                }
                .onReceive(refreshTimer) { _ in
                    Task {
                        if activeTimer != nil { await syncActiveTimer() }
                        if searchText.isEmpty {
                            if let location = locationManager.location {
                                await updateNearbyStops(userLocation: location)
                            }
                        } else if !displayData.isEmpty && !showCustomKeyboard {
                            await searchRoute(route: searchText.uppercased(), direction: selectedDirection, findNearest: false, shouldScroll: false, isRefresh: true)
                        }
                    }
                }
                .onReceive(clockTimer) { _ in
                    currentTime = Date()
                    if let timer = activeTimer {
                        let secondsLeft = timer.etaDate.timeIntervalSince(currentTime)
                        if secondsLeft <= -10 {
                            print("🐛 [背景擊殺] 巴士已過站，啟動自動收屍程序...")
                            activeTimer = nil
                            endLiveActivity()
                            self.locationManager.stopBackgroundTracking()
                            print("🐛 [背景擊殺] 成功殺死卡片並關閉定位更新，App 已回歸 0 耗電深層睡眠狀態。")
                        }
                    }
                }
                .onChange(of: scrollTriggerId) { _ in
                    if let target = highlightedStopId {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                }
                .alert("設定巴士抵站提醒", isPresented: $showingAddTimerAlert) {
                    Button("設定提醒", role: .none) {
                        if let etaDate = timerTargetDate {
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
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("您是否要為 \(timerRouteName) 路線設定提醒？系統將在巴士預計抵達前 2 分鐘（即 \(formattedTime(timerTargetDate?.addingTimeInterval(-120) ?? Date()))）提醒您。")
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
                            print("🐛 [深層睡眠心跳扣殺] 褲袋擊殺觸發！執行收屍任務...")
                            withAnimation { activeTimer = nil }
                            endLiveActivity()
                            self.locationManager.stopBackgroundTracking()
                        }
                    }
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        print("🐛 [DEBUG] App 返到前景！即刻檢查有冇死屍卡片...")
                        reconnectActiveLiveActivity()
                    }
                }
            }
        }
    }
    
    var themeBackground: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
}
