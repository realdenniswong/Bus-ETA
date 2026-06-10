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

struct FavoriteETA {
    let stopName: String
    let etaDate: Date?
}

struct ContentView: View {
    // MARK: - Tab and Search State
    @State var selectedTab = 0
    
    @State var searchText = ""
    @State var selectedDirection = "outbound"
    @State var selectedCompany = "KMB"
    
    // MARK: - KMB Route and Stop Data
    @State var stopDictionary: [String: String] = [:]
    @State var stopInfoDictionary: [String: StopInfo] = [:]
    @State var displayData: [StopDisplayModel] = []
    @State var allRoutes: [RouteSuggestion] = []
    
    @State var isLoading = false
    @State var systemMessage = "搜尋巴士路線 (例如 1A, 281A)"
    
    // MARK: - Managers
    @StateObject var locationManager = LocationManager()
    @StateObject var favoritesManager = FavoritesManager()
    
    // MARK: - Nearby Dashboard State
    @State var allStops: [StopInfo] = []
    @State var nearbyStops: [NearbyStopModel] = []
    @State var dashboardETAByKey: [String: (updatedAt: Date, etas: [ETADisplayInfo])] = [:]
    @State var isSearchingNearby = false
    @State var isUpdatingNearby = false
    
    // MARK: - Refresh and Clock State
    let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State var currentTime = Date()
    
    // MARK: - Active Reminder State
    @State var activeTimer: ActiveTimerModel? = nil
    @State var showingAddTimerAlert = false
    @State var timerTargetDate: Date? = nil
    @State var timerRouteName = ""
    @State var timerCompany = "KMB"
    @State var timerDestination = ""
    @State var timerStopId = ""
    @State var timerDirection = ""
    @State var timerStationName = ""
    
    // MARK: - Favourites State
    @State var favoriteStatus: [String: FavoriteStatusModel] = [:]
    @State var isUpdatingFavorites = false
    
    // MARK: - Navigation and UI State
    @State var highlightedStopId: String? = nil
    @State var scrollTriggerId: UUID = UUID()
    @State var showCustomKeyboard = false
    @State var isNavigatingToRoute = false
    @State var dashboardScrollTarget: String? = nil
    @State var toastMessage: String? = nil
    
    // MARK: - App Lifecycle
    @Environment(\.scenePhase) var scenePhase
    
    init() {
        UISegmentedControl.appearance().backgroundColor = .clear
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScrollViewReader { dashboardProxy in
                    dashboardContentView
                        .onChange(of: dashboardScrollTarget) { _, target in
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
                .onChange(of: isNavigatingToRoute) { _, isNavigating in
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
                    if locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways {
                        locationManager.requestLocation()
                    }
                    
                    async let stopsLoad: Void = loadAllStops()
                    async let routesLoad: Void = loadAllRoutes()
                    _ = await (stopsLoad, routesLoad)
                    reconnectActiveLiveActivity()
                    warmFavoriteETAsIfPossible()
                    
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
                }
                .onChange(of: locationManager.location) { _, newValue in
                    if let location = newValue, !locationManager.isBackgroundTracking {
                        Task {
                            await updateNearbyStops(userLocation: location)
                            warmFavoriteETAsIfPossible()
                        }
                    }
                }
                .onChange(of: locationManager.backgroundHeartbeat) { _, _ in
                    clearExpiredTimerIfNeeded(referenceDate: Date())
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        reconnectActiveLiveActivity()
                        locationManager.requestLocation()
                        Task { await refreshVisibleData(rebuildNearbyWhenEmpty: true) }
                    }
                }
            }
            .toolbar(showCustomKeyboard ? .hidden : .visible, for: .tabBar)
            .animation(.easeInOut(duration: 0.2), value: showCustomKeyboard)
            .tabItem {
                Label("到站預報", systemImage: "bus.fill")
            }
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
                toastView(message: message)
            }
        }
        .environmentObject(favoritesManager)
    }
}
