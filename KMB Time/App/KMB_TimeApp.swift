/// 檔案用途：設定 KMB Time app 入口，負責載入主畫面。

import SwiftUI

@main
/// `MyApp` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
