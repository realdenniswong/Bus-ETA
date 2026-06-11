/// 檔案用途：處理到站提醒確認對話框內容同按鈕。
import SwiftUI
import UserNotifications

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    /// 到站提醒確認對話框顯示嘅按鈕。
    @ViewBuilder
    var alertButtons: some View {
        Button(activeTimer == nil ? "設定提醒" : "確認替換", role: .none) {
            confirmTimerAlert()
        }
        Button("取消", role: .cancel) {}
    }

    /// 到站提醒確認對話框顯示嘅訊息。
    ///
    /// 新提醒會取代現有啟用計時器時，文案會有所不同。
    @ViewBuilder
    var alertMessage: some View {
        if let existing = activeTimer {
            Text("您目前已為 \(existing.routeName) 設定了提醒。確定要取消舊提醒，並為 \(timerRouteName) 重新設定嗎？\n\n系統將在巴士預計抵達前 2 分鐘（即 \(formattedTime(timerTargetDate?.addingTimeInterval(-120) ?? Date()))）提醒您。")
        } else {
            Text("您是否要為 \(timerRouteName) 路線設定提醒？\n\n系統將在巴士預計抵達前 2 分鐘（即 \(formattedTime(timerTargetDate?.addingTimeInterval(-120) ?? Date()))）提醒您。")
        }
    }

    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func confirmTimerAlert() {
        guard let etaDate = timerTargetDate else { return }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                scheduleLocalNotification(
                    routeName: timerRouteName,
                    destination: timerDestination,
                    alertDate: etaDate.addingTimeInterval(-120)
                )
            }
        }
        let routeName = timerRouteName
        let company = timerCompany
        let destination = timerDestination
        let stationName = timerStationName
        let stopId = timerStopId
        let direction = timerDirection
        let operatorStopIds = timerOperatorStopIds
        let startTime = Date()

        Task {
            if activeTimer != nil {
                await endLiveActivity()
            }

            startLiveActivity(
                routeName: routeName,
                company: company,
                destination: destination,
                stationName: stationName,
                etaDate: etaDate,
                startTime: startTime,
                stopId: stopId,
                direction: direction,
                operatorStopIds: operatorStopIds
            )
            locationManager.startBackgroundTracking()

            withAnimation {
                activeTimer = ActiveTimerModel(
                    routeName: routeName,
                    company: company,
                    destination: destination,
                    etaDate: etaDate,
                    targetAlertDate: etaDate.addingTimeInterval(-120),
                    startTime: startTime,
                    stopId: stopId,
                    direction: direction,
                    stationName: stationName,
                    operatorStopIds: operatorStopIds
                )
            }
        }

        isNavigatingToRoute = false
        dashboardScrollTarget = "ActiveTimerCard"
    }
}
