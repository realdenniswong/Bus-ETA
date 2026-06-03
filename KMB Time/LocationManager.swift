//
//  LocationManager.swift
//  KMB Time
//
//  Created by Antigravity on 5/31/26.
//

import Foundation
import CoreLocation
import Combine

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    
    @Published var location: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isLocating = false
    
    @Published var isBackgroundTracking = false
    @Published var backgroundHeartbeat = Date()
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        self.authorizationStatus = manager.authorizationStatus
        
        // 🌟 在你的 LocationManager 初始化地方加上：
        manager.allowsBackgroundLocationUpdates = true  // 允許在背景持續拿定位（這是不被急凍的關鍵）
        manager.showsBackgroundLocationIndicator = false // 設為 false，用家頂部唔會出現藍色定位長條，最神祕、最唔打擾
        manager.pausesLocationUpdatesAutomatically = false // 防止 iOS 覺得你停喺度等車就自動幫你熄咗定位
    }
    
    func requestLocation() {
        isLocating = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        } else {
            // Already denied or restricted
            isLocating = false
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                manager.startUpdatingLocation()
            } else {
                self.isLocating = false
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let first = locations.last else { return }
        DispatchQueue.main.async {
            self.location = first
            self.isLocating = false
            
            // 👇 替換成呢幾行：每次定位更新就發送心跳，而且背景追蹤時唔好自動熄定位！
            self.backgroundHeartbeat = Date()
            if !self.isBackgroundTracking {
                manager.stopUpdatingLocation()
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed: \(error)")
        DispatchQueue.main.async {
            self.isLocating = false
        }
    }
    
    // 🌟 請加在你的 LocationManager 類別入面：
    func startBackgroundTracking() {
        self.isBackgroundTracking = true // 👇 加呢行
        // 確保開啟背景特權配置
        self.manager.allowsBackgroundLocationUpdates = true
        self.manager.showsBackgroundLocationIndicator = false
        self.manager.pausesLocationUpdatesAutomatically = false
        
        // 正式開火
        self.manager.startUpdatingLocation()
        print("🐛 [LocationManager] 背景定位已成功開火！")
    }

    func stopBackgroundTracking() {
        self.isBackgroundTracking = false // 👇 加呢行
        // 關燈收工，交還特權
        self.manager.stopUpdatingLocation()
        print("🐛 [LocationManager] 背景定位已成功關閉。")
    }
}
