import ActivityKit
import SwiftUI
import UserNotifications

extension ContentView {
    /// Refreshes the active timer with the provider's latest ETA for the tracked stop.
    func syncActiveTimer() async {
        guard let timer = activeTimer, !timer.stopId.isEmpty else { return }
        let timerDirection = BusDirection(rawValue: timer.direction) ?? .outbound
        
        do {
            let provider = providerForRoute(route: timer.routeName, direction: timerDirection, stopId: timer.stopId)
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
    
    /// Pushes a new ETA state to any running Live Activity.
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
    
    /// Formats an optional date for alert copy.
    func formattedTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    /// Schedules the single local reminder used by the active timer.
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
    
    /// Starts a Live Activity for the selected ETA reminder.
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
    
    /// Ends every Live Activity created by this app.
    func endLiveActivity() {
        Task {
            for activity in Activity<BusETAAttributes>.activities {
                let state = BusETAAttributes.ContentState(etaDate: activity.content.state.etaDate, remainingSeconds: 0)
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
    
    /// Rehydrates `activeTimer` from an existing Live Activity after app launch or foregrounding.
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
