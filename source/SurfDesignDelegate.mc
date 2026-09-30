import Toybox.Application;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
// Math not imported — Math.abs() unavailable in SDK 3.x; using inline ternary instead
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;

// Garmin epoch starts 1989-01-01; Unix epoch starts 1970-01-01.
// WorldTides returns Unix timestamps. Time.now().value() returns Garmin epoch.
// Offset (seconds from Unix epoch to Garmin epoch) = 19 years = 599,616,000 s.
(:background)
const UNIX_EPOCH_OFFSET = 599616000;

// ─────────────────────────────────────────────────────────────────────────────
// SurfDesignDelegate — Background service for marine data fetching
//
// Phase 3.3 changes:
//   - WorldTides API key read from Properties (settings), not hardcoded
//   - Tide fetch skipped entirely when no key configured (UV replaces tide)
//   - UV index fetched from Open-Meteo Forecast API (free, no key needed)
//   - Diagnostic storage: delegateRunTime, httpCode* for debugging
//   - _finalize() extracts common exit logic (cacheTime + Background.exit)
//
// Chains sequential web requests:
//   1. Open-Meteo Marine   → wave height/period/direction, sea temp
//   2. Open-Meteo Forecast → air temp, wind, sunrise/sunset, UV index
//   3. WorldTides          → tide height + trend (only if API key configured)
//
// All results written to Application.Storage (shared with foreground view).
// ─────────────────────────────────────────────────────────────────────────────
(:background)
class SurfDesignDelegate extends System.ServiceDelegate {

    private var _lat        as Lang.Float   = -31.99f;  // Perth fallback
    private var _lon        as Lang.Float   = 115.74f;
    private var _hour       as Lang.Number  = 0;        // index into hourly arrays
    private var _anySuccess as Lang.Boolean = false;    // true if any API call succeeded

    function initialize() {
        ServiceDelegate.initialize();
    }

    // Entry point — called by OS on temporal event
    function onTemporalEvent() as Void {
        // Diagnostic: record when delegate ran
        Application.Storage.setValue("delegateRunTime", Time.now().value());

        var latRaw = Application.Storage.getValue("lat");
        var lonRaw = Application.Storage.getValue("lon");
        if (latRaw != null) { _lat = latRaw as Lang.Float; }
        if (lonRaw != null) { _lon = lonRaw as Lang.Float; }

        var info = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        _hour    = info.hour as Lang.Number;

        fetchMarineData();
    }

    // ── 1. Open-Meteo Marine — ocean variables only (no wind) ────────────────
    private function fetchMarineData() as Void {
        var url = "https://marine-api.open-meteo.com/v1/marine";
        var params = {
            "latitude"      => _lat.format("%.4f"),
            "longitude"     => _lon.format("%.4f"),
            "hourly"        => "wave_height,wave_period,wave_direction,sea_surface_temperature",
            "timezone"      => "auto",
            "forecast_days" => "1"
        };
        Communications.makeWebRequest(url, params,
            {:responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON},
            method(:onMarineResponse));
    }

    function onMarineResponse(code as Lang.Number, data as Lang.Dictionary?) as Void {
        Application.Storage.setValue("httpCodeMarine", code);
        if (code == 200 && data != null) {
            var h = data["hourly"] as Lang.Dictionary;
            var i = _hour;
            Application.Storage.setValue("waveHeight", ((h["wave_height"]            as Lang.Array)[i] as Lang.Numeric).toFloat());
            Application.Storage.setValue("wavePeriod", ((h["wave_period"]             as Lang.Array)[i] as Lang.Numeric).toFloat());
            Application.Storage.setValue("waveDir",    ((h["wave_direction"]          as Lang.Array)[i] as Lang.Numeric).toNumber());
            Application.Storage.setValue("seaTemp",    ((h["sea_surface_temperature"] as Lang.Array)[i] as Lang.Numeric).toFloat());
            _anySuccess = true;
        }
        fetchForecastData(); // always chain
    }

    // ── 2. Open-Meteo Forecast — air temp, wind, sunrise/sunset, UV index ────
    private function fetchForecastData() as Void {
        var url = "https://api.open-meteo.com/v1/forecast";
        var params = {
            "latitude"        => _lat.format("%.4f"),
            "longitude"       => _lon.format("%.4f"),
            "hourly"          => "temperature_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,uv_index",
            "daily"           => "sunrise,sunset",
            "wind_speed_unit" => "kn",
            "timezone"        => "auto",
            "forecast_days"   => "1"
        };
        Communications.makeWebRequest(url, params,
            {:responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON},
            method(:onForecastResponse));
    }

