//
//  ContentView.swift
//  KMB Time
//
//  Created by Dennis Wong on 5/31/26.
//

import SwiftUI
import CoreLocation
import Combine
import UserNotifications
import ActivityKit

// MARK: - Data Models
struct StopResponse: Codable { let data: [StopInfo] }
struct StopInfo: Codable {
    let stop: String
    let name_tc: String
    let lat: String?
    let long: String?
}

extension StopInfo {
    var clLocation: CLLocation? {
        guard let latStr = lat, let longStr = long,
              let latitude = Double(latStr), let longitude = Double(longStr) else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
}

struct RouteStopResponse: Codable { let data: [RouteStop] }
struct RouteStop: Codable {
    let seq: String
    let stop: String
}

struct ETAResponse: Codable { let data: [ETAItem] }
struct ETAItem: Codable {
    let seq: Int
    let dir: String
    let eta: String?
    let rmk_tc: String?
}

struct ETADisplayInfo: Identifiable, Hashable {
    let id = UUID()
    let etaDate: Date?
    let remark: String?
}

struct StopDisplayModel: Identifiable {
    // Deterministic ID ensures background refreshes don't break the active scroll position
    var id: String { "\(seq)-\(stopId)" }
    let seq: Int
    let stopId: String
    let stopNameTc: String
    let etas: [ETADisplayInfo]
}

struct NearbyStopModel: Identifiable {
    let id = UUID()
    let stopInfo: StopInfo
    let distance: CLLocationDistance
    var routes: [NearbyRouteModel] = []
}

struct NearbyRouteModel: Identifiable {
    let id = UUID()
    let route: String
    let directionCode: String // "O" or "I"
    let destNameTc: String
    let etas: [ETADisplayInfo]
}

struct StopETAResponse: Codable {
    let data: [StopETAItem]
}

struct StopETAItem: Codable {
    let co: String
    let route: String
    let dir: String
    let service_type: Int
    let dest_tc: String
    let eta_seq: Int
    let eta: String?
    let rmk_tc: String?
}

// MARK: - Route Suggestion Models
struct AllRoutesResponse: Codable { let data: [RouteItem] }
struct RouteItem: Codable {
    let route: String
    let bound: String    // "O" (Outbound) or "I" (Inbound)
    let orig_tc: String  // Origin Station
    let dest_tc: String  // Destination Station
}

struct RouteSuggestion: Hashable {
    let route: String
    let bound: String
    let origin: String
    let destination: String
}

// MARK: - User Interface
struct ContentView: View {
    @State private var searchText = ""
    @State private var selectedDirection = "outbound" // Tracks the selected direction
    
    @State private var stopDictionary: [String: String] = [:]
    @State private var stopInfoDictionary: [String: StopInfo] = [:]
    @State private var displayData: [StopDisplayModel] = []
    
    // Auto-complete variables
    @State private var allRoutes: [RouteSuggestion] = []
    
    @State private var isLoading = false
    @State private var systemMessage = "搜尋九巴路線 (例如 1A, 281A)"
    
    // Nearby Location States
    @StateObject private var locationManager = LocationManager()
    @State private var allStops: [StopInfo] = []
    @State private var nearbyStops: [NearbyStopModel] = []
    @State private var expandedStopIds: Set<String> = []
    @State private var isSearchingNearby = false
    
    @State private var timerStationName = ""
    
    // Auto-refresh timer to keep ETA countdowns fresh (ticks every 30 seconds)
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    
    // Local clock timer to update countdowns smoothly (ticks every 1 second)
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var currentTime = Date()
    
    // Active Timer and Alert States
    @State private var activeTimer: ActiveTimerModel? = nil
    @State private var showingAddTimerAlert = false
    @State private var showingTimerCompletedAlert = false
    @State private var timerTargetDate: Date? = nil
    @State private var timerRouteName = ""
    @State private var timerDestination = ""
    
    // Track the targeted/closest station for highlighting & auto-scrolling
    @State private var highlightedStopId: String? = nil
    @State private var scrollTriggerId: UUID = UUID()
    
    // Custom Keyboard State
    @State private var showCustomKeyboard = false
    
    // Computed property to filter routes for auto-complete suggestions
    var searchSuggestions: [RouteSuggestion] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.uppercased()
        return allRoutes.filter { $0.route.uppercased().hasPrefix(query) }.prefix(30).map { $0 }
    }
    
