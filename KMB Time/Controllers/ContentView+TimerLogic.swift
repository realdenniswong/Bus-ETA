/// 檔案用途：管理到站提醒、Live Activity 同本地通知。
import ActivityKit
import SwiftUI
import UserNotifications

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    /// 用最新 provider ETA 更新目前啟用嘅到站提醒。
    ///
    /// 當 ETA 變動超過 10 秒，會更新 app 內計時器、重新排程兩分鐘前本地通知，並將新到站時間推送到任何啟用中嘅 Live Activity。
    func syncActiveTimer() async {
        guard let timer = activeTimer, !timer.stopId.isEmpty else { return }
        let timerDirection = BusDirection(rawValue: timer.direction) ?? .outbound
        
        do {
            let provider = providerForCompany(timer.company)
            let etas = try await provider.fetchTimerETAs(
                route: timer.routeName,
                direction: timerDirection,
                stopId: timer.stopId,
                operatorStopIds: timer.operatorStopIds
            )
            guard let newEtaDate = etas.first?.etaDate else { return }
            
            let difference = abs(newEtaDate.timeIntervalSince(timer.etaDate))
            guard difference > 10 else { return }
            
            await MainActor.run {
                withAnimation {
                    self.activeTimer?.etaDate = newEtaDate
                    self.activeTimer?.targetAlertDate = newEtaDate.addingTimeInterval(-120)
                }
            }
            
            let alertDate = newEtaDate.addingTimeInterval(-120)
            scheduleLocalNotification(routeName: timer.routeName, destination: timer.destination, alertDate: alertDate)
            updateLiveActivity(etaDate: newEtaDate)
        } catch {
            print("Active timer sync failed: \(error)")
        }
    }
    
    /// 將新到站時間發布到所有運行中嘅巴士 ETA Live Activity。
    /// - Parameter etaDate: 更新後 ETA，會同時用於 Live Activity 狀態同過期時間。
    func updateLiveActivity(etaDate: Date) {
        Task {
            for activity in Activity<BusETAAttributes>.activities {
                let remaining = Int(etaDate.timeIntervalSince(Date()))
                let state = BusETAAttributes.ContentState(etaDate: etaDate, remainingSeconds: remaining)
                let expireDate = etaDate.addingTimeInterval(60)
                await activity.update(ActivityContent(state: state, staleDate: expireDate))
            }
        }
    }
    
    /// 將可選 ETA 格式化成精簡計時器顯示文字。
    /// - Parameter date: 要格式化嘅 ETA；`nil` 代表無可用時間。
    /// - Returns: `HH:mm` 字串；當 `date` 係 `nil` 時返回空字串。
    func formattedTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    /// 為目前啟用計時器排程唯一一個待發送嘅到站提示通知。
    /// - Parameters:
    ///   - routeName: 通知內容顯示嘅路線號碼。
    ///   - destination: 通知內容顯示嘅目的地。
    ///   - alertDate: 兩分鐘前提示應該送出嘅時間。
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
        UNUserNotificationCenter.current().add(request) { _ in }
    }
    
    /// 裝置允許 Live Activity 時，為巴士計時器啟動 Live Activity。
    /// - Parameters:
    ///   - routeName: Activity 顯示嘅路線號碼。
    ///   - company: Activity 屬性顯示嘅營辦商代碼。
    ///   - destination: Activity 顯示嘅路線目的地。
    ///   - stationName: Activity 顯示嘅站名。
    ///   - etaDate: 目前目標到站時間。
    ///   - startTime: 計時器建立時間，用嚟喺重新連接後保留活動內容。
    func startLiveActivity(routeName: String, company: String, destination: String, stationName: String, etaDate: Date, startTime: Date, stopId: String, direction: String, operatorStopIds: [String: String]) {
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                let attributes = BusETAAttributes(
                    routeName: routeName,
                    company: company,
                    destination: destination,
                    stationName: stationName,
                    startTime: startTime,
                    stopId: stopId,
                    direction: direction,
                    operatorStopIds: operatorStopIds
                )
                let remaining = Int(etaDate.timeIntervalSince(Date()))
                let state = BusETAAttributes.ContentState(etaDate: etaDate, remainingSeconds: remaining)
                let content = ActivityContent(state: state, staleDate: etaDate.addingTimeInterval(60))
                let _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                print("Error starting Live Activity: \(error.localizedDescription)")
            }
        }
    }
    
    /// 即時結束所有運行中嘅巴士 ETA Live Activity。
    ///
    /// 最終狀態會保留最後 ETA，但將剩餘秒數設為零，令活動可以乾淨地關閉。
    func endLiveActivity() async {
        for activity in Activity<BusETAAttributes>.activities {
            let state = BusETAAttributes.ContentState(etaDate: activity.content.state.etaDate, remainingSeconds: 0)
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
    }
    
    /// 應用程式啟動或返回前景後，從現有即時活動重建 `activeTimer`。
    ///
    /// 已過期活動會即時結束；如果目前無顯示計時器，仍然有效嘅活動會複製返到本地狀態。
    func reconnectActiveLiveActivity() {
        for activity in Activity<BusETAAttributes>.activities {
            let attributes = activity.attributes
            let state = activity.content.state
            
            if state.etaDate.timeIntervalSince(Date()) > 0 {
                if self.activeTimer == nil {
                    self.activeTimer = ActiveTimerModel(
                        routeName: attributes.routeName,
                        company: attributes.company,
                        destination: attributes.destination,
                        etaDate: state.etaDate,
                        targetAlertDate: state.etaDate.addingTimeInterval(-120),
                        startTime: attributes.startTime,
                        stopId: attributes.stopId,
                        direction: attributes.direction,
                        stationName: attributes.stationName,
                        operatorStopIds: attributes.operatorStopIds
                    )
                }
            } else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }
}