    function onForecastResponse(code as Lang.Number, data as Lang.Dictionary?) as Void {
        Application.Storage.setValue("httpCodeForecast", code);
        if (code == 200 && data != null) {
            var h = data["hourly"] as Lang.Dictionary;
            var i = _hour;

            // Air temp
            Application.Storage.setValue("airTemp",
                ((h["temperature_2m"] as Lang.Array)[i] as Lang.Numeric).toFloat());

            // Wind speed + direction
            Application.Storage.setValue("windSpeed",
                ((h["wind_speed_10m"]     as Lang.Array)[i] as Lang.Numeric).toFloat());
            Application.Storage.setValue("windGust",
                ((h["wind_gusts_10m"]     as Lang.Array)[i] as Lang.Numeric).toFloat());
            Application.Storage.setValue("windDir",
                ((h["wind_direction_10m"] as Lang.Array)[i] as Lang.Numeric).toNumber());

            // UV index
            var uvArr = h["uv_index"] as Lang.Array;
            if (uvArr != null && i < uvArr.size() && uvArr[i] != null) {
                Application.Storage.setValue("uvIndex",
                    (uvArr[i] as Lang.Numeric).toFloat());
            }

            // Wind min/max for the full day (all 24 hours of forecast)
            var speeds = h["wind_speed_10m"] as Lang.Array;
            var wMin = 9999.0f;
            var wMax = 0.0f;
            for (var j = 0; j < speeds.size(); j++) {
                var sf = (speeds[j] as Lang.Numeric).toFloat();
                if (sf < wMin) { wMin = sf; }
                if (sf > wMax) { wMax = sf; }
            }
            if (wMin == 9999.0f) { wMin = 0.0f; }
            Application.Storage.setValue("windMinKn", wMin);
            Application.Storage.setValue("windMaxKn", wMax);

            // Parse daily sunrise/sunset → store as total minutes from midnight
            if (data.hasKey("daily")) {
                var daily = data["daily"] as Lang.Dictionary;
                if (daily.hasKey("sunrise") && daily.hasKey("sunset")) {
                    var srStr = ((daily["sunrise"] as Lang.Array)[0]) as Lang.String;
                    var ssStr = ((daily["sunset"]  as Lang.Array)[0]) as Lang.String;
                    if (srStr.length() >= 16 && ssStr.length() >= 16) {
                        var srMins = srStr.substring(11, 13).toNumber() * 60 + srStr.substring(14, 16).toNumber();
                        var ssMins = ssStr.substring(11, 13).toNumber() * 60 + ssStr.substring(14, 16).toNumber();
                        Application.Storage.setValue("apiSunriseMins", srMins);
                        Application.Storage.setValue("apiSunsetMins",  ssMins);
                    }
                }
            }
            _anySuccess = true;
        }

        // Chain to tide (or finalize if no key)
        fetchTideData();
    }

    // ── 3. WorldTides — only if API key is configured in settings ────────────
    // URL built manually (heights is a flag param, no value).
    // WorldTides dt values are Unix timestamps; Time.now().value() is Garmin epoch.
    private function fetchTideData() as Void {
        var apiKey = Application.Properties.getValue("worldTidesApiKey") as Lang.String?;
        if (apiKey == null || apiKey.equals("")) {
            // No key configured → skip tide entirely
            Application.Storage.setValue("httpCodeTide", -1);
            _finalize();
            return;
        }

        var url = "https://www.worldtides.info/api/v3"
            + "?heights&lat=" + _lat.format("%.4f")
            + "&lon=" + _lon.format("%.4f")
            + "&key=" + apiKey
            + "&days=1&step=3600";
        Communications.makeWebRequest(url, null,
            {:responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON},
            method(:onTideResponse));
    }

    function onTideResponse(code as Lang.Number, data as Lang.Dictionary?) as Void {
        Application.Storage.setValue("httpCodeTide", code);
        if (code == 200 && data != null) {
            var heights = data["heights"] as Lang.Array;
            if (heights.size() > 0) {
                // Convert Garmin epoch → Unix epoch for comparison with WorldTides dt
                var nowUnix  = Time.now().value() + UNIX_EPOCH_OFFSET;
                var bestIdx  = 0;
                var diff0    = nowUnix - ((heights[0] as Lang.Dictionary)["dt"] as Lang.Number);
                var bestDiff = (diff0 >= 0) ? diff0 : -diff0;
                for (var i = 1; i < heights.size(); i++) {
                    var dRaw = nowUnix - ((heights[i] as Lang.Dictionary)["dt"] as Lang.Number);
                    var d    = (dRaw >= 0) ? dRaw : -dRaw;
                    if (d < bestDiff) { bestDiff = d; bestIdx = i; }
                }

                var curH  = ((heights[bestIdx] as Lang.Dictionary)["height"] as Lang.Numeric).toFloat();
                var prevH = (bestIdx > 0)
                    ? ((heights[bestIdx - 1] as Lang.Dictionary)["height"] as Lang.Numeric).toFloat()
                    : curH;

                var delta = curH - prevH;
                var trend = "Low";
                if (delta > 0.15f)       { trend = "Rising"; }
                else if (delta < -0.15f) { trend = "Falling"; }
                else if (curH > 0.7f)    { trend = "High"; }

                Application.Storage.setValue("tideHeight", curH);
                Application.Storage.setValue("tideTrend",  trend);
                _anySuccess = true;
            }
        }

        _finalize();
    }

    // ── Common exit: write cache timestamp + exit background ─────────────────
    private function _finalize() as Void {
        if (_anySuccess) {
            Application.Storage.setValue("cacheTime", Time.now().value());
        }
        Background.exit(null);
    }

}
