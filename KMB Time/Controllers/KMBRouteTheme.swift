//
//  KMBRouteTheme.swift
//  KMB Time
//
//  Created by Dennis Wong on 6/8/26.
//

import SwiftUI

struct KMBRouteTheme {
    static func backgroundColor(route: String, company: String, allRoutes: [RouteSuggestion]) -> Color {
        if company == BusOperator.ctb.rawValue {
            return Color(red: 0xF7 / 255, green: 0xDE / 255, blue: 0x06 / 255)
        }
        if company == "KMB+CTB" {
            return Color(red: 0.12, green: 0.32, blue: 0.58)
        }
        return Color(red: 0.65, green: 0.08, blue: 0.12)
    }
    
    static func foregroundColor(route: String, company: String, allRoutes: [RouteSuggestion]) -> Color {
        if company == BusOperator.ctb.rawValue {
            return Color(red: 0x01 / 255, green: 0x5D / 255, blue: 0xA6 / 255)
        }
        return .white
    }
    
    static func color(route: String, company: String, allRoutes: [RouteSuggestion]) -> Color {
        backgroundColor(route: route, company: company, allRoutes: allRoutes)
    }
}
