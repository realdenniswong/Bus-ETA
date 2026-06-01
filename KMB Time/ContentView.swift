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
    let name_en: String
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
    let id = UUID()
    let seq: Int
    let stopId: String // <--- 新增呢行
    let stopNameTc: String
    let stopNameEn: String
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
    let destNameEn: String
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
    let dest_en: String
    let eta_seq: Int
    let eta: String?
    let rmk_tc: String?
    let rmk_en: String?
}

// MARK: - User Interface
struct ContentView: View {
    @State private var searchText = ""
    @State private var selectedDirection = "outbound" // Tracks the selected direction
    
    @State private var stopDictionary: [String: String] = [:]
    @State private var stopInfoDictionary: [String: StopInfo] = [:]
    @State private var displayData: [StopDisplayModel] = []
    
    @State private var isLoading = false
    @State private var systemMessage = "搜尋九巴路線 (例如 1A, 281A)"
    
    // Nearby Location States
    @StateObject private var locationManager = LocationManager()
    @State private var allStops: [StopInfo] = []
    @State private var nearbyStops: [NearbyStopModel] = []
    @State private var expandedStopIds: Set<String> = []
    @State private var isSearchingNearby = false
    
    // Explicit Navigation Title State
   
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
    
    // Auto-scroll target Stop ID/Name
    @State private var targetScrollStopId: String? = nil
    
    // NEW: Custom Keyboard State
    @State private var showCustomKeyboard = false
    
    init() {
        // Remove Segmented Control white background track to match background color
        UISegmentedControl.appearance().backgroundColor = .clear
    }
    
