import SwiftUI
import UserNotifications

extension ContentView {
    /// Buttons shown in the timer confirmation alert.
    @ViewBuilder
    var alertButtons: some View {
        Button(activeTimer == nil ? "設定提醒" : "確認替換", role: .none) {
            confirmTimerAlert()
        }
        Button("取消", role: .cancel) {}
    }
    
    /// Message shown in the timer confirmation alert.
    ///
    /// The copy differs when the new reminder will replace an existing active timer.
    @ViewBuilder
    var alertMessage: some View {
        if let existing = activeTimer {
            Text("您目前已為 \(existing.routeName) 設定了提醒。確定要取消舊提醒，並為 \(timerRouteName) 重新設定嗎？\n\n系統將在巴士預計抵達前 2 分鐘（即 \(formattedTime(timerTargetDate?.addingTimeInterval(-120) ?? Date()))）提醒您。")
        } else {
            Text("您是否要為 \(timerRouteName) 路線設定提醒？\n\n系統將在巴士預計抵達前 2 分鐘（即 \(formattedTime(timerTargetDate?.addingTimeInterval(-120) ?? Date()))）提醒您。")
        }
    }
    
    /// Commits the pending timer values after the user confirms the alert.
    ///
    /// This schedules the local notification, starts the Live Activity, starts background location
    /// tracking, and returns the UI to the dashboard timer card.
    func confirmTimerAlert() {
        guard let etaDate = timerTargetDate else { return }
        
        if activeTimer != nil {
            endLiveActivity()
        }
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                scheduleLocalNotification(
                    routeName: timerRouteName,
                    destination: timerDestination,
                    alertDate: etaDate.addingTimeInterval(-120)
                )
            }
        }
        
        startLiveActivity(
            routeName: timerRouteName,
            company: timerCompany,
            destination: timerDestination,
            stationName: timerStationName,
            etaDate: etaDate,
            startTime: Date()
        )
        locationManager.startBackgroundTracking()
        
        withAnimation {
            activeTimer = ActiveTimerModel(
                routeName: timerRouteName,
                company: timerCompany,
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
