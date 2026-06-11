# Bus ETA

呢個 app 係用 SwiftUI 寫嘅香港巴士 ETA 工具，主要支援九巴、城巴同部分聯營路線。app 會載入靜態路線/站點資料，根據使用者位置搵附近車站，並用 provider 去即時 API 拎到站時間。

> Note: The public app display name is **Bus ETA**, but the Xcode project, target, and some internal names still use **KMB Time**. This app originally started as a KMB-only route ETA tool, so I kept the original project name to avoid unnecessary Xcode project churn while expanding the app to support Citybus and joint KMB/CTB routes.

## 主要結構

`ContentView` 係 app 狀態同 navigation 中心，持有 tab、搜尋文字、已選方向、已選公司、路線/站點查表、附近車站、收藏 ETA、active timer、toast、自訂鍵盤同 route detail navigation 狀態。主要邏輯拆咗做幾個 extension：

- `ContentView+RouteData`：載入靜態路線/站點 cache，背景刷新 KMB/CTB 資料，建立站名同站點查表。
- `ContentView+NearbyRoutes`：根據定位搵附近站點，分批載入附近路線 ETA，並管理首頁 ETA cache。
- `ContentView+RouteSearch`：處理路線搜尋、provider 選擇、站點高亮同 route detail 資料載入。
- `ContentView+FavouritesLogic`：更新收藏路線最近站點、距離同 ETA。
- `ContentView+TimerLogic`：同步 active timer、Live Activity 同本地通知。
- `ContentView+Refresh`：集中處理 30 秒刷新、返回前景刷新同過期 timer 清理。

畫面層拆咗做幾個 SwiftUI view：

- `DashboardView`：首頁搜尋、附近路線、建議路線同 active timer。
- `RouteDetailsView`：單一路線站序、ETA、收藏同重新整理。
- `FavouritesView`：收藏路線列表，同最近 ETA / 距離。
- `BusETAWidget`：Live Activity / widget 顯示。

資料層用 provider 同 manager 包住唔同職責：

- `BusETAProvider` 定義所有 provider 要提供嘅方法。
- `KMBETAProvider` 負責九巴 API。
- `CTBETAProvider` 負責城巴 API 同 CSV/API cache。
- `JointRouteETAProvider` 合併 KMB + CTB 聯營路線顯示。
- `RouteSuggestionCatalog` 負責搜尋建議、公司判斷同 KMB/CTB 建議合併。
- `LocationManager` 包裝前景定位、背景定位同 background heartbeat。
- `FavoritesManager` 用 `UserDefaults` 儲存收藏路線。
- `StaticRouteDataCache` 將路線建議同站點快照存入 app support directory，令下次啟動可以先用 cache 顯示。

## App 啟動流程

`KMB_TimeApp.body` 會建立 `ContentView`。

`ContentView.body` 會建立兩個 tab：首頁 `dashboardContentView` 同收藏頁 `favoritesTab`。首頁用 `NavigationStack` 加 `ScrollViewReader`，並用 `isNavigatingToRoute` 打開 `routeDetailView`。同時有兩個 timer：

- `refreshTimer`：每 30 秒呼叫 `refreshVisibleData()`，刷新目前可見嘅路線、附近 ETA、收藏 ETA 或 active timer。
- `clockTimer`：每 1 秒更新 `currentTime`，並呼叫 `clearExpiredTimerIfNeeded(referenceDate:)` 清走過期提醒。

`ContentView.body` 入面 `.task` 會按以下次序做一次啟動工作：

