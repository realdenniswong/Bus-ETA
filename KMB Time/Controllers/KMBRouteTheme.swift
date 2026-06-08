//
//  KMBRouteTheme.swift
//  KMB Time
//
//  Created by Dennis Wong on 6/8/26.
//

import SwiftUI

struct KMBRouteTheme {
    static func color(route: String, company: String, allRoutes: [RouteSuggestion]) -> Color {
        if company == BusOperator.ctb.rawValue {
            return Color(red: 0.0, green: 0.42, blue: 0.72)
        }
        if company == "KMB+CTB" {
            return Color(red: 0.12, green: 0.32, blue: 0.58)
        }
        return Color(red: 0.65, green: 0.08, blue: 0.12)
    }
}
