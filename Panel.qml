import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.howdyitskyle.weathering"
  ipcTarget: "io.github.howdyitskyle.weathering"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator compares against `slot.activeItem`, and
  // switchPanelFrom looks the slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    locationFile.reload()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    locationFile.reload()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingLocation) root.cancelEditingLocation()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // Parsed wttr.in j1 response. Kept on failure so stale data stays visible.
  property var report: null
  property var dailyForecastReport: null
  property var airQualityReport: null
  property string wttrLocation: ""

  // Configured location, read from the weather.json state file (owned by
  // omarchy-weather-location). The query is the wttr.in path segment
  // (coordinates when stored, else the encoded name); empty means IP
  // auto-detect. The watch makes hand edits take effect live.
  property var configuredLocationState: ({ name: "", latitude: null, longitude: null })
  readonly property string configuredLocation: configuredLocationState.name
  readonly property string locationQuery: Model.wttrLocationQuery(configuredLocationState.name, configuredLocationState.latitude, configuredLocationState.longitude)

  onLocationQueryChanged: {
    if (savingLocation) savingLocationQueryStarted = true
    forecastRetries = 0
    dailyForecastRetries = 0
    airQualityRetries = 0
    forecastProc.running = false
    dailyForecastProc.running = false
    airQualityProc.running = false
    forecastRetryTimer.stop()
    dailyForecastRetryTimer.stop()
    airQualityRetryTimer.stop()
    Qt.callLater(refresh)
  }

  property FileView locationFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.configuredLocationState = Model.parseLocationFile(text())
    onLoadFailed: root.configuredLocationState = Model.parseLocationFile("")
  }

  // The first read can race shell startup (observed sporadically), leaving a
  // stored location unhonored until the next file write. One delayed reload
  // self-corrects; if the first read was fine it's a no-op, since identical
  // state doesn't change locationQuery and so triggers no refetch.
  Timer {
    interval: 1500
    running: true
    onTriggered: locationFile.reload()
  }

  property int forecastRetries: 0
  property int dailyForecastRetries: 0
  property int airQualityRetries: 0
  property real lastLat: NaN
  property real lastLon: NaN

  // Click-to-edit state for the location label.
  property bool editingLocation: false
  property bool savingLocation: false
  property bool savingLocationQueryStarted: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""

  // Shared hero/bar icon state, updated with each successful weather response.
  property string label: ""

  // wttr's current conditions when available; open-meteo's (bundled with the
  // much faster daily forecast fetch) fill the hero while wttr is in flight.
  readonly property bool hasConfiguredCoordinates: !isNaN(parseFloat(String(configuredLocationState.latitude))) && !isNaN(parseFloat(String(configuredLocationState.longitude)))
  readonly property var openMeteoCurrent: Model.openMeteoCurrentCondition(dailyForecastReport)
  readonly property var current: (hasConfiguredCoordinates && openMeteoCurrent) ? openMeteoCurrent : ((report && report.current_condition && report.current_condition[0]) ? report.current_condition[0] : openMeteoCurrent)
  readonly property var areaInfo: report && report.nearest_area && report.nearest_area[0] ? report.nearest_area[0] : null
  readonly property string reportCountry: areaInfo && areaInfo.country && areaInfo.country[0] ? areaInfo.country[0].value : ""

  readonly property bool useImperial: Model.shouldUseImperial(setting("unit", ""), Qt.locale().name, reportCountry)

  // Auto-refresh interval in minutes; clamped to a sane minimum.
  readonly property int refreshMinutes: Math.max(5, parseInt(setting("refreshMinutes", 15), 10) || 15)

  // Feature toggles.
  readonly property bool showHourly: setting("showHourly", true) !== false
  readonly property bool showAirQuality: setting("showAirQuality", true) !== false
  readonly property bool showMetrics: setting("showMetrics", true) !== false
  readonly property bool showSun: setting("showSun", true) !== false
  readonly property bool show7day: setting("show7day", true) !== false
  readonly property bool showFeelsLike: setting("showFeelsLike", true) !== false
  // How many hourly cells to render; clamped so a bad value can't break layout.
  readonly property int hourlyCells: Math.max(3, Math.min(6, parseInt(setting("hourlyCells", 6), 10) || 6))

  readonly property string reportLocation: configuredLocation || wttrLocation || (areaInfo && areaInfo.areaName && areaInfo.areaName[0] ? areaInfo.areaName[0].value : "")
  readonly property string reportTempNum: current ? String(useImperial ? current.temp_F : current.temp_C) : ""
  readonly property string tempUnit: "°" + (useImperial ? "F" : "C")
  readonly property string reportFeels: current ? formatTemp(useImperial ? current.FeelsLikeF : current.FeelsLikeC) : ""
  readonly property string reportWindDir: openMeteoCurrent ? Model.windDirectionLabel(openMeteoCurrent.windDirection) : ""
  readonly property string reportWind: current ? ((useImperial ? (current.windspeedMiles + " mph") : (current.windspeedKmph + " km/h")) + (reportWindDir ? " " + reportWindDir : "")) : ""
  
  // Precipitation chance from the first upcoming hour — the headline question
  // after temperature. Lives in the hero stats instead of the duplicated
  // humidity (which already has its own METRICS card).
  readonly property string reportPrecip: hourly.length > 0 && hourly[0].precipProb !== "" ? (hourly[0].precipProb + "%") : ""

  // Sun / moon + UV come from the daily block (today's row).
  readonly property var todayExtra: Model.todayExtras(dailyForecastReport)
  readonly property string reportSunrise: todayExtra ? todayExtra.sunrise : ""
  readonly property string reportSunset: todayExtra ? todayExtra.sunset : ""
  readonly property var uv: (todayExtra && todayExtra.uv !== null && isFinite(todayExtra.uv)) ? Model.uvInfo(todayExtra.uv) : null
  
  // Forecast + air quality.
  readonly property var hourly: Model.hourlyForecast(dailyForecastReport, Qt.formatDateTime(new Date(), "yyyy-MM-ddThh:mm"))
  readonly property var daily: Model.dailyForecast(dailyForecastReport, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  readonly property var airQuality: Model.aqiSummary(airQualityReport)
  readonly property bool hasAirQuality: airQuality !== null
  // Safe alias: bindings evaluate even when the AQI section is hidden, so the
  // section reads from this never-null object instead of the nullable report.
  readonly property var aq: airQuality ? airQuality : ({ aqi: 0, pm25: "", pm10: "", info: null })

  // True once the current-condition fetches (wttr / open-meteo) have exhausted
  // their retries with no data yet — the placeholder then says it failed rather
  // than claiming it is still fetching. The refresh timer resets the counters
  // and tries again on schedule.
  readonly property bool weatherUnavailable: !root.current && (root.forecastRetries >= 3 || root.dailyForecastRetries >= 3)

  // Secondary text: the theme foreground at reduced opacity. Stock themes
  // define `muted` too dark for text on the dark popup surface (~2:1), and
  // Qt.darker(foreground, n) breaks on light themes — alpha on the primary
  // foreground stays readable on any background and follows theme swaps.
  readonly property color dimText: Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.8)

  // Uniform height for every METRICS grid cell, so the filled cards line up
  // in a clean grid regardless of whether a row has a level bar.
  readonly property int metricCellHeight: Style.space(60)

  // All-caps label tracking (location, stat labels, day names). QML
  // letterSpacing is in device pixels, so derive it from the base font to
  // keep the ~0.08em ratio when a theme overrides the font size.
  readonly property real capsLetterSpacing: Math.max(1, Math.round(Style.font.body * 0.08))

  // ---- Metric card values (2x2 grid) --------------------------------------
    readonly property string reportWindSpeed: openMeteoCurrent ? String(useImperial ? openMeteoCurrent.windspeedMiles : openMeteoCurrent.windspeedKmph) : ""
  readonly property string reportWindUnit: useImperial ? "mph" : "km/h"
  readonly property string reportWindDirName: openMeteoCurrent ? Model.windDirectionName(openMeteoCurrent.windDirection) : ""
  readonly property real windDeg: openMeteoCurrent && isFinite(Number(openMeteoCurrent.windDirection)) ? Number(openMeteoCurrent.windDirection) : -1
  // Pressure mapped to a 0..1 bar over the practical 950-1050 hPa span, so a
  // "Normal" reading (~1013 hPa) sits mid-bar and agrees with the Low/Normal/
  // High label rather than near-full (the old all-time-extremes 872-1080 range).
  readonly property real pressureLevel: openMeteoCurrent && openMeteoCurrent.pressureMb !== "" ? Math.max(0, Math.min(1, (Number(openMeteoCurrent.pressureMb) - 950) / (1050 - 950))) : -1
  readonly property real humidityLevel: openMeteoCurrent && openMeteoCurrent.humidity !== "" ? (Number(openMeteoCurrent.humidity) / 100) : -1
  readonly property real uvLevel: todayExtra && todayExtra.uv !== null && isFinite(todayExtra.uv) ? Math.max(0, Math.min(1, todayExtra.uv / 12)) : -1
  readonly property string hourlyMax: Model.hourlyMaxTemp(hourly, useImperial)


  function refresh() {
    forecastRetries = 0
    dailyForecastRetries = 0
    airQualityRetries = 0
    // Cancel any pending retries so a refresh can't stack stale requests on
    // top of a fresh cycle.
    forecastRetryTimer.stop()
    dailyForecastRetryTimer.stop()
    airQualityRetryTimer.stop()
    // wttr.in's full j1 fetch only serves the no-coordinates (IP auto-detect)
    // path — with configured coordinates Open-Meteo is authoritative, so skip
    // the extra external request entirely.
    if (!root.hasConfiguredCoordinates && !forecastProc.running) forecastProc.running = true
    if (root.locationQuery === "" && !locationProc.running) locationProc.running = true
    refreshDailyForecast(null)
  }

  function refreshDailyForecast(sourceReport) {
    if (dailyForecastProc.running) return

    var lat = parseFloat(String(root.configuredLocationState.latitude))
    var lon = parseFloat(String(root.configuredLocationState.longitude))
    if (isNaN(lat) || isNaN(lon)) {
      var area = sourceReport && sourceReport.nearest_area && sourceReport.nearest_area[0] ? sourceReport.nearest_area[0] : root.areaInfo
      if (!area) return
      lat = parseFloat(String(area.latitude || ""))
      lon = parseFloat(String(area.longitude || ""))
    }
    if (isNaN(lat) || isNaN(lon)) return

    root.lastLat = lat
    root.lastLon = lon

    var url = "https://api.open-meteo.com/v1/forecast"
      + "?latitude=" + encodeURIComponent(String(lat))
      + "&longitude=" + encodeURIComponent(String(lon))
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,wind_direction_10m,surface_pressure,weather_code,is_day"
      + "&hourly=temperature_2m,precipitation_probability,weather_code,is_day"
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max,precipitation_probability_max"
      + "&forecast_days=8"
      + "&timezone=auto"
    dailyForecastProc.command = ["curl", "-fsS", "--max-time", "5", url]
    dailyForecastProc.running = true

    if (root.showAirQuality) refreshAirQuality(lat, lon)
  }

  function refreshAirQuality(lat, lon) {
    if (airQualityProc.running) return
    var url = "https://air-quality-api.open-meteo.com/v1/air-quality"
      + "?latitude=" + encodeURIComponent(String(lat))
      + "&longitude=" + encodeURIComponent(String(lon))
      + "&current=us_aqi,pm10,pm2_5,nitrogen_dioxide,ozone"
      + "&timezone=auto"
    airQualityProc.command = ["curl", "-fsS", "--max-time", "5", url]
    airQualityProc.running = true
  }

  // ---- Location editing. Clicking the location label swaps it for a search
  //      field; picking a geocoded suggestion persists name + coordinates to
  //      the module's shell.json entry. An empty commit returns to auto.
  function startEditingLocation() {
    editingLocation = true
    savingLocation = false
    savingLocationQueryStarted = false
    locationSuggestions = []
    suggestionIndex = 0
    Qt.callLater(function() {
      locationField.text = root.configuredLocation
      locationField.selectAll()
      locationField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    editingLocation = false
    savingLocation = false
    savingLocationQueryStarted = false
    locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitLocation() {
    var location = Model.locationCommit(locationField.text, locationSuggestions, suggestionIndex)
    if (location.name === "") {
      clearLocation()
      return
    }
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = {
      name: location.name,
      latitude: location.latitude,
      longitude: location.longitude
    }
    persistLocation(location.name, location.latitude, location.longitude)
  }

  function clearLocation() {
    persistLocation("", null, null)
    wttrLocation = ""
    cancelEditingLocation()
  }

  function pickSuggestion(suggestion) {
    if (!suggestion) return
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = {
      name: suggestion.name,
      latitude: suggestion.latitude,
      longitude: suggestion.longitude
    }
    persistLocation(suggestion.name, suggestion.latitude, suggestion.longitude)
  }

  function finishSavingLocation() {
    if (savingLocation && savingLocationQueryStarted) cancelEditingLocation()
  }

  function persistLocation(name, latitude, longitude) {
    if (name && latitude !== null && longitude !== null)
      locationSaveProc.command = ["omarchy-weather-location", "--set", name, latitude + "," + longitude]
    else if (name)
      locationSaveProc.command = ["omarchy-weather-location", "--set", name]
    else
      locationSaveProc.command = ["omarchy-weather-location", "--clear"]
    locationSaveProc.running = true
  }

  // Debounced geocoding. Only one curl runs at a time; if the query moved on
  // while a fetch was in flight, the latest query is fetched right after.
  function requestGeocode() {
    var query = locationField.text.trim()
    if (query.length < 2) {
      locationSuggestions = []
      return
    }
    geocodePendingQuery = query
    if (!geocodeProc.running) startGeocode()
  }

  function startGeocode() {
    geocodeActiveQuery = geocodePendingQuery
    geocodeProc.command = ["curl", "-fsS", "--max-time", "5",
      "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(geocodeActiveQuery) + "&count=5&language=en&format=json"]
    geocodeProc.running = true
  }

  function formatTemp(value) {
    return Model.formatTemp(value, useImperial)
  }

  function dayName(dateString) {
    return Model.dayName(dateString, function(date) { return Qt.formatDate(date, "dddd") })
  }

  function dayAbbr(dateString) {
    return Model.dayName(dateString, function(date) { return Qt.formatDate(date, "ddd") })
  }

  function bareTempForDay(day, kind) {
    return Model.bareTempForDay(day, kind, useImperial)
  }

  function iconForOpenMeteoCode(code, night) {
    return Model.iconForOpenMeteoCode(code, night)
  }

  Process {
    id: forecastProc
    command: ["curl", "-fsS", "--max-time", "10", "https://wttr.in/" + root.locationQuery + "?format=j1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleForecastRetry()
          return
        }
        try {
          var parsed = JSON.parse(raw)
          root.report = parsed
          if (!root.hasConfiguredCoordinates)
            root.label = Model.provisionalCurrentIcon(parsed.current_condition && parsed.current_condition[0], root.label)
          root.forecastRetries = 0
          if (Model.weatherResponseCompletesSave(root.hasConfiguredCoordinates, "wttr"))
            root.finishSavingLocation()
          if (isNaN(parseFloat(String(root.configuredLocationState.latitude))))
            root.refreshDailyForecast(parsed)
        } catch (e) {
          root.scheduleForecastRetry()
        }
      }
    }
  }

  // wttr.in can be slow or flaky, especially for a location it hasn't
  // cached yet. Retry a few times before leaving it to the refresh timer.
  function scheduleForecastRetry() {
    if (forecastRetries >= 3) return
    forecastRetries++
    forecastRetryTimer.restart()
  }

  Timer {
    id: forecastRetryTimer
    interval: 2500
    onTriggered: if (!forecastProc.running) forecastProc.running = true
  }

  // With configured coordinates this fetch is the only thing that updates the
  // bar icon, so a dropped response must retry rather than wait out the
  // refresh timer with a stale icon.
  function scheduleDailyForecastRetry() {
    if (dailyForecastRetries >= 3) return
    dailyForecastRetries++
    dailyForecastRetryTimer.restart()
  }

  Timer {
    id: dailyForecastRetryTimer
    interval: 2500
    onTriggered: root.refreshDailyForecast(null)
  }

  function scheduleAirQualityRetry() {
    if (airQualityRetries >= 3) return
    airQualityRetries++
    airQualityRetryTimer.restart()
  }

  Timer {
    id: airQualityRetryTimer
    interval: 2500
    onTriggered: {
      if (root.showAirQuality && !isNaN(root.lastLat) && !isNaN(root.lastLon)) root.refreshAirQuality(root.lastLat, root.lastLon)
    }
  }

  Process {
    id: dailyForecastProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleDailyForecastRetry()
          return
        }
        try {
          var parsed = JSON.parse(raw)
          var parsedCurrent = Model.openMeteoCurrentCondition(parsed)
          root.dailyForecastReport = parsed
          root.label = Model.currentIcon(parsedCurrent, root.label)
          root.dailyForecastRetries = 0
          if (Model.weatherResponseCompletesSave(root.hasConfiguredCoordinates, "open-meteo"))
            root.finishSavingLocation()
        } catch (e) {
          root.scheduleDailyForecastRetry()
        }
      }
    }
  }

  Process {
    id: airQualityProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleAirQualityRetry()
          return
        }
        try {
          root.airQualityReport = JSON.parse(raw)
          root.airQualityRetries = 0
        } catch (e) {
          root.scheduleAirQualityRetry()
        }
      }
    }
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locationSuggestions = root.editingLocation ? Model.parseGeocodingResults(text) : []
        root.suggestionIndex = 0
        if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startGeocode)
      }
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  Process {
    id: locationSaveProc
    onExited: function(exitCode) {
      if (exitCode !== 0 || !root.savingLocation) return

      locationFile.reload()
      if (!root.savingLocationQueryStarted) {
        root.savingLocationQueryStarted = true
        root.forecastRetries = 0
        root.dailyForecastRetries = 0
        root.airQualityRetries = 0
        forecastProc.running = false
        dailyForecastProc.running = false
        airQualityProc.running = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: locationProc
    command: ["curl", "-fsS", "--max-time", "4", "https://wttr.in/?format=%l"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        root.wttrLocation = raw.split(",")[0]
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function edit(): void { root.openFromHotkey(); root.startEditingLocation() }
  }

KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(540))
    contentHeight: panel.fittedContentHeight(weatherColumn.implicitHeight)

    // No custom background layer: the KeyboardPanel's BorderSurface paints the
    // theme popup surface (Color.popups.background), so the panel follows the
    // theme on dark and light surfaces alike.

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation
      onReturnRequested: root.startEditingLocation()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: weatherScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: weatherColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: weatherColumn
          width: weatherScroll.width
          spacing: Style.space(18)

          // ---- Hero: big glyph + temp on the left; location + FEELS/WIND/PRECIP
          //      stats on the right, matching the built-in weather plugin.
          Item {
            width: parent.width
            height: Math.max(heroLeft.height, heroRight.height)

            Row {
              id: heroLeft
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(16)

              Text {
                id: heroIcon
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 5
                text: root.label || "—"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: 64
              }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  id: tempBig
                  text: root.reportTempNum || "—"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: 56
                  font.bold: true
                }

                Text {
                  text: root.current ? root.tempUnit : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.display
                  anchors.top: tempBig.top
                  anchors.topMargin: Style.space(10)
                }
              }
            }

            Column {
              id: heroRight
              width: weatherStats.implicitWidth
              anchors.right: parent.right
              anchors.rightMargin: Style.space(20)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(12)

              Row {
                visible: !root.editingLocation && root.reportLocation !== ""
                spacing: Style.space(6)

                TapHandler { onTapped: root.startEditingLocation() }
                HoverHandler { cursorShape: Qt.PointingHandCursor }

                Text {
                  text: "\uf041"
                  color: root.dimText
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: (root.reportLocation || "").toUpperCase()
                  color: root.dimText
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.letterSpacing: root.capsLetterSpacing
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Row {
                visible: root.editingLocation
                spacing: Style.space(6)

                TextField {
                  id: locationField
                  width: Style.space(190)
                  enabled: !root.savingLocation
                  placeholderText: "Search city"
                  foreground: root.bar.foreground
                  font.family: root.bar.fontFamily

                  onTextChanged: if (root.editingLocation && !root.savingLocation) geocodeDebounce.restart()

                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                      root.cancelEditingLocation()
                      event.accepted = true
                    } else if (event.key === Qt.Key_Down) {
                      if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                      event.accepted = true
                    } else if (event.key === Qt.Key_Up) {
                      if (root.suggestionIndex > 0) root.suggestionIndex--
                      event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      root.commitLocation()
                      event.accepted = true
                    }
                  }
                }

                Rectangle {
                  width: Style.space(18)
                  height: Style.space(18)
                  anchors.verticalCenter: parent.verticalCenter
                  radius: Math.min(4, Style.cornerRadius)
                  color: !root.savingLocation && clearLocationArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: root.savingLocation ? "󰦖" : "\u2715"
                    font.family: root.bar.fontFamily
                    color: root.dimText
                    font.pixelSize: Style.font.bodySmall

                    RotationAnimator on rotation {
                      running: root.savingLocation
                      from: 0; to: 360
                      duration: 800
                      loops: Animation.Infinite
                    }
                  }

                  MouseArea {
                    id: clearLocationArea
                    anchors.fill: parent
                    enabled: !root.savingLocation
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.clearLocation()
                  }
                }
              }

              Row {
                id: weatherStats
                visible: !!root.current
                spacing: Style.space(36)

                Column {
                  visible: root.showFeelsLike
                  spacing: Style.space(5)
                  Text {
                    text: "FEELS"
                    color: root.dimText
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.letterSpacing: root.capsLetterSpacing
                  }
                  Text {
                    text: root.reportFeels
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.title
                  }
                }

                Column {
                  spacing: Style.space(5)
                  Text {
                    text: "WIND"
                    color: root.dimText
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.letterSpacing: root.capsLetterSpacing
                  }
                  Text {
                    text: root.reportWind
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.title
                  }
                }

                Column {
                  spacing: Style.space(5)
                  Text {
                    text: "PRECIP"
                    color: root.dimText
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.letterSpacing: root.capsLetterSpacing
                  }
                  Text {
                    text: root.reportPrecip
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.title
                  }
                }
              }
            }
          }

          // ---- Geocoding suggestions while the location is being edited.
          Column {
            visible: root.editingLocation && !root.savingLocation && root.locationSuggestions.length > 0
            width: parent.width
            spacing: 0

            Repeater {
              model: root.locationSuggestions

              Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: suggestionRow.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: index === root.suggestionIndex ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                Row {
                  id: suggestionRow
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    text: modelData.name
                    color: index === root.suggestionIndex ? Style.hoverStateColor(root.bar.foreground, Color.accent) : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    visible: text !== ""
                    text: modelData.description
                    color: root.dimText
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: root.suggestionIndex = index
                  onClicked: root.pickSuggestion(modelData)
                }
              }
            }
          }

          Text {
            visible: !root.current
            text: root.weatherUnavailable ? "Couldn't reach the weather service — will retry." : "Fetching forecast…"
            color: root.dimText
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- HOURLY ----------------------------------------------------------
          PanelSeparator {
            strength: 0.2
            visible: root.showHourly && root.hourly.length > 0
            foreground: root.bar.foreground
          }

          Column {
            visible: root.showHourly && root.hourly.length > 0
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: hourHeader.implicitHeight

              PanelSectionHeader {
                id: hourHeader
                text: "HOURLY"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.hourlyMax !== ""
                spacing: Style.space(4)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󱃂"
                  color: root.dimText
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Day MAX " + root.hourlyMax
                  color: root.dimText
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Flickable {
              width: parent.width
              height: hourRow.implicitHeight
              contentWidth: hourRow.implicitWidth
              contentHeight: hourRow.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: hourRow.implicitWidth > width

              Row {
                id: hourRow
                width: parent.width
                spacing: Style.space(4)

                Repeater {
                  id: hourRepeater
                  model: root.hourly.length > root.hourlyCells ? root.hourly.slice(0, root.hourlyCells) : root.hourly

                  Item {
                    required property var modelData
                    required property int index
                    width: (hourRow.width - Style.space(4) * (hourRepeater.count - 1)) / hourRepeater.count
                    height: hourCellColumn.implicitHeight + Style.space(8)

                    Rectangle {
                      anchors.fill: parent
                      radius: Math.min(4, Style.cornerRadius)
                      color: index === 0 ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.1) : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.05)
                    }

                    Column {
                      id: hourCellColumn
                      width: parent.width
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(3)

                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: index === 0 ? "NOW" : modelData.time
                        color: index === 0 ? root.bar.foreground : root.dimText
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: index === 0
                      }
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.iconForOpenMeteoCode(modelData.code, modelData.night)
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.title
                      }
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        // The NOW cell mirrors the hero's live reading (current
                        // block) so the two never disagree; the rest use the
                        // hourly forecast.
                        text: index === 0 && root.reportTempNum !== "" ? root.reportTempNum + "°" : (useImperial ? modelData.tempF : modelData.tempC) + "°"
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                      }
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: text !== ""
                        text: modelData.precipProb !== "" ? (modelData.precipProb + "%") : ""
                        color: root.dimText
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }
            }
          }

          // ---- METRICS ----------------------------------------------------

          Column {
            visible: root.showMetrics && !!root.openMeteoCurrent
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "METRICS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(12)

            Row {
              width: parent.width
              spacing: Style.space(12)

              MetricCard {
                width: (parent.width - Style.space(12)) / 2
                height: root.metricCellHeight
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                label: "Wind"
                value: root.reportWindSpeed !== "" ? root.reportWindSpeed : "—"
                unit: root.reportWindSpeed !== "" ? root.reportWindUnit : ""
                desc: root.reportWindDirName
                arrowAngle: root.windDeg >= 0 ? root.windDeg : -1
              }

              MetricCard {
                width: (parent.width - Style.space(12)) / 2
                height: root.metricCellHeight
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                label: "Humidity"
                value: root.openMeteoCurrent ? Model.humidityLabel(root.openMeteoCurrent.humidity) : "—"
                unit: ""
                desc: root.openMeteoCurrent && root.openMeteoCurrent.humidity !== "" ? (root.openMeteoCurrent.humidity + "%") : ""
                valuePixelSize: Style.font.body
                barLevel: root.humidityLevel
                barColor: Util.alpha(Color.accent, 0.85)
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(12)

              MetricCard {
                width: (parent.width - Style.space(12)) / 2
                height: root.metricCellHeight
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                label: "Pressure"
                value: root.openMeteoCurrent ? Model.pressureLabel(root.openMeteoCurrent.pressureMb) : "—"
                unit: ""
                desc: root.openMeteoCurrent && root.openMeteoCurrent.pressureMb !== "" ? (root.openMeteoCurrent.pressureMb + " hPa") : ""
                valuePixelSize: Style.font.body
                barLevel: root.pressureLevel
                barColor: Util.alpha(Color.accent, 0.85)
              }

              MetricCard {
                width: (parent.width - Style.space(12)) / 2
                height: root.metricCellHeight
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                label: "UV"
                value: root.uv ? root.uv.label : "—"
                unit: ""
                desc: root.todayExtra && root.uv ? String(Math.round(root.todayExtra.uv)) : ""
                valuePixelSize: Style.font.body
                barLevel: root.uvLevel
                barColor: Util.alpha(Color.accent, 0.85)
              }
            }

            // Row 3: Air quality | Sun
            Row {
              width: parent.width
              spacing: Style.space(12)

              Rectangle {
                width: (parent.width - Style.space(12)) / 2
                height: root.metricCellHeight
                radius: Math.min(4, Style.cornerRadius)
                color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.05)
                visible: root.showAirQuality && root.hasAirQuality

                Column {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(5)

                  RowLayout {
                    width: parent.width
                    spacing: Style.space(8)

                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(1)

                      Text {
                        Layout.fillWidth: true
                        text: "Air Quality"
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }

                      Text {
                        Layout.fillWidth: true
                        text: String(root.aq.aqi)
                        color: root.dimText
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }

                      Text {
                        Layout.fillWidth: true
                        visible: text !== ""
                        text: (root.aq.pm25 !== "" ? "PM2.5 " + root.aq.pm25 + " · " : "") + (root.aq.pm10 !== "" ? "PM10 " + root.aq.pm10 : "")
                        color: root.dimText
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    Text {
                      Layout.alignment: Qt.AlignVCenter
                      text: root.aq.info ? root.aq.info.label : ""
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                  }
                }
              }

              Rectangle {
                width: (parent.width - Style.space(12)) / 2
                height: root.metricCellHeight
                radius: Math.min(4, Style.cornerRadius)
                color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.05)
                visible: root.showSun && root.reportSunrise !== "" && root.reportSunset !== ""

                Column {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(5)

                  RowLayout {
                    width: parent.width
                    spacing: Style.space(8)

                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(1)

                      Text {
                        Layout.fillWidth: true
                        text: "Sun"
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        Layout.fillWidth: true
                        text: "Rise " + root.reportSunrise
                        color: root.dimText
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        Layout.fillWidth: true
                        text: "Set " + root.reportSunset
                        color: root.dimText
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Text {
                      text: root.iconForOpenMeteoCode(0, false)
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.title
                      Layout.alignment: Qt.AlignVCenter
                    }
                  }
                }
              }
              }
            }
          }

          // ---- 7-DAY FORECAST ---------------------------------------------

          Column {
            visible: root.show7day && root.daily.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "7-DAY FORECAST"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.daily

                Rectangle {
                  required property var modelData
                  Layout.fillWidth: true
                  height: root.metricCellHeight + Style.space(8)
                  radius: Math.min(4, Style.cornerRadius)
                  color: modelData.isToday ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.1) : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.05)

                  Column {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Style.space(6)
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(3)

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: root.dayAbbr(modelData.date).toUpperCase()
                      color: modelData.isToday ? root.bar.foreground : root.dimText
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: modelData.isToday
                      font.letterSpacing: root.capsLetterSpacing
                    }

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: root.iconForOpenMeteoCode(modelData.code, false)
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.title
                    }

                    Row {
                      anchors.horizontalCenter: parent.horizontalCenter
                      spacing: Style.space(4)

                      Text {
                        text: root.bareTempForDay(modelData, "max")
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        text: root.bareTempForDay(modelData, "min")
                        color: root.dimText
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                      }
                    }
                  }
                }
              }
            }
          }

        }
      }
    }
  }
}