1. 如果定位已授權，呼叫 `locationManager.requestLocation()`。
2. 呼叫 `loadStaticRouteData()`。
3. `loadStaticRouteData()` 先試 `StaticRouteDataCache.load()`。如果有有效 cache，會立即 `applyStaticRouteData(routes:stops:)`，再用背景 `Task` 執行 `refreshStaticRouteData()`。
4. 如果無 cache，`loadStaticRouteData()` 會等待 `refreshStaticRouteData()` 完成，先令 app 有可用路線同站點資料。
5. `refreshStaticRouteData()` 會並行呼叫 `fetchAllRouteSuggestions()` 同 `fetchAllStops()`。
6. `fetchAllRouteSuggestions()` 會並行讀取 KMB 同 CTB route suggestions，再用 `RouteSuggestionCatalog.merged(kmb:ctb:)` 合併同排序。
7. `fetchAllStops()` 會並行讀取 KMB 同 CTB stops，再交畀 `applyStops(_:)` 建立 `allStops`、`stopDictionary` 同 `stopInfoDictionary`。
8. 靜態資料套用後，如果已有定位，`updateNearbyStopsAfterStaticDataLoad()` 會重建附近站點，並呼叫 `warmFavoriteETAsIfPossible()` 預熱收藏 ETA。
9. `reconnectActiveLiveActivity()` 嘗試由現有 Live Activity 重建 `activeTimer`，或者結束已過期嘅 activity。
10. `warmFavoriteETAsIfPossible()` 會喺收藏、定位同站點資料齊備，而且目前未有收藏狀態時，啟動第一次收藏 ETA 更新。
11. `UNUserNotificationCenter.current().requestAuthorization(...)` 會要求通知權限，供到站提醒使用。

啟動後仲有幾個 lifecycle 更新：

- `locationManager.location` 改變時，如果唔係背景追蹤中，就重新計算附近站點同預熱收藏 ETA。
- `locationManager.backgroundHeartbeat` 改變時，會檢查 active timer 是否過期。
- app 返回 `.active` 時，會重新接回 Live Activity、要求一次定位，並呼叫 `refreshVisibleData(rebuildNearbyWhenEmpty: true)`。
- route detail 關閉時，`clearRouteDetailState()` 會清走搜尋/站序/highlight/keyboard 狀態，然後用目前定位重建附近站點。

## 搜尋路線流程

使用者喺首頁輸入車號或揀搜尋建議時，`DashboardView` 會透過 callback 返到 `ContentView+Dashboard`：

1. 揀建議會呼叫 `openSuggestedRoute(_:)`。
2. `openSuggestedRoute(_:)` 設定 `searchText`、`selectedDirection`、`selectedCompany`，再設 `isNavigatingToRoute = true`。
3. 之後呼叫 `searchRoute(route:direction:company:findNearest:targetStopCode:shouldScroll:isRefresh:)`。
4. `searchRoute(...)` 用 `routeSuggestionCatalog.resolvedCompany(...)` 決定公司。
5. `fetchTimetableRows(route:direction:company:)` 根據公司轉去：
   - `kmbETAProvider.fetchTimetableRows(...)`
   - `ctbETAProvider.fetchTimetableRows(...)`
   - `jointRouteETAProvider.fetchTimetableRows(...)`
6. 回傳嘅 `[StopDisplayModel]` 會寫入 `displayData`，`RouteDetailsView` 就用佢顯示站序同 ETA。
7. 如果要自動捲到最近站，`highlightedStopIdForRouteSearch(...)` 會用 `locationManager.location` 同每個站距離揀最近。

## 附近路線流程

當定位更新時，`ContentView.body` 嘅 `.onChange(of: locationManager.location)` 會觸發：

1. 呼叫 `updateNearbyStops(userLocation:)`。
2. `nearbyStopModels(from:userLocation:radius:)` 由 `allStops` 篩出 300 米內車站。
3. `nearbyStopsForAllBusesMode(_:)` 逐個最近車站呼叫 `fetchRoutesForNearbyStop(_:)`。
4. `fetchRoutesForNearbyStop(_:)` 會按站點公司呼叫 KMB、CTB 或 Joint provider。
5. `dashboardRoutes(kmbRoutes:ctbRoutes:jointRoutes:)` 會移除重覆/聯營衝突，合併成首頁要顯示嘅路線。
6. `cachedRoute(_:stopId:forceRefresh:)` 用 `dashboardETAByKey` 做 30 秒 ETA cache，避免首頁太頻密打 API。
7. 結果寫入 `nearbyStops`，`NearbyDashboardSectionView` 負責畫出附近站同路線卡。

