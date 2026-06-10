/// 檔案用途：管理到站提醒、Live Activity 同本地通知。
import ActivityKit
import SwiftUI
import UserNotifications

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func syncActiveTimer() async {
        guard let timer = activeTimer, !timer.stopId.isEmpty else { return }
        let timerDirection = BusDirection(rawValue: timer.direction) ?? .outbound
        
        do {
            let provider = providerForCompany(timer.company)
            let etas = try await provider.fetchTimerETAs(route: timer.routeName, direction: timerDirection, stopId: timer.stopId)
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
            if alertDate.timeIntervalSince(Date()) > 0 {
                scheduleLocalNotification(routeName: timer.routeName, destination: timer.destination, alertDate: alertDate)
            }
            updateLiveActivity(etaDate: newEtaDate)
        } catch {
            print("Active timer sync failed: \(error)")
        }
    }
    
    /// 更新相關狀態，令畫面或快取保持最新。
    /// - Parameters:
    ///   - etaDate: 時間或到站時間資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
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
    
    /// 將資料格式化成畫面顯示文字。
    /// - Parameters:
    ///   - date: 時間或到站時間資料。
    /// - Returns: 格式化或查找後嘅文字。
    func formattedTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - routeName: 路線編號或路線模型。
    ///   - destination: 畫面顯示文字。
    ///   - alertDate: 時間或到站時間資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
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
    
    /// 開始相關追蹤、活動或流程。
    /// - Parameters:
    ///   - routeName: 路線編號或路線模型。
    ///   - company: 巴士公司代碼。
    ///   - destination: 畫面顯示文字。
    ///   - stationName: 車站識別或車站資料。
    ///   - etaDate: 時間或到站時間資料。
    ///   - startTime: 時間或到站時間資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func startLiveActivity(routeName: String, company: String, destination: String, stationName: String, etaDate: Date, startTime: Date) {
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                let attributes = BusETAAttributes(routeName: routeName, company: company, destination: destination, stationName: stationName, startTime: startTime)
                let remaining = Int(etaDate.timeIntervalSince(Date()))
                let state = BusETAAttributes.ContentState(etaDate: etaDate, remainingSeconds: remaining)
                let content = ActivityContent(state: state, staleDate: etaDate.addingTimeInterval(60))
                let _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                print("Error starting Live Activity: \(error.localizedDescription)")
            }
        }
    }
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func endLiveActivity() {
        Task {
            for activity in Activity<BusETAAttributes>.activities {
                let state = BusETAAttributes.ContentState(etaDate: activity.content.state.etaDate, remainingSeconds: 0)
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
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
                        stopId: "",
                        direction: "",
                        stationName: attributes.stationName
                    )
                }
            } else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }
}
