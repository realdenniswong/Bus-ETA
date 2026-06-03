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
        
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        manager.pausesLocationUpdatesAutomatically = false
    }
    
    func requestLocation() {
        isLocating = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        } else {
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
    
    func startBackgroundTracking() {
        self.isBackgroundTracking = true
        self.manager.allowsBackgroundLocationUpdates = true
        self.manager.showsBackgroundLocationIndicator = false
        self.manager.pausesLocationUpdatesAutomatically = false
        
        self.manager.startUpdatingLocation()
        print("🐛 [LocationManager] 背景定位已成功開火！")
    }

    func stopBackgroundTracking() {
        self.isBackgroundTracking = false
        self.manager.stopUpdatingLocation()
        print("🐛 [LocationManager] 背景定位已成功關閉。")
    }
}
