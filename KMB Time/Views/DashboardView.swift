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
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 17, weight: .semibold))
            
            Text(searchText.isEmpty ? "輸入路線 (例如 1A)" : searchText)
                .foregroundStyle(searchText.isEmpty ? .secondary : .primary)
                .font(.system(size: 17, weight: searchText.isEmpty ? .regular : .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, searchText.isEmpty ? 16 : 8)
        .frame(height: 52)
        .liquidGlassSurface(cornerRadius: 24, isInteractive: true)
        .padding(.horizontal, 4)
        .padding(.top, 16)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
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
private extension View {
    @ViewBuilder
    func liquidGlassSurface(cornerRadius: CGFloat, isInteractive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if isInteractive {
                self.glassEffect(.regular.tint(.white.opacity(0.18)).interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular.tint(.white.opacity(0.16)), in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
                )
        }
    }
}

