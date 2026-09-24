# AGENTS.md

Context for agents working on the Weathering Omarchy plugin.

## What this is

A third-party Omarchy shell plugin (`bar-widget` kind): a pill in the bar plus a
nested details panel. QML entry points load inside the long-running
`omarchy-shell` (Quickshell) process; the plugin runs unsandboxed with the user's
permissions.

## Layout

- `manifest.json` — plugin contract (`bar-widget` kind, settings `schema`/`defaults`).
- `BarWidget.qml` — bar pill and shell-facing entry point. Loads `Panel.qml` via a
  permanent `Loader` (`active: true`, `visible: false`) and implements the shape
  contract Quattro's panel routing requires (`open`/`close`/`opened`/
  `popoutSwitchClosing`/`closeForPopoutSwitch`), forwarding each to the loaded
  panel. `injectPanel()` hands `bar`/`settings`/`anchorItem`/`hostWidget` to it.
  Right-click sends a notification via `omarchy-weather-status`; middle-click refreshes.
- `Panel.qml` — details panel, rclone-style sectioned layout: the built-in
  weather hero (64px glyph + 56px temp, location click-to-edit, FEELS/WIND/
  PRECIP stats), then `PanelSectionHeader` sections for the hourly strip (six
  cells, NOW highlighted), a METRICS grid (wind/humidity, pressure/UV, air
  quality/sun rows), and a 7-day strip (today highlighted). No custom surface:
  the KeyboardPanel paints the theme popup surface (`Color.popups.background`)
  so the panel follows dark and light themes. Cell wash is a foreground alpha:
  0.05 for the metric/AQ/Sun cards and non-highlighted strip cells, 0.1 for NOW
  /today. Fetches with `curl` via
  Quickshell `Process` blocks. Sets `manageIpc: false` and registers its own
  `IpcHandler` (target = `ipcTarget`).
- `Model.js` — pure JS helpers (parsing, unit conversion, weather-code → glyph, wind
  direction, UV/AQI bucketing). Imported as `import "Model.js" as Model`; also has a
  guarded `module.exports` for standalone use. Not a `.pragma library`.
- `MetricCard.qml` — row-style metric cell (label + desc left, value + unit right,
  thin theme-accent level bar / wind arrow). Its `arrowAngle` points the direction
  the wind comes FROM, matching the desc label (e.g. "South").
- `test/glyph-coverage.py` — standalone (no fontTools) font check: every PUA glyph
  in the repo's `*.qml` + `*.js` must exist in JetBrainsMono Nerd Font. Run with
  `python3 test/glyph-coverage.py`; use `--find <name>` to look a glyph up.
- `PanelCard.qml`, `Stat.qml` — legacy card components from the old card-style
  layout; no longer referenced by `Panel.qml`, kept for reference only.
- `README.md`, `LICENSE`, `preview.png` — publishing. `preview.png` in the repo
  root doubles as the marketplace listing preview.

## Data

All from free, keyless services:

- `api.open-meteo.com/v1/forecast` — current + hourly + daily (sunrise/sunset,
  uv_index_max, precipitation_probability_max); `forecast_days=8`, `timezone=auto`.
- `air-quality-api.open-meteo.com/v1/air-quality` — `current=us_aqi,pm10,pm2_5,...`.
- `geocoding-api.open-meteo.com/v1/search` — city search in the panel.
- `wttr.in` — current condition + auto-location fallback, exactly like the built-in
  `omarchy.weather`.

Two current-condition sources, selected by `hasConfiguredCoordinates`: with stored
coordinates, Open-Meteo's current (bundled with the fast daily forecast) is
authoritative; without them, wttr.in fills the hero. The wttr icon only ever fills an
empty initial state — it never replaces a day/night-aware Open-Meteo glyph
(`provisionalCurrentIcon`). `weatherResponseCompletesSave` decides which response
finishes the location-save flow.

Fetch policy: fetches fire on open, on location change, and on a `refreshTimer` that
runs unconditionally (`running: true`, `triggeredOnStart`) — it keeps fetching every
`refreshMinutes` even while the panel is closed. Each `Process` is guarded against
concurrent runs; failed responses retry up to 3 times (2.5s apart) before leaving
stale data visible. To avoid wasted external requests, the wttr.in `forecastProc`
only fires when there are **no** configured coordinates (IP auto-detect), and the
air-quality fetch only fires when `showAirQuality` is true. A refresh/location change
cancels any pending retry timers so requests can't stack. With no data at all, the
placeholder switches from "Fetching forecast…" to a couldn't-reach message once the
retries are exhausted (`weatherUnavailable`).

## Location

Shared with the built-in weather widget: read/write
`~/.local/state/omarchy/settings/weather.json` (`{name, latitude, longitude}`, blank =
IP auto-detect), via `omarchy-weather-location` for writes and a bounded read for
reads. Don't introduce a second location store. Content is read with a `Process`
(`sh -c`) that only reads a regular file under a 4096-byte cap (`[ -f ]` + `stat`
size check + `head -c` transfer cap); a `FileView` (`preload: false`) is kept
purely as a `watchChanges` notifier so hand edits still trigger `readLocationFile()`.
A delayed 1.5s reload after startup self-corrects a first-read race.

## Settings

Read from the bar layout entry in `~/.config/omarchy/shell.json` via `setting(key,
default)` — settings are inline on the entry, no per-plugin config file. Keys and
defaults come from the manifest `barWidget.schema`/`defaults` (`unit`, `refreshMinutes`,
`showHourly`, `showAirQuality`, `showMetrics`, `showSun`, `show7day`,
`showFeelsLike`, `hourlyCells`).

## Dev loop

- Plugin id: `io.github.howdyitskyle.weathering`.
- Installed copy: `~/.config/omarchy/plugins/io.github.howdyitskyle.weathering/`
  (copy files there; saving under the folder hot-reloads).
- Force discovery: `omarchy-shell shell rescanPlugins`; status: `omarchy plugin list --json`.
- Validate: `omarchy plugin validate <plugin-folder>` and
  `qmllint -I "$OMARCHY_PATH/shell" <plugin-folder>/BarWidget.qml <plugin-folder>/Panel.qml`.
- Shell log: `qs log -p "$OMARCHY_PATH/shell" --tail 100`.
- Test lifecycle: `omarchy-shell shell summon|toggle|hide <id> '{}'` (routed to the
  BarWidget's `open`/`close`).

## Conventions

- Keep `moduleName` equal to the manifest id in both QML files; `Panel.qml` also sets
  `ipcTarget` to the same id (paired with `manageIpc: false` and its `IpcHandler`).
- Match the built-in `panels/weather/` plugin's structure and the third-party
  `io.github.woogy7.vitals` plugin's patterns.
- QML bindings evaluate even when an item is `visible: false` — guard every
  possibly-null property access (see the `aq` safe alias in `Panel.qml`).
- Typography: always `font.family: root.bar.fontFamily` (or a component's
  `fontFamily` prop defaulting to `Style.font.family`) and sizes from
  `Style.font.*` tokens — never literal px except the hero's deliberate 64/56
  oversizes. All-caps labels use `root.capsLetterSpacing` (scaled ~0.08em) so
  tracking survives theme font overrides; no letter-spacing on body text.
  Temperature readouts use `body` in the hourly/7-day strips, `title` in the
  hero stats, and the oversized 56px only in the hero.
- No comments unless they explain a non-obvious decision (existing code style).
- `qmllint` in this repo's environment (v1.0, a minimal verifier) rejects the
  `: void` return-type annotations used on `IpcHandler` methods; ignore that
  false positive and keep the annotations (they match the built-in plugins).