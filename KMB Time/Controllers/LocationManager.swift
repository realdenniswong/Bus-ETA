/// 檔案用途：包裝 Core Location，提供前景定位同背景追蹤狀態。

import Foundation
import CoreLocation
import Combine

/// `LocationManager` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let foregroundAccuracy = kCLLocationAccuracyNearestTenMeters
    private let cachedLocationMaxAge: TimeInterval = 60
    private let cachedLocationMaxAccuracy: CLLocationAccuracy = 150
    
    @Published var location: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isLocating = false
    
    @Published var isBackgroundTracking = false
    @Published var backgroundHeartbeat = Date()
    
    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；完成物件初始化。
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = foregroundAccuracy
        manager.distanceFilter = 20
        self.authorizationStatus = manager.authorizationStatus
        self.location = recentCachedLocation
        
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        manager.pausesLocationUpdatesAutomatically = false
    }
    
    /// 向系統要求所需權限或資料。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func requestLocation() {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            isLocating = status == .notDetermined
            if status == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
            return
        }
        
        if let cachedLocation = recentCachedLocation {
            location = cachedLocation
            isLocating = false
        } else {
            isLocating = true
        }
        
        manager.desiredAccuracy = foregroundAccuracy
        manager.requestLocation()
    }
    
    /// 接收 Core Location 回呼並更新定位狀態。
    /// - Parameters:
    ///   - manager: 系統或 app manager 物件。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                self.requestLocation()
            } else {
                self.isLocating = false
            }
        }
    }
    
    /// 接收 Core Location 回呼並更新定位狀態。
    /// - Parameters:
    ///   - manager: 系統或 app manager 物件。
    ///   - didUpdateLocations: 用嚟計算距離嘅位置。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let first = locations.last else { return }
        DispatchQueue.main.async {
            self.location = first
            self.isLocating = false
            
            self.backgroundHeartbeat = Date()
            if !self.isBackgroundTracking {
                manager.stopUpdatingLocation()
            }
        }
    }
    
    /// 接收 Core Location 回呼並更新定位狀態。
    /// - Parameters:
    ///   - manager: 系統或 app manager 物件。
    ///   - didFailWithError: 系統回傳嘅錯誤。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed: \(error)")
        DispatchQueue.main.async {
            self.isLocating = false
        }
    }
    
    private var recentCachedLocation: CLLocation? {
        guard let cachedLocation = manager.location ?? location,
              cachedLocation.horizontalAccuracy >= 0,
              cachedLocation.horizontalAccuracy <= cachedLocationMaxAccuracy,
              abs(cachedLocation.timestamp.timeIntervalSinceNow) <= cachedLocationMaxAge else {
            return nil
        }
        return cachedLocation
    }
    
    /// 開始相關追蹤、活動或流程。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func startBackgroundTracking() {
        self.isBackgroundTracking = true
        self.manager.desiredAccuracy = kCLLocationAccuracyBest
        self.manager.allowsBackgroundLocationUpdates = true
        self.manager.showsBackgroundLocationIndicator = false
        self.manager.pausesLocationUpdatesAutomatically = false
        
        self.manager.startUpdatingLocation()
        print("🐛 [LocationManager] 背景定位已成功開火！")
    }

    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func stopBackgroundTracking() {
        self.isBackgroundTracking = false
        self.manager.stopUpdatingLocation()
        self.manager.desiredAccuracy = foregroundAccuracy
        print("🐛 [LocationManager] 背景定位已成功關閉。")
    }
}
