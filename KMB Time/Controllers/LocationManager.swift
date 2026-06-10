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
    private let foregroundAccuracy = kCLLocationAccuracyNearestTenMeters
    private let cachedLocationMaxAge: TimeInterval = 60
    private let cachedLocationMaxAccuracy: CLLocationAccuracy = 150
    
    @Published var location: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isLocating = false
    
    @Published var isBackgroundTracking = false
    @Published var backgroundHeartbeat = Date()
    
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
    
    private var recentCachedLocation: CLLocation? {
        guard let cachedLocation = manager.location ?? location,
              cachedLocation.horizontalAccuracy >= 0,
              cachedLocation.horizontalAccuracy <= cachedLocationMaxAccuracy,
              abs(cachedLocation.timestamp.timeIntervalSinceNow) <= cachedLocationMaxAge else {
            return nil
        }
        return cachedLocation
    }
    
    func startBackgroundTracking() {
        self.isBackgroundTracking = true
        self.manager.desiredAccuracy = kCLLocationAccuracyBest
        self.manager.allowsBackgroundLocationUpdates = true
        self.manager.showsBackgroundLocationIndicator = false
        self.manager.pausesLocationUpdatesAutomatically = false
        
        self.manager.startUpdatingLocation()
        print("🐛 [LocationManager] 背景定位已成功開火！")
    }

    func stopBackgroundTracking() {
        self.isBackgroundTracking = false
        self.manager.stopUpdatingLocation()
        self.manager.desiredAccuracy = foregroundAccuracy
        print("🐛 [LocationManager] 背景定位已成功關閉。")
    }
}