## 收藏流程

收藏資料由 `FavoritesManager` 管理：

1. 使用者喺路線詳情按收藏，`toggleCurrentRouteFavorite()` 會呼叫 `favoritesManager.toggleFavorite(...)`。
2. `FavoritesManager` 把 `[FavoriteRoute]` 編碼到 `UserDefaults`。
3. 收藏頁出現或 app 有定位時，`updateFavoriteETAs()` 會更新收藏狀態。
4. `updateFavoriteETAs()` 對每個收藏呼叫對應 provider 嘅 `fetchFavoriteStatus(for:context:)`。
5. provider 會根據使用者位置揀該路線最近車站，再拎 ETA。
6. 回傳嘅 `FavoriteStatusModel` 會存入 `favoriteStatus`，`FavouritesView` 用嚟顯示最近 ETA、車站名同距離。

## 到站提醒同 Live Activity

使用者可以由附近路線或路線詳情建立提醒：

1. `prepareNearbyTimerAlert(route:stopInfo:)` 或 `prepareRouteDetailTimerAlert(stop:etaDate:)` 會呼叫 `prepareTimerAlert(...)`。
2. `prepareTimerAlert(...)` 記低路線、公司、站點、方向同 ETA，然後打開確認 alert。
3. 使用者確認後，`confirmTimerAlert()` 建立 `ActiveTimerModel`。
4. 同一時間會呼叫：
   - `scheduleLocalNotification(routeName:destination:alertDate:)`
   - `startLiveActivity(routeName:company:destination:stationName:etaDate:startTime:)`
   - `locationManager.startBackgroundTracking()`
5. `syncActiveTimer()` 會用 provider 重新讀 timer 站點 ETA，如果 ETA 改變超過 10 秒，就更新 `activeTimer`、重新排 notification，同呼叫 `updateLiveActivity(etaDate:)`。
6. `clearExpiredTimerIfNeeded(referenceDate:)` 會喺 clock timer 或 background heartbeat 時清走過期提醒。
7. `cancelActiveTimer()` 會清除 active timer、結束 Live Activity、停止背景定位同移除 notification。

## 重新整理流程

app 每 30 秒由 `refreshTimer` 觸發 `refreshVisibleData(rebuildNearbyWhenEmpty:)`：

1. 如果正在路線詳情頁，會用目前 `searchText`、`selectedDirection`、`selectedCompany` 呼叫 `searchRoute(..., isRefresh: true)`。
2. 如果首頁有附近站，呼叫 `refreshNearbyETAs()`。
3. 如果附近站為空但有定位，且允許 rebuild，就呼叫 `updateNearbyStops(userLocation:)`。
4. 收藏資料會由 `warmFavoriteETAsIfPossible()` 或相關畫面 lifecycle 觸發更新。

## 快取策略

- `StaticRouteDataCache`：把 route suggestions 同 stops 存到 app cache directory，app 下次啟動可以先顯示舊資料，再背景更新。
- `CTBETAProvider`：用 actor `CTBDataStore` 管理 route list、CSV parse、API rows、ETA cache 同 in-flight task，避免重覆請求。
- `dashboardETAByKey`：首頁附近 ETA 短暫快取 30 秒，改善滑動同刷新體驗。

## 主要資料模型

- `RouteSuggestion`：搜尋建議用，包含公司、路線、方向、起點同終點。
- `StopInfo`：站點 id、中文名、座標同公司。
- `StopDisplayModel`：路線詳情每一個站嘅顯示資料。
- `NearbyStopModel`：首頁附近站連距離同路線列表。
- `NearbyRouteModel`：首頁附近路線卡。
- `ETADisplayInfo`：單一 ETA 時間、備註同公司。
- `FavoriteRoute` / `FavoriteStatusModel`：收藏路線同收藏頁狀態。
- `ActiveTimerModel`：目前啟用嘅到站提醒。
