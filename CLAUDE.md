# CLAUDE.md: instructions for Claude

This is **SwellVision**, a Garmin Connect IQ watch face written in Monkey C that shows
live surf conditions. The person using it probably has no coding experience. Explain
changes in one plain sentence, make one change at a time, build, and have them check the
simulator before the next change.

## Map

- `source/SurfDesignView.mc`: all drawing. The layout is computed from screen size
  (fractions of width/height), icons are drawn as vectors, colours follow a hierarchy
  (white time/date, light grey values, mid grey headers, dark grey labels).
- `source/SurfDesignDelegate.mc`: background service. Chain: GPS position →
  Open-Meteo Marine (swell, water temp) → Open-Meteo Forecast (wind, air temp, UV, sunrise)
  → WorldTides (only if the user set a key). Results go to `Application.Storage`.
- `source/SurfDesignApp.mc`: registers the temporal event (5 min first run, then 30 min,
  re-registered in `onBackgroundData`).
- `resources/properties.xml` + `resources/settings/settings.xml`: the optional WorldTides key.

## Build

Monkey C extension: `F5` / `Monkey C: Run`. Terminal:
`monkeyc.bat -d fr955 -f monkey.jungle -o bin\sv.prg -y developer_key.der -w`
then `connectiq.bat` and `monkeydo.bat bin\sv.prg fr955`.

## Rules

- 🔴 Never commit `developer_key.der` or any key. Never hardcode an API key; keys come from settings.
- Everything the background process touches needs `(:background)`. The simulator doesn't
  enforce it; the real watch silently never fetches ("Waiting for data" forever).
- Web requests only happen in the background delegate, never in the view.
- Keep refreshes at 30 minutes or longer for battery.
- To swap surf for another data source (weather, prices, scores), change the URLs and
  parsing in the delegate and the fields drawn in the view. Keep the storage pattern.
- Before the user publishes their own version: new UUID in `manifest.xml`, their own name.