    // 放入 searchSuggestions 下面
    var validNextKeys: Set<String>? {
        // 如果 API 未 load 完或者失敗，回傳 nil 代表「全部按鍵皆可按」
        guard !allRoutes.isEmpty else { return nil }
        
        let query = searchText.uppercased()
        
        // 如果未入任何字，就抽哂所有路線嘅第一個字出嚟
        if query.isEmpty {
            return Set(allRoutes.compactMap { $0.route.first.map(String.init) })
        }
        
        var nextKeys = Set<String>()
        for suggestion in allRoutes {
            let route = suggestion.route.uppercased()
            if route.hasPrefix(query) && route.count > query.count {
                // 搵出 Prefix 之後緊接住嗰個字元
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

                        // 2. Active Timer Card
                        if let timer = activeTimer {
                            activeTimerCard(timer: timer)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                        }
                        
                        // 3. Main Content Sections
                        if showCustomKeyboard && !searchText.isEmpty {
                            // SHOW SUGGESTIONS LIST WHILE TYPING
                            suggestionsSection
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                            
                        } else if searchText.isEmpty {
                            // SHOW NEARBY DASHBOARD
                            nearbyDashboardSection
                            
                        } else {
                            // SHOW TIMETABLE RESULTS
                            Picker("Direction", selection: $selectedDirection) {
                                Text("去程 (Outbound)").tag("outbound")
                                Text("回程 (Inbound)").tag("inbound")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: selectedDirection) { _ in
                                if !searchText.isEmpty {
                                    Task {
                                        await searchRoute(route: searchText.uppercased(), findNearest: true, shouldScroll: true)
                                    }
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            
                            timetableSection
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(themeBackground)
                    .listSectionSpacing(.custom(16))
                    
                    // 4. Custom Keyboard Overlay & Modifiers
                    .overlay(alignment: .bottom) {
                        if showCustomKeyboard {
                            CustomKeyboardView(
                                text: $searchText,
                                validKeys: validNextKeys, // <--- 加入呢行
                                onSearch: {
                                    showCustomKeyboard = false
                                    Task { await searchRoute(route: searchText.uppercased(), findNearest: true, shouldScroll: true) }
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
                            if searchText.isEmpty {
                                if let location = locationManager.location {
                                    await updateNearbyStops(userLocation: location)
                                }
                            } else if !displayData.isEmpty && !showCustomKeyboard {
                                // Background refresh - preserve highlight but do not scroll again
                                await searchRoute(route: searchText.uppercased(), findNearest: false, shouldScroll: false)
                            }
                        }
                    }
                    .onReceive(clockTimer) { _ in
                        currentTime = Date()
                        if let timer = activeTimer {
                            let secondsLeft = timer.targetAlertDate.timeIntervalSince(currentTime)
                            if secondsLeft <= 0 {
                                let generator = UINotificationFeedbackGenerator()
                                generator.notificationOccurred(.success)
                                showingTimerCompletedAlert = true
                                activeTimer = nil
                                endLiveActivity()
                                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["KMBTimeAlarm"])
                            }
                        }
                    }
                    // MARK: 🐛 DEBUG Scroll Trigger
                    .onChange(of: scrollTriggerId) { _ in
                        if let target = highlightedStopId {
                            // 只需單次延遲 0.3 秒，等 UI 畫好就觸發平滑捲動
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
                                
                                withAnimation {
                                    activeTimer = ActiveTimerModel(
                                        routeName: timerRouteName,
                                        destination: timerDestination,
                                        etaDate: etaDate,
                                        targetAlertDate: etaDate.addingTimeInterval(-120),
                                        startTime: Date()
                                    )
                                }
                            }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("您是否要為 \(timerRouteName) 路線設定提醒？系統將在巴士預計抵達前 2 分鐘（即 \(formattedTime(timerTargetDate?.addingTimeInterval(-120) ?? Date()))）提醒您。")
                    }
                    .alert("巴士即將抵達！", isPresented: $showingTimerCompletedAlert) {
                        Button("好", role: .cancel) {}
                    } message: {
                        Text("您設定的巴士即將在 2 分鐘內抵達，請準備上車。")
                    }
                    .task {
                        await loadAllStops()
                        await loadAllRoutes()
                        if locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways {
                            locationManager.requestLocation()
                        }
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
                    }
                    .onChange(of: locationManager.location) { _ in
                        if let location = locationManager.location {
                            Task {
                                await updateNearbyStops(userLocation: location)
                            }
                        }
                    }
                }
            }
        }
    
    // MARK: - Core Theme Background
    private var themeBackground: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
    
    // MARK: - Auto-complete Suggestions Section (IN-PAGE)
    @ViewBuilder
    private var suggestionsSection: some View {
        VStack(spacing: 0) {
            if searchSuggestions.isEmpty {
                HStack {
                    Spacer()
                    Text("找不到相關路線")
                        .foregroundColor(.secondary)
                        .padding(.vertical, 30)
                    Spacer()
                }
            } else {
                ForEach(searchSuggestions, id: \.self) { suggestion in
                    Button(action: {
                        // Apply selection and close keyboard
                        searchText = suggestion.route
                        selectedDirection = suggestion.bound == "O" ? "outbound" : "inbound"
                        
                        withAnimation(.spring()) {
                            showCustomKeyboard = false
                        }
                        
                        Task {
                            await searchRoute(route: suggestion.route.uppercased(), findNearest: true, shouldScroll: true)
                        }
                    }) {
                        HStack(spacing: 16) {
                            Text(suggestion.route)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .frame(width: 52, height: 32)
                                .background(Color(red: 0.65, green: 0.08, blue: 0.12))
                                .cornerRadius(8)
                            
                            HStack(spacing: 6) {
                                Text(suggestion.origin)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .layoutPriority(1)
                                
                                Text(suggestion.destination)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            
                            Spacer(minLength: 4)
                            
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14))
                                .foregroundColor(Color(UIColor.tertiaryLabel))
                                .layoutPriority(1)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    
                    if suggestion != searchSuggestions.last {
                        Divider()
                            .padding(.leading, 84)
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
    }
    
    // MARK: - Timetable Route Content Section
    private var timetableSection: some View {
        Group {
            if !displayData.isEmpty {
                // 1. 拆除 VStack，改用 Section！等 List 知道每個站都係獨立嘅 Row
                Section {
                    ForEach(Array(displayData.enumerated()), id: \.element.id) { index, stop in
                        let isHighlighted = stop.id == highlightedStopId
                        
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(isHighlighted ? Color.blue : Color(red: 0.65, green: 0.08, blue: 0.12))
                                    .frame(width: isHighlighted ? 16 : 12, height: isHighlighted ? 16 : 12)
                                    .padding(.top, isHighlighted ? 4 : 6)
                                
                                if index < displayData.count - 1 {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.3))
                                        .frame(width: 2)
                                        .frame(maxHeight: .infinity)
                                }
                            }
                            .frame(width: 20)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(stop.seq). \(stop.stopNameTc)")
                                        .font(isHighlighted ? .title3 : .headline)
                                        .fontWeight(isHighlighted ? .black : .semibold)
                                        .foregroundColor(isHighlighted ? .blue : .primary)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(0..<3, id: \.self) { etaIndex in
                                        let etaInfo = etaIndex < stop.etas.count ? stop.etas[etaIndex] : nil
                                        if let etaInfo = etaInfo, let etaDate = etaInfo.etaDate {
                                            let secondsLeft = etaDate.timeIntervalSince(currentTime)
                                            let remark = etaInfo.remark ?? ""
                                            let formattedRemark = remark.isEmpty ? "" : " (\(remark))"
                                            
                                            if secondsLeft < 120 {
                                                Text("即將抵達\(formattedRemark)")
                                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                                    .foregroundColor(.green)
                                            } else {
                                                let minutesLeft = Int(secondsLeft / 60)
                                                Text("\(minutesLeft) 分鐘\(formattedRemark)")
                                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    .foregroundColor(.primary)
                                            }
                                        } else {
                                            Text("-")
                                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                .foregroundColor(.primary)
                                        }
                                    }
                                }
                            }
                            // 保持站與站之間嘅距離，灰線會自動穿透呢個空間
                            .padding(.bottom, index < displayData.count - 1 ? 20 : 0)
                            
                            Spacer(minLength: 0)
                        }
                        // 為 Section 嘅第一行同最後一行加返頂/底 Padding，扮返原本卡片嘅邊界
                        .padding(.top, index == 0 ? 16 : 0)
                        .padding(.bottom, index == displayData.count - 1 ? 16 : 0)
                        
                        // 2. 將 .id 放喺呢度！而家佢係 List 認可嘅獨立 Row ID
                        .id(stop.id)
                        
                        // 3. 消除預設 Row 邊距，等灰線完美連接
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color(.secondarySystemGroupedBackground))
                    }
                }
            }
        }
    }
    
    // MARK: - Nearby Dashboard View
    @ViewBuilder
    private var nearbyDashboardSection: some View {
        HStack {
            Text("附近巴士站")
                .font(.title2)
                .fontWeight(.bold)
            
            Spacer()
            
            if isSearchingNearby {
                ProgressView()
            } else if locationManager.location != nil {
                Button(action: {
                    locationManager.requestLocation()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, -10)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        
        let status = locationManager.authorizationStatus
        
        if status == .notDetermined {
            VStack(alignment: .center, spacing: 12) {
                Image(systemName: "location.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .foregroundColor(.blue)
                    .padding(.top, 10)
                
                Text("尋找附近巴士站及抵達時間")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text("啟用定位權限，系統會自動探索您目前位置附近的巴士站與即時路線資訊。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                
                Button(action: {
                    locationManager.requestLocation()
                }) {
                    Text("分享目前位置")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(colors: [Color.blue, Color.cyan], startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(12)
                        .shadow(color: Color.blue.opacity(0.3), radius: 6, x: 0, y: 3)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(14)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } else if status == .denied || status == .restricted {
            VStack(alignment: .center, spacing: 12) {
                Image(systemName: "location.slash.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .foregroundColor(.red)
                    .padding(.top, 10)
                
                Text("定位權限已關閉")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text("如欲使用此定位功能，請至系統設定開啟此應用的定位服務。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                
                Button(action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }) {
                    Text("開啟系統設定")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(14)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } else {
            if locationManager.location == nil || allStops.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(allStops.isEmpty ? "正在載入巴士站數據庫..." : "正在尋找您的位置...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 250)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if nearbyStops.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mappin.slash")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("附近未發現巴士站。")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                ForEach(nearbyStops) { stopModel in
                    let isExpanded = expandedStopIds.contains(stopModel.stopInfo.stop)
                    
                    Section {
                        Button(action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                toggleStopExpanded(stopModel.stopInfo.stop)
                            }
                        }) {
                            HStack(alignment: .center) {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundColor(.red)
                                    .font(.headline)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stopModel.stopInfo.name_tc)
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                        .multilineTextAlignment(.leading)
                                }
                                
                                Spacer()
                                
                                HStack(spacing: 12) {
                                    Text(formatDistance(stopModel.distance))
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.12))
                                        .foregroundColor(.blue)
                                        .cornerRadius(6)
                                    
                                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        
                        if isExpanded {
                            if stopModel.routes.isEmpty {
                                Text("目前無即時抵達班次或路線")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(stopModel.routes) { route in
                                    Button(action: {
                                        let newDir = route.directionCode == "O" ? "outbound" : "inbound"
                                        selectedDirection = newDir
                                        searchText = route.route
                                        
                                        Task {
                                            // Pass the station Code so we strictly highlight what was tapped!
                                            await searchRoute(route: route.route, findNearest: false, targetStopCode: stopModel.stopInfo.stop, shouldScroll: true)
                                        }
                                    }) {
                                        HStack(alignment: .center, spacing: 12) {
                                            Text(route.route)
                                                .font(.system(.body, design: .rounded))
                                                .fontWeight(.bold)
                                                .foregroundColor(.white)
                                                .frame(width: 64, height: 36)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(Color(red: 0.65, green: 0.08, blue: 0.12))
                                                )
                                            
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                                    Text("往")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                    Text(route.destNameTc)
                                                        .font(.system(size: 15, weight: .bold))
                                                        .foregroundColor(.primary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            
                                            Spacer()
                                            
                                            HStack(spacing: 6) {
                                                if let firstEta = route.etas.first, let etaDate = firstEta.etaDate {
                                                    let secondsLeft = etaDate.timeIntervalSince(currentTime)
                                                    
                                                    if secondsLeft < 120 {
                                                        Text("即將抵達")
                                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                                            .foregroundColor(.green)
                                                    } else {
                                                        let minutesLeft = Int(secondsLeft / 60)
                                                        Text("\(minutesLeft) 分鐘")
                                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                            .foregroundColor(.primary)
                                                    }
                                                } else {
                                                    Text("無即時班次")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                }
                                                
                                                Image(systemName: "chevron.right")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if let firstEtaDate = route.etas.first?.etaDate,
                                           firstEtaDate.timeIntervalSince(currentTime) > 120 {
                                            Button {
                                                timerTargetDate = firstEtaDate
                                                timerRouteName = route.route
                                                timerDestination = route.destNameTc
                                                timerStationName = stopModel.stopInfo.name_tc
                                                showingAddTimerAlert = true
                                            } label: {
                                                Label("提醒", systemImage: "bell.fill")
                                            }
                                            .tint(.blue)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    func toggleStopExpanded(_ stopId: String) {
        if expandedStopIds.contains(stopId) {
            expandedStopIds.remove(stopId)
        } else {
            expandedStopIds.insert(stopId)
        }
    }
    
    func formatDistance(_ distance: CLLocationDistance) -> String {
        if distance < 1000 {
            return String(format: "%.0f 米", distance)
        } else {
            return String(format: "%.1f 公里", distance / 1000)
        }
    }
    
    // MARK: - Network Functions
    func loadAllRoutes() async {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route/") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(AllRoutesResponse.self, from: data)
            
            var uniqueSuggestions: [String: RouteSuggestion] = [:]
            
            for item in response.data {
                let key = "\(item.route)-\(item.bound)"
                if uniqueSuggestions[key] == nil {
                    uniqueSuggestions[key] = RouteSuggestion(
                        route: item.route,
                        bound: item.bound,
                        origin: item.orig_tc,
                        destination: item.dest_tc
                    )
                }
            }
            
            let sortedRoutes = uniqueSuggestions.values.sorted {
                if $0.route == $1.route { return $0.bound > $1.bound }
                return $0.route.localizedStandardCompare($1.route) == .orderedAscending
            }
            
            await MainActor.run {
                self.allRoutes = sortedRoutes
            }
        } catch {
            print("Failed to load all routes: \(error)")
        }
    }
    
    func loadAllStops() async {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop/") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(StopResponse.self, from: data)
            
            var newDict: [String: String] = [:]
            var newInfoDict: [String: StopInfo] = [:]
            for stop in response.data {
                newDict[stop.stop] = stop.name_tc // Store TC name as fallback mapping
                newInfoDict[stop.stop] = stop
            }
            
            await MainActor.run {
                self.allStops = response.data
                self.stopDictionary = newDict
                self.stopInfoDictionary = newInfoDict
            }
            
            if let userLoc = locationManager.location {
                await updateNearbyStops(userLocation: userLoc)
            }
        } catch {
            print("Failed to load stops dictionary: \(error)")
        }
    }
    
    func updateNearbyStops(userLocation: CLLocation) async {
        guard !allStops.isEmpty else { return }
        
        await MainActor.run {
            isSearchingNearby = true
        }
        
        let sorted = await Task.detached(priority: .userInitiated) { () -> [NearbyStopModel] in
            var temp: [NearbyStopModel] = []
            for stop in allStops {
                guard let stopLoc = stop.clLocation else { continue }
                let dist = userLocation.distance(from: stopLoc)
                temp.append(NearbyStopModel(stopInfo: stop, distance: dist))
            }
            temp.sort { $0.distance < $1.distance }
            return Array(temp.prefix(3))
        }.value
        
        var populated: [NearbyStopModel] = []
        for var stopModel in sorted {
            let routes = await fetchRoutesForStop(stopId: stopModel.stopInfo.stop)
            stopModel.routes = routes
            populated.append(stopModel)
        }
        
        await MainActor.run {
            self.nearbyStops = populated
            self.isSearchingNearby = false
        }
    }
    
    func fetchRoutesForStop(stopId: String) async -> [NearbyRouteModel] {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/\(stopId)") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(StopETAResponse.self, from: data)
            
            var grouped: [String: [StopETAItem]] = [:]
            for item in response.data {
                let key = "\(item.route)-\(item.dir)-\(item.dest_tc)"
                grouped[key, default: []].append(item)
            }
            
            var routes: [NearbyRouteModel] = []
            let dateFormatter = ISO8601DateFormatter()
            
            for (_, items) in grouped {
                guard let first = items.first else { continue }
                let sortedItems = items.sorted { $0.eta_seq < $1.eta_seq }
                
                var etaInfos: [ETADisplayInfo] = []
                for etaItem in sortedItems {
                    if let etaString = etaItem.eta, let etaDate = dateFormatter.date(from: etaString) {
                        etaInfos.append(ETADisplayInfo(etaDate: etaDate, remark: etaItem.rmk_tc))
                    }
                }
                
                routes.append(NearbyRouteModel(
                    route: first.route,
                    directionCode: first.dir,
                    destNameTc: first.dest_tc,
                    etas: etaInfos
                ))
            }
            
            return routes.sorted { $0.route.localizedStandardCompare($1.route) == .orderedAscending }
        } catch {
            print("Failed to fetch routes for stop \(stopId): \(error)")
            return []
        }
    }
    
    // MARK: 🐛 DEBUG Search Route Logic
    func searchRoute(route: String, findNearest: Bool = false, targetStopCode: String? = nil, shouldScroll: Bool = false) async {
        guard !route.isEmpty else { return }
        
        print("🐛 [DEBUG] 開始搜尋路線: \(route) | findNearest: \(findNearest) | shouldScroll: \(shouldScroll)")
        
        await MainActor.run {
            isLoading = true
            displayData = [] // 先清空，強迫 List 重新載入
            highlightedStopId = nil
        }
        
        let routeStopUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-stop/\(route)/\(selectedDirection)/1")!
        let etaUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-eta/\(route)/1")!
        
        do {
            async let (routeStopData, _) = URLSession.shared.data(from: routeStopUrl)
            async let (etaData, _) = URLSession.shared.data(from: etaUrl)
            
            let decoder = JSONDecoder()
            let routeStops = try await decoder.decode(RouteStopResponse.self, from: routeStopData).data
            let allEtas = try await decoder.decode(ETAResponse.self, from: etaData).data
            
            let targetDirectionCode = selectedDirection == "outbound" ? "O" : "I"
            let filteredEtas = allEtas.filter { $0.dir == targetDirectionCode }
            
            let dateFormatter = ISO8601DateFormatter()
            var results: [StopDisplayModel] = []
            
            for routeStop in routeStops {
                let stopNameTc: String
                if let stopInfo = stopInfoDictionary[routeStop.stop] {
                    stopNameTc = stopInfo.name_tc
                } else {
                    stopNameTc = stopDictionary[routeStop.stop] ?? "未知車站"
                }
                
                let seqInt = Int(routeStop.seq) ?? 0
                let stopEtas = filteredEtas.filter { $0.seq == seqInt }
                
                var parsedEtas: [ETADisplayInfo] = []
                for etaItem in stopEtas {
                    if let etaString = etaItem.eta, let etaDate = dateFormatter.date(from: etaString) {
                        parsedEtas.append(ETADisplayInfo(etaDate: etaDate, remark: etaItem.rmk_tc))
                    }
                }
                
                results.append(StopDisplayModel(
                    seq: seqInt,
                    stopId: routeStop.stop,
                    stopNameTc: stopNameTc,
                    etas: parsedEtas
                ))
            }
            
            // Highlight Logic matching
            var targetId: String? = nil
            
            if findNearest {
                if let userLoc = locationManager.location, !results.isEmpty {
                    print("🐛 [DEBUG] 正在根據 GPS 尋找最近車站...")
                    var minDistance: CLLocationDistance = .infinity
                    for rs in results {
                        let loc: CLLocation? = stopInfoDictionary[rs.stopId]?.clLocation ?? allStops.first(where: { $0.stop == rs.stopId })?.clLocation
                        if let stopLoc = loc {
                            let dist = userLoc.distance(from: stopLoc)
                            if dist < minDistance {
                                minDistance = dist
                                targetId = rs.id // Use deterministic ID string
                            }
                        }
                    }
                    print("🐛 [DEBUG] 根據 GPS 搵到最近車站 ID: \(targetId ?? "nil")")
                } else {
                    print("🐛 [DEBUG] 警告：findNearest 係 true，但無 GPS 定位 (locationManager.location 為 nil)！")
                }
            } else if let code = targetStopCode {
                targetId = results.first(where: { $0.stopId == code })?.id
                print("🐛 [DEBUG] 根據點擊嘅 targetStopCode 搵到車站 ID: \(targetId ?? "nil")")
            } else {
                targetId = highlightedStopId
            }
            
            await MainActor.run {
                self.highlightedStopId = targetId
                
                if results.isEmpty {
                    systemMessage = "沒有找到路線 \(route) 的 \(selectedDirection == "outbound" ? "去程" : "回程") 班次數據。"
                    displayData = []
                } else {
                    displayData = results
                }
                
                if shouldScroll {
                    print("🐛 [DEBUG] 更新 scrollTriggerId，準備觸發捲動")
                    self.scrollTriggerId = UUID() // 更新 UUID 強制觸發
                }
                
                isLoading = false
            }
        } catch {
            await MainActor.run {
                systemMessage = "無法加載數據或找不到此路線。"
                displayData = []
                isLoading = false
            }
            print("🐛 [DEBUG] Error: \(error)")
        }
    }
    
    @ViewBuilder
        private func activeTimerCard(timer: ActiveTimerModel) -> some View {
            let totalTime = timer.etaDate.timeIntervalSince(timer.startTime)
            let elapsedTime = currentTime.timeIntervalSince(timer.startTime)
            let progress = totalTime > 0 ? min(1.0, max(0.0, elapsedTime / totalTime)) : 1.0
            
            let secondsLeft = max(0, Int(timer.etaDate.timeIntervalSince(currentTime)))
            
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .opacity(secondsLeft > 0 && (Int(currentTime.timeIntervalSince1970) % 2 == 0) ? 0.3 : 1.0)
                            .animation(.easeInOut(duration: 0.5), value: currentTime)
                        Text("實時追蹤")
                            .font(.caption)
                            .fontWeight(.heavy)
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(10)
                    
                    Spacer()
                    
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            activeTimer = nil
                        }
                        endLiveActivity()
                        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["KMBTimeAlarm"])
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                            .font(.title2)
                    }
                }
                .padding([.top, .horizontal], 16)
                
                HStack(alignment: .center) {
                    HStack(spacing: 12) {
                        Text(timer.routeName)
                            .font(.system(size: 24, weight: .black))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(red: 0.65, green: 0.08, blue: 0.12))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("往 \(timer.destination)")
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            Text(timerStationName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                    
                    if secondsLeft < 120 {
                        Text("即將抵達")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.green)
                    } else {
                        Text(formattedTime(timer.etaDate))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                
                GeometryReader { geometry in
                    let barWidth = geometry.size.width
                    let busPosition = barWidth * CGFloat(progress)
                    
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 10)
                        
                        Capsule()
                            .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, busPosition), height: 10)
                            .animation(.linear(duration: 1.0), value: progress)
                        
                        Image(systemName: "bus.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Circle().fill(Color.blue).shadow(radius: 3))
                            .offset(x: max(0, min(busPosition - 17, barWidth - 34)))
                            .animation(.linear(duration: 1.0), value: progress)
                    }
                }
                .frame(height: 34)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
                
                HStack {
                    VStack(alignment: .leading) {
                        Text("預計到站時間")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(formattedTime(timer.etaDate))
                            .font(.headline)
                            .fontWeight(.bold)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("狀態")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(secondsLeft < 120 ? "即將抵達" : "正常行駛中")
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(secondsLeft < 120 ? .green : .secondary)
                    }
                }
                .padding(16)
                .background(Color.gray.opacity(0.05))
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .padding(.top, 8)
            .padding(.bottom, 8)
            .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity.combined(with: .scale)))
        }
    
    func formattedTime(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    func scheduleLocalNotification(routeName: String, destination: String, alertDate: Date) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["KMBTimeAlarm"])
        
        let content = UNMutableNotificationContent()
        content.title = "巴士即將抵達！"
        content.body = "您設定的 \(routeName) (往 \(destination)) 巴士即將在 2 分鐘內抵達，請準備上車。"
        content.sound = .default
        
        let timeInterval = alertDate.timeIntervalSince(Date())
        guard timeInterval > 0 else { return }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
        let request = UNNotificationRequest(identifier: "KMBTimeAlarm", content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule local notification: \(error)")
            }
        }
    }
    
    func startLiveActivity(routeName: String, destination: String, stationName: String, etaDate: Date, startTime: Date) {
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                let attributes = BusETAAttributes(routeName: routeName, destination: destination, stationName: stationName, startTime: startTime)
                let remaining = Int(etaDate.timeIntervalSince(Date()))
                let state = BusETAAttributes.ContentState(etaDate: etaDate, remainingSeconds: remaining)
                let content = ActivityContent(state: state, staleDate: nil)
                let _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                print("Error starting Live Activity: \(error.localizedDescription)")
            }
        }
    }
    
    func endLiveActivity() {
        Task {
            for activity in Activity<BusETAAttributes>.activities {
                let state = BusETAAttributes.ContentState(etaDate: activity.content.state.etaDate, remainingSeconds: 0)
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
}

struct ActiveTimerModel: Identifiable, Equatable {
    let id = UUID()
    let routeName: String
    let destination: String
    let etaDate: Date
    let targetAlertDate: Date
    let startTime: Date
}

// MARK: - Custom Keyboard View
struct CustomKeyboardView: View {
    @Binding var text: String
    var validKeys: Set<String>? // <--- 1. 喺度加入接收變數
    var onSearch: () -> Void
    var onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            // Toolbar Area
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Text("完成")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.blue)
                        .padding(.trailing, 16)
                }
            }
            .padding(.top, 10)
            
            // Main Keyboard Layout (Exactly 7 mathematical columns)
            GeometryReader { geo in
                let spacing: CGFloat = 8
                // 7 equal columns with 6 gaps of `spacing`
                let colWidth = (geo.size.width - (spacing * 6)) / 7
                let keyHeight: CGFloat = 46
                
                VStack(spacing: spacing) {
                    
                    // TOP SECTION: Numpad (Left) + Alpha (Right)
                    HStack(spacing: spacing) {
                        
                        // LEFT SIDE: Numpad (3 cols wide)
                        VStack(spacing: spacing) {
                            let numpad = [
                                ["1", "2", "3"],
                                ["4", "5", "6"],
                                ["7", "8", "9"]
                            ]
                            
                            ForEach(numpad, id: \.self) { row in
                                HStack(spacing: spacing) {
                                    ForEach(row, id: \.self) { key in
                                        keyboardButton(key, width: colWidth, height: keyHeight) { text.append(key) }
                                    }
                                }
                            }
                            
                            // Bottom Numpad Row: '0' safely isolated below '8'
                            HStack(spacing: spacing) {
                                Color.clear.frame(width: colWidth, height: keyHeight)
                                keyboardButton("0", width: colWidth, height: keyHeight) { text.append("0") }
                                Color.clear.frame(width: colWidth, height: keyHeight)
                            }
                        }
                        
                        // RIGHT SIDE: Alpha (4 cols wide)
                        VStack(spacing: spacing) {
                            let alphaRows = [
                                ["A", "B", "C", "D"],
                                ["E", "F", "H", "K"],
                                ["M", "N", "P", "R"],
                                ["S", "T", "W", "X"]
                            ]
                            
                            ForEach(alphaRows, id: \.self) { row in
                                HStack(spacing: spacing) {
                                    ForEach(row, id: \.self) { key in
                                        keyboardButton(key, width: colWidth, height: keyHeight) { text.append(key) }
                                    }
                                }
                            }
                        }
                    }
                    
                    // BOTTOM SECTION: Action Row
                    HStack(spacing: spacing) {
                        // Clear All (Spans 2 columns + 1 inner spacing)
                        let clearWidth = (colWidth * 2) + spacing
                        actionButton("清空", width: clearWidth, height: keyHeight, color: Color(UIColor.systemGray4)) {
                            text = ""
                        }
                        
                        // Search (Spans 3 columns + 2 inner spacings)
                        let searchWidth = (colWidth * 3) + (spacing * 2)
                        Button(action: onSearch) {
                            Text("搜尋")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: searchWidth, height: keyHeight)
                                .background(Color.blue)
                                .cornerRadius(6)
                                .shadow(color: Color.black.opacity(0.3), radius: 0, x: 0, y: 1)
                                .foregroundColor(.white)
                        }
                        
                        // Backspace (Spans 2 columns + 1 inner spacing)
                        let backspaceWidth = (colWidth * 2) + spacing
                        actionButton(Image(systemName: "delete.left"), width: backspaceWidth, height: keyHeight, color: Color(UIColor.systemGray4)) {
                            if !text.isEmpty { text.removeLast() }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 270) // Accommodates 5 distinct rows + paddings
        }
        .padding(.bottom, 20)
        .background(
            Color(UIColor.systemGray5)
                .shadow(color: .black.opacity(0.1), radius: 10, y: -5)
                .ignoresSafeArea()
        )
    }
    
    // MARK: - Reusable Button Builders
    @ViewBuilder
    private func keyboardButton(_ text: String, width: CGFloat, height: CGFloat, action: @escaping () -> Void) -> some View {
        // 如果 validKeys 係 nil (API未load完)，或者包含呢個按鍵，就當做 valid
        let isValid = validKeys?.contains(text) ?? true
        
        Button(action: action) {
            Text(text)
                .font(.system(size: 22, weight: .regular))
                .frame(width: width, height: height)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(6)
                // 如果 Disable 咗，將陰影移除令佢望落去平啲
                .shadow(color: Color.black.opacity(isValid ? 0.3 : 0.0), radius: 0, x: 0, y: isValid ? 1 : 0)
                // 如果 Disable 咗，將字體顏色變灰
                .foregroundColor(isValid ? .primary : Color(UIColor.tertiaryLabel))
        }
        // 直接封鎖點擊功能
        .disabled(!isValid)
    }
    
    @ViewBuilder
    private func actionButton(_ title: String, width: CGFloat, height: CGFloat, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .frame(width: width, height: height)
                .background(color)
                .cornerRadius(6)
                .shadow(color: Color.black.opacity(0.3), radius: 0, x: 0, y: 1)
                .foregroundColor(.primary)
        }
    }
    
    @ViewBuilder
    private func actionButton(_ icon: Image, width: CGFloat, height: CGFloat, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon
                .font(.system(size: 20))
                .frame(width: width, height: height)
                .background(color)
                .cornerRadius(6)
                .shadow(color: Color.black.opacity(0.3), radius: 0, x: 0, y: 1)
                .foregroundColor(.primary)
        }
    }
}
