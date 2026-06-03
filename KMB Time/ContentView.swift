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

// MARK: - User Interface View
struct ContentView: View {
    // Note: 'private' removed to allow ContentView+Logic.swift to access state variables
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
        
        if query.isEmpty {
            return Set(allRoutes.compactMap { $0.route.first.map(String.init) })
        }
        
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
                    
                    // 2. Active Timer Card
                    if let timer = activeTimer {
                        activeTimerCard(timer: timer)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                    
                    // 3. Main Content Sections
                    if showCustomKeyboard && !searchText.isEmpty {
                        suggestionsSection
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        
                    } else if searchText.isEmpty {
                        nearbyDashboardSection
                        
                    } else {
                        Picker("Direction", selection: $selectedDirection) {
                            Text("去程 (Outbound)").tag("outbound")
                            Text("回程 (Inbound)").tag("inbound")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedDirection) { newValue in
                            if !searchText.isEmpty {
                                Task {
                                    await searchRoute(route: searchText.uppercased(), direction: newValue, findNearest: true, shouldScroll: true)
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
                            validKeys: validNextKeys,
                            onSearch: {
                                showCustomKeyboard = false
                                Task {
                                    await searchRoute(route: searchText.uppercased(), direction: selectedDirection, findNearest: true, shouldScroll: true)
                                }
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
                                    Task {
                                        await updateNearbyStops(userLocation: loc)
                                    }
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
                        if activeTimer != nil {
                            await syncActiveTimer()
                        }
                        
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
                        Task {
                            await updateNearbyStops(userLocation: location)
                        }
                    }
                }
                .onChange(of: locationManager.backgroundHeartbeat) { oldValue, newValue in
                    if let timer = activeTimer {
                        let secondsLeft = timer.etaDate.timeIntervalSince(Date())
                        if secondsLeft <= -10 {
                            print("🐛 [深層睡眠心跳扣殺] 褲袋擊殺觸發！執行收屍任務...")
                            withAnimation {
                                activeTimer = nil
                            }
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
    
    // MARK: - Core Theme Background
    var themeBackground: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
    
    // MARK: - Auto-complete Suggestions Section (IN-PAGE)
    @ViewBuilder
    var suggestionsSection: some View {
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
                    .onTapGesture {
                        searchText = suggestion.route
                        
                        let isOutbound = suggestion.bound.uppercased().hasPrefix("O")
                        let newDir = isOutbound ? "outbound" : "inbound"
                        
                        withAnimation(.spring()) {
                            showCustomKeyboard = false
                        }
                        
                        Task {
                            await searchRoute(route: suggestion.route.uppercased(), direction: newDir, findNearest: true, shouldScroll: true)
                        }
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
    var timetableSection: some View {
        Group {
            if !displayData.isEmpty {
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

                                            let minutesLeft = Int(secondsLeft / 60)
                                            if(minutesLeft < 0){
                                                Text("遲到 \(minutesLeft * -1) 分鐘\(formattedRemark)")
                                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    .foregroundColor(Color.red)
                                            }
                                            else if(minutesLeft == 0){
                                                Text("已到站")
                                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    .foregroundColor(Color.green)
                                            }
                                            else{
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
                            
                            Spacer(minLength: 0)
                        }
                        .padding(.top, index == 0 ? 16 : 0)
                        .padding(.bottom, index == displayData.count - 1 ? 16 : 0)
                        .id(stop.id)
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
    var nearbyDashboardSection: some View {
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
                                            await searchRoute(route: route.route, direction: newDir, findNearest: false, targetStopCode: stopModel.stopInfo.stop, shouldScroll: true)
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
                                                    let minutesLeft = Int(secondsLeft / 60)
                                                    if(minutesLeft < 0){
                                                        Text("遲到 \(minutesLeft * -1) 分鐘")
                                                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                            .foregroundColor(Color.red)
                                                    }
                                                    else if(minutesLeft == 0){
                                                        Text("已到站")
                                                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                            .foregroundColor(Color.green)
                                                    }
                                                    else{
                                                        Text("\(minutesLeft) 分鐘")
                                                            .font(.system(size: 15, weight: .semibold, design: .rounded))
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
                                                timerStopId = stopModel.stopInfo.stop
                                                timerDirection = route.directionCode == "O" ? "outbound" : "inbound"
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
    
    // MARK: - Local UI Helpers
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
    
    @ViewBuilder
    func activeTimerCard(timer: ActiveTimerModel) -> some View {
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
                    self.locationManager.stopBackgroundTracking()
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
                        
                        Text(timer.stationName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                let minutesLeft = max(0, Int(ceil(Double(secondsLeft) / 60.0)))
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(minutesLeft) 分鐘")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(minutesLeft == 0 ? .green : .blue)
                    Text("\(formattedTime(timer.etaDate)) 到達")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                    let minutesLeft = max(0, Int(ceil(Double(secondsLeft) / 60.0)))
                    Text(minutesLeft == 0 ? "巴士到站中" : "正常行駛中")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(minutesLeft == 0 ? .green : .secondary)
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
}