    var body: some View {
            NavigationStack {
                ScrollViewReader { proxy in
                    List {
                        // 1. Native-Looking Custom Search Bar (Inside the List)
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
                        .background(Color(UIColor.systemGray5)) // 1. Inner pill background (slightly darker so it pops)
                        .cornerRadius(20)
                        .padding(.top, 16)
                        .listRowBackground(themeBackground) // 2. Fills the empty space around the bar with your theme color
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
                        if searchText.isEmpty {
                            nearbyDashboardSection
                        } else {
                            // Segmented direction switcher
                            Picker("Direction", selection: $selectedDirection) {
                                Text("去程 (Outbound)").tag("outbound")
                                Text("回程 (Inbound)").tag("inbound")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: selectedDirection) { _ in
                                if !searchText.isEmpty {
                                    Task {
                                        await searchRoute(route: searchText.uppercased())
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
                                onSearch: {
                                    showCustomKeyboard = false
                                    Task {
                                        await searchRoute(route: searchText.uppercased())
                                    }
                                },
                                onDismiss: {
                                    withAnimation(.spring()) { showCustomKeyboard = false }
                                }
                            )
                            .transition(.move(edge: .bottom))
                        }
                    }
                    .navigationTitle(searchText.isEmpty ? "九巴到站預報" : "路線資料")
                    .navigationBarTitleDisplayMode(.large)
                    .overlay {
                        if isLoading {
                            ProgressView("正在獲取數據...")
                        } else if displayData.isEmpty && !searchText.isEmpty {
                            Text(systemMessage)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                    .toolbar {
                        if !searchText.isEmpty {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button(action: {
                                    searchText = ""
                                    displayData = []
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
                            } else if !displayData.isEmpty {
                                await searchRoute(route: searchText.uppercased())
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
                    .onChange(of: displayData.isEmpty) { isEmpty in
                        if !isEmpty, let target = targetScrollStopId {
                            // 稍微拉長 delay 至 0.4 秒，確保 SwiftUI List 已經生成好 UI
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                    proxy.scrollTo(target, anchor: .center)
                                }
                                targetScrollStopId = nil
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
    
    // MARK: - Core Theme Background (Pure Native Apple Style)
    private var themeBackground: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
    
    // MARK: - Timetable Route Content Section
    private var timetableSection: some View {
        Group {
            if !displayData.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayData.enumerated()), id: \.element.id) { index, stop in
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(Color(red: 0.65, green: 0.08, blue: 0.12)) // KMB Red
                                    .frame(width: 12, height: 12)
                                    .padding(.top, 6)
                                
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
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                    Text(stop.stopNameEn)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                
                                // Always displays exactly 3 lines of ETAs, filling blank spaces with "-"
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(0..<3, id: \.self) { index in
                                        let etaInfo = index < stop.etas.count ? stop.etas[index] : nil
                                        if let etaInfo = etaInfo, let etaDate = etaInfo.etaDate {
                                            // 1. Calculate raw seconds left instead of shifting straight to minutes
                                            let secondsLeft = etaDate.timeIntervalSince(currentTime)
                                            let remark = etaInfo.remark ?? ""
                                            let formattedRemark = remark.isEmpty ? "" : " (\(remark))"
                                            
                                            // 2. Apply the < 2 minutes (120 seconds) "Arriving" rule
                                            if secondsLeft < 120 {
                                                Text("即將抵達\(formattedRemark)")
                                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                                    .foregroundColor(.green) // Visual cue: Green for arriving
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
                            .padding(.bottom, index < displayData.count - 1 ? 20 : 0)
                        }
                        .id(stop.stopId)
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(14)
                .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
            }
        }
    }
    
    // MARK: - Nearby Dashboard View
    @ViewBuilder
    private var nearbyDashboardSection: some View {
        // Stop Header
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
        .padding(.top, 12)    // 稍微將文字同上面嘅元素推開少少
        .padding(.bottom, -10) // ✨ 加入呢行！利用負數 padding 將第一張卡片強行向上拉近
        .listRowBackground(Color.clear)
        // .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        .listRowSeparator(.hidden) // <--- ADD THIS LINE HERE
        
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
                // 1. Change the frame to have a minHeight to push it down
                .frame(maxWidth: .infinity, minHeight: 250)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden) // 2. Hide the separator line here too!
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
                        // Header Row (toggles expansion)
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
                                    Text(stopModel.stopInfo.name_en)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
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
                        
                        // Route items (if expanded)
                        if isExpanded {
                            if stopModel.routes.isEmpty {
                                Text("目前無即時抵達班次或路線")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(stopModel.routes) { route in
                                    Button(action: {
                                        // 1. 決定方向
                                        let newDir = route.directionCode == "O" ? "outbound" : "inbound"
                                        
                                        // 2. 同步更新所有狀態
                                        selectedDirection = newDir
                                        searchText = route.route
                                        targetScrollStopId = stopModel.stopInfo.stop // 繼續保留用精準嘅 ID 來做 Scroll
                                        
                                        // 3. 刪除多餘嘅 if/else，每次都無條件直接手動 Call API！
                                        Task {
                                            await searchRoute(route: route.route)
                                        }
                                    }) {
                                        // 呢度下面維持你原本嘅 HStack UI 設計...
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
                                                Text("to \(route.destNameEn)")
                                                    .font(.system(size: 12))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                            
                                            Spacer()
                                            
                                            // Look for this block inside nearbyDashboardSection:
                                            HStack(spacing: 6) {
                                                
                                                // 搵返 Dashboard 修改第一班車 ETA 嘅位置，換成呢段：
                                                if let firstEta = route.etas.first, let etaDate = firstEta.etaDate {
                                                    let secondsLeft = etaDate.timeIntervalSince(currentTime)
                                                    
                                                    if secondsLeft < 120 {
                                                        Text("即將抵達")
                                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                                            .foregroundColor(.green)
                                                    } else {
                                                        // 改回顯示剩餘分鐘（例如：15 分鐘）
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
                                                timerStationName = stopModel.stopInfo.name_tc // <-- 喺度攞返個站名！
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
    
    func loadAllStops() async {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop/") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(StopResponse.self, from: data)
            
            var newDict: [String: String] = [:]
            var newInfoDict: [String: StopInfo] = [:]
            for stop in response.data {
                newDict[stop.stop] = stop.name_en
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
                let key = "\(item.route)-\(item.dir)-\(item.dest_en)"
                grouped[key, default: []].append(item)
            }
            
            var routes: [NearbyRouteModel] = []
            let dateFormatter = ISO8601DateFormatter()
            let now = Date()
            
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
                    destNameEn: first.dest_en,
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
    
    func searchRoute(route: String) async {
        guard !route.isEmpty else { return }
        
        isLoading = true
        displayData = []
        
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
            let now = Date()
            var results: [StopDisplayModel] = []
            
            for routeStop in routeStops {
                let stopNameTc: String
                let stopNameEn: String
                if let stopInfo = stopInfoDictionary[routeStop.stop] {
                    stopNameTc = stopInfo.name_tc
                    stopNameEn = stopInfo.name_en
                } else {
                    stopNameTc = stopDictionary[routeStop.stop] ?? "未知車站"
                    stopNameEn = "Unknown Stop"
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
                    stopId: routeStop.stop, // <--- 新增呢行，將 API 嘅真實 stop 碼記錄低
                    stopNameTc: stopNameTc,
                    stopNameEn: stopNameEn,
                    etas: parsedEtas
                ))
            }
            
            if results.isEmpty {
                systemMessage = "沒有找到路線 \(route) 的 \(selectedDirection == "outbound" ? "去程" : "回程") 班次數據。"
            } else {
                displayData = results
            }
            
        } catch {
            systemMessage = "無法加載數據或找不到此路線。"
            print(error)
        }
        
        isLoading = false
    }
    
    @ViewBuilder
        private func activeTimerCard(timer: ActiveTimerModel) -> some View {
            let totalTime = timer.etaDate.timeIntervalSince(timer.startTime)
            let elapsedTime = currentTime.timeIntervalSince(timer.startTime)
            let progress = totalTime > 0 ? min(1.0, max(0.0, elapsedTime / totalTime)) : 1.0
            
            // 計算剩餘秒數用作判斷狀態
            let secondsLeft = max(0, Int(timer.etaDate.timeIntervalSince(currentTime)))
            
            // Uber Style Live Tracker
            VStack(spacing: 0) {
                // Header: Live Tracking
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
                
                // ETA and Route info
                HStack(alignment: .center) {
                    // 1. 左邊：路線資訊
                    HStack(spacing: 12) {
                        // 路線號碼
                        Text(timer.routeName)
                            .font(.system(size: 24, weight: .black))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(red: 0.65, green: 0.08, blue: 0.12)) // 統一使用九巴標準紅
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        
                        // 目的地及站名
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
                    
                    // 2. 右邊：預計時間狀態（已移除倒數，改為大字絕對時間或即將抵達）
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
                
                // Progress Bar and Bus Icon
                GeometryReader { geometry in
                    let barWidth = geometry.size.width
                    let busPosition = barWidth * CGFloat(progress)
                    
                    ZStack(alignment: .leading) {
                        // Background Track
                        Capsule()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 10)
                        
                        // Fill Track
                        Capsule()
                            .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, busPosition), height: 10)
                            .animation(.linear(duration: 1.0), value: progress)
                        
                        // Bus Icon
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
                
                // Footer Info（已完全移除 MM:SS 倒數時鐘）
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
        // Cancel existing timer notification
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
    var onSearch: () -> Void
    var onDismiss: () -> Void
    
    let rows = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["A", "B", "C", "E", "H", "K", "N", "P", "R", "S"],
        ["T", "W", "X"]
    ]
    
    var body: some View {
        VStack(spacing: 12) {
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
            
            // Keys Area
            VStack(spacing: 12) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { key in
                            Button(action: { text.append(key) }) {
                                Text(key)
                                    .font(.system(size: 24, weight: .regular))
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(Color(UIColor.systemBackground)) // Pure white/black key
                                    .cornerRadius(5) // Standard Apple key radius
                                    .shadow(color: Color.black.opacity(0.3), radius: 0, x: 0, y: 1) // Apple key drop shadow
                                    .foregroundColor(.primary)
                            }
                        }
                        
                        // For the last row, seamlessly append Delete and Search keys
                        if row == rows.last {
                            Button(action: {
                                if !text.isEmpty { text.removeLast() }
                            }) {
                                Image(systemName: "delete.left")
                                    .font(.system(size: 20))
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(Color(UIColor.systemGray4)) // Action keys are slightly darker
                                    .cornerRadius(5)
                                    .shadow(color: Color.black.opacity(0.3), radius: 0, x: 0, y: 1)
                                    .foregroundColor(.primary)
                            }
                            
                            Button(action: {
                                onSearch()
                            }) {
                                Text("搜尋")
                                    .font(.system(size: 16, weight: .bold))
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(Color.blue)
                                    .cornerRadius(5)
                                    .shadow(color: Color.black.opacity(0.3), radius: 0, x: 0, y: 1)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 6) // Padding to prevent bleeding to the absolute edge
        }
        .padding(.bottom, 20)
        .background(
            Color(UIColor.systemGray5) // Native iOS keyboard background color
                .shadow(color: .black.opacity(0.1), radius: 10, y: -5)
                .ignoresSafeArea()
        )
    }
}

