import SwiftUI

struct DashboardView: View {
    @ObservedObject var locationManager: LocationManager
    @Binding var searchText: String
    @Binding var showCustomKeyboard: Bool
    let activeTimer: ActiveTimerModel?
    let currentTime: Date
    let allStops: [StopInfo]
    let nearbyStops: [NearbyStopModel]
    let allRoutes: [RouteSuggestion]
    let searchSuggestions: [RouteSuggestion]
    let validNextKeys: Set<String>?
    let selectedDirection: String
    let isSearchingNearby: Bool
    
    let onCancelTimer: () -> Void
    let onRequestLocation: () -> Void
    let onRefreshLocationAndNearbyStops: () -> Void
    let onSuggestedRouteSelected: (RouteSuggestion) -> Void
    let onNearbyRouteSelected: (NearbyRouteModel, StopInfo) -> Void
    let onSetNearbyTimer: (NearbyRouteModel, StopInfo) -> Void
    let onSearchRoute: (String, String) -> Void
    let onShowToast: (String) -> Void
    
    var body: some View {
        ZStack {
            List {
                searchBarView
                
                if let activeTimer {
                    activeTimerCardView(timer: activeTimer)
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
        .navigationTitle(showCustomKeyboard ? "搜尋路線" : "到站預報")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { dashboardToolbar }
    }
    
    private var themeBackground: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
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
            withAnimation(.spring()) {
                showCustomKeyboard = true
            }
        }
    }
    
    private var suggestionsSectionView: some View {
        SuggestionsSectionView(
            suggestions: searchSuggestions,
            allRoutes: allRoutes,
            onSelected: { suggestion, _ in
                onSuggestedRouteSelected(suggestion)
            }
        )
    }
    
    private func activeTimerCardView(timer: ActiveTimerModel) -> some View {
        ActiveTimerCardView(
            timer: timer,
            currentTime: currentTime,
            onCancel: onCancelTimer
        )
        .id("ActiveTimerCard")
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
    
    private var nearbyDashboardSectionView: some View {
        NearbyDashboardSectionView(
            locationManager: locationManager,
            allStops: allStops,
            nearbyStops: nearbyStops,
            currentTime: currentTime,
            allRoutes: allRoutes,
            onRequestLocation: onRequestLocation,
            onRouteSelected: onNearbyRouteSelected,
            onSetTimer: onSetNearbyTimer,
            onShowToast: onShowToast
        )
    }
    
    private var customKeyboardOverlay: some View {
        CustomKeyboardView(
            text: $searchText,
            validKeys: validNextKeys,
            onSearch: {
                showCustomKeyboard = false
                onSearchRoute(searchText.uppercased(), selectedDirection)
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
                    Button(action: onRefreshLocationAndNearbyStops) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .medium))
                    }
                }
            }
        }
    }
    
    private func dismissKeyboardSafe() {
        withAnimation(.spring()) {
            showCustomKeyboard = false
        }
    }
}
