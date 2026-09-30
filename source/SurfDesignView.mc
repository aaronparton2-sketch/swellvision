import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;

// ─────────────────────────────────────────────────────────────────────────────
// SurfDesignView — Phase 3.3: Background Fix, Settings, UV/Tide Toggle
//
// Phase 3.3 changes:
//   - drawDataStatus(): shows "Waiting for data..." or "Xm ago" between sun/battery
//   - Dynamic left column row 3: UV index (default) or tide (if WorldTides key set)
//   - _drawUVIcon(): vector sun icon for UV index display
//   - _classifyUV(): UV index → classification label
//   - _loadCachedData() / _demoData() updated for UV/tide toggle via "hasTide" flag
//
// Architecture:
//   _computeLayout(dc)       → all coordinates derived from screen dims
//   drawHeader(...)          → Zone 1: date + activity stack (steps/cal/HR)
//   drawTime(...)            → Zone 2: dominant time display
//   drawMarine(...)          → Zone 3: 3×3 marine data grid (UV or tide in row 3)
//   drawSunTimes(...)        → Zone 4: vector sunrise/sunset + times
//   drawDataStatus(...)      → Zone 4b: data freshness indicator
//   drawBattery(...)         → Zone 5: bottom arc concentric with watch face
// ─────────────────────────────────────────────────────────────────────────────

// ── Debug flags ───────────────────────────────────────────────────────────────
const DEBUG_SAFE_AREA   = false; // true → draw grey safe-circle overlay for QA
const DEBUG_DEMO_STATS  = false; // true → show realistic demo values for steps/cal/HR
                                  //        (simulator returns 0/null; set false on real device)

// ── Colour palette ────────────────────────────────────────────────────────────
const COLOR_BG         = 0x000000;  // Black background
const COLOR_WHITE      = 0xFFFFFF;  // Date, time, primary labels
const COLOR_VALUE      = 0xFFFFFF;  // Numeric values (temps, m, s, kn, °) — white
const COLOR_DESC       = 0x666666;  // Descriptor labels (Warm/High/Low…) — dimmer for hierarchy
const COLOR_SUBTLE     = 0xB1B1B1;  // Column headers, secondary elements
const COLOR_CYAN_MID   = 0x606060;  // Divider/separator lines (subtle grey — named for legacy)
const COLOR_CYAN       = 0x33B0E2;  // Swell direction arrow + accent elements
const COLOR_RED        = 0xF03B31;  // Wind direction arrow ONLY
const COLOR_ORANGE     = 0xBA4609;  // Sunrise/sunset icons + FL/LL labels
const COLOR_BATTERY    = 0x3B7D23;  // Battery fill (green)

// ── Fallback GPS (Perth/Cottesloe) ────────────────────────────────────────────
const FALLBACK_LAT_DEG = -31.99f;
const FALLBACK_LON_DEG = 115.74f;

// ── Layout tuning constants ───────────────────────────────────────────────────
const ICON_W_TOP  = 17;   // steps/cal icon width (px)
const ICON_H_TOP  = 17;   // steps/cal icon height (px)
const ICON_W_HR   = 14;   // heart rate icon width — visually smaller than steps/cal
const ICON_H_HR   = 14;   // heart rate icon height
const ICON_W_GRID = 19;   // marine grid icon width (px)
const ICON_H_GRID = 19;   // marine grid icon height (px)
const CAL_IC_SIZE = 18;   // calendar vector icon drawn size (px)
const SUN_IC_SIZE = 18;   // sunrise/sunset vector icon drawn size (px)

// ── Typography spacing ────────────────────────────────────────────────────────
const LINE_GAP_PX    = 7;  // half-gap: value at rowCY-LINE_GAP_PX, desc at rowCY+LINE_GAP_PX
const SOLAR_LINE_GAP = 7;  // half-gap: FL at sunCY-SOLAR_LINE_GAP, SR at sunCY+SOLAR_LINE_GAP
const STATS_ROW_GAP  = 16; // px between each top-left stat row (steps / cal / HR)
const GRID_TOP_PADDING    = 8;  // px from colHeader centre to first row centre (tighter = bigger rowSpacing)
const GRID_BOTTOM_PADDING = 6;  // px from last row centre to bottom divider

// ── Battery icon constants ────────────────────────────────────────────────────
const BAT_ICON_W   = 18;  // battery outline width (px)
const BAT_ICON_H   = 10;  // battery outline height (px)
const BAT_ICON_NUB = 3;   // nub width on right side (px)
const BAT_Y_INSET  = 7;   // batTextY = safeBot - BAT_Y_INSET (lower = move down)
const BAT_ICON_GAP = 4;   // gap between icon and text

class SurfDesignView extends WatchUi.WatchFace {

    // ── Cached screen geometry ─────────────────────────────────────────────────
    private var _w  as Lang.Number = 260;
    private var _h  as Lang.Number = 260;
    private var _cx as Lang.Number = 130;
    private var _cy as Lang.Number = 130;

    // ── Cached layout dictionary (set in onLayout, reused every minute) ────────
    private var _layout as Lang.Dictionary? = null;

    // ── Bitmap resources (loaded in initialize) ───────────────────────────────
    // Only header icons still use PNGs. Marine grid icons replaced by vector functions.
    private var _icSteps   as WatchUi.BitmapResource? = null;
    private var _icCal     as WatchUi.BitmapResource? = null;
    private var _icHR      as WatchUi.BitmapResource? = null;
    private var _icWeather as WatchUi.BitmapResource? = null;
    private var _icWaterT  as WatchUi.BitmapResource? = null;
    private var _icSwellSz as WatchUi.BitmapResource? = null;

    // =========================================================================
    // initialize — load bitmaps once (only header + 3 marine row-1/row-2 icons)
    // =========================================================================
    function initialize() {
        WatchFace.initialize();

        _icSteps   = WatchUi.loadResource(Rez.Drawables.steps_white)             as WatchUi.BitmapResource;
        _icCal     = WatchUi.loadResource(Rez.Drawables.calories_white)          as WatchUi.BitmapResource;
        _icHR      = WatchUi.loadResource(Rez.Drawables.heart_rate_white)        as WatchUi.BitmapResource;
        _icWeather = WatchUi.loadResource(Rez.Drawables.outside_weather_colored) as WatchUi.BitmapResource;
        _icWaterT  = WatchUi.loadResource(Rez.Drawables.water_temp_colored)      as WatchUi.BitmapResource;
        _icSwellSz = WatchUi.loadResource(Rez.Drawables.swell_size)             as WatchUi.BitmapResource;
    }

    // =========================================================================
    // onLayout — cache screen geometry + compute layout once per layout change
    // =========================================================================
    function onLayout(dc as Graphics.Dc) as Void {
        _w  = dc.getWidth();
        _h  = dc.getHeight();
        _cx = _w / 2;
        _cy = _h / 2;
        _layout = _computeLayout(dc);
        setLayout(Rez.Layouts.WatchFace(dc));
    }

    function onShow() as Void {}
    function onHide() as Void {}

    // =========================================================================
    // onUpdate — called every minute (or on wake/tap)
    // =========================================================================
    function onUpdate(dc as Graphics.Dc) as Void {

        // ── Clear screen ──────────────────────────────────────────────────────
        dc.setColor(COLOR_BG, COLOR_BG);
        dc.clear();

        // ── Debug: safe area circle ────────────────────────────────────────────
        if (DEBUG_SAFE_AREA && _layout != null) {
            dc.setColor(0x444444, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(_cx, _cy, (_layout as Lang.Dictionary)["safeR"] as Lang.Number);
        }

        // ── GPS position ──────────────────────────────────────────────────────
        var latDeg = FALLBACK_LAT_DEG;
        var lonDeg = FALLBACK_LON_DEG;
        var posInfo = Position.getInfo();
        if (posInfo != null && posInfo.position != null) {
            var coords = posInfo.position.toDegrees();
            latDeg = coords[0].toFloat();
            lonDeg = coords[1].toFloat();
        }
        // Persist GPS for background delegate (reads from Storage in onTemporalEvent)
        Application.Storage.setValue("lat", latDeg);
        Application.Storage.setValue("lon", lonDeg);

        // ── Native data ────────────────────────────────────────────────────────
        var clockTime  = System.getClockTime();
        var now        = Time.now();
        var dateInfo   = Gregorian.info(now, Time.FORMAT_MEDIUM);  // string month/dow
        var dateNum    = Gregorian.info(now, Time.FORMAT_SHORT);   // numeric for solar math
        var sysStats   = System.getSystemStats();
        var actInfo    = ActivityMonitor.getInfo();

        var steps    = (actInfo.steps    != null) ? actInfo.steps    : 0;
        var calories = (actInfo.calories != null) ? actInfo.calories : 0;

        var hrValue  = "--";
        var activityInfo = Activity.getActivityInfo();
        if (activityInfo != null && activityInfo.currentHeartRate != null) {
            hrValue = activityInfo.currentHeartRate.toString();
        }

        // Demo fallback: simulator returns 0/null — use realistic values so the
        // layout looks correct while testing. Set DEBUG_DEMO_STATS=false for device.
        if (DEBUG_DEMO_STATS) {
            if (steps    == 0)           { steps    = 9500; }
            if (calories == 0)           { calories = 1700; }
            if (hrValue.equals("--"))    { hrValue  = "55"; }
        }

        var batteryPct = sysStats.battery.toNumber();

        var sunTimes = _computeSunTimes(dateNum.year, dateNum.month, dateNum.day, latDeg, lonDeg);

        // Override sunrise/sunset with API data when available (more trusted source).
        // First light and last light remain from solar math (accurate for any latitude).
        var apiSrMins = Application.Storage.getValue("apiSunriseMins");
        var apiSsMins = Application.Storage.getValue("apiSunsetMins");
        if (apiSrMins != null && apiSsMins != null) {
            sunTimes.put("sunrise", _minsToHHMM(apiSrMins as Lang.Number));
            sunTimes.put("sunset",  _minsToHHMM(apiSsMins as Lang.Number));
        }

        // ── Ensure layout is ready ─────────────────────────────────────────────
        if (_layout == null) {
            _layout = _computeLayout(dc);
        }
        var layout = _layout as Lang.Dictionary;

        // ── Draw all zones ─────────────────────────────────────────────────────
        drawHeader(dc, layout, dateInfo, steps, calories, hrValue);
        drawDataStatus(dc, layout);
        drawTime(dc, layout, clockTime);
        drawMarine(dc, layout);
        drawSunTimes(dc, layout, sunTimes);
        drawBattery(dc, layout, batteryPct);
    }

    // =========================================================================
    // _computeLayout — derive all coordinates from screen dimensions
    //
    // Returns a dictionary of named positions/dimensions used by draw functions.
    // All elements verified to stay inside the safe circle (safeR = min(w,h)/2 - 12).
    // =========================================================================
    private function _computeLayout(dc as Graphics.Dc) as Lang.Dictionary {
        var w    = dc.getWidth();
        var h    = dc.getHeight();
        var cx   = w / 2;
        var cy   = h / 2;
        var safeR    = (w < h ? w : h) / 2 - 12;  // 118 for 260px
        var safeTop  = cy - safeR;                  // 12
        var safeBot  = cy + safeR;                  // 248

        // ── Band Y positions ──────────────────────────────────────────────────
        var dateY   = safeTop + 12;              //  ≈ 24
        var stepsY  = safeTop + 38;              //  ≈ 50  (moved further down, reduce gap to divTop)
        var calY    = stepsY + STATS_ROW_GAP;    //  ≈ 60
        var hrY     = calY   + STATS_ROW_GAP;    //  ≈ 76

        // statsLeftX: FIXED left-edge for all activity rows (prevents diagonal slant).
        var stpDy2     = stepsY - cy;
        var stpC2      = safeR * safeR - stpDy2 * stpDy2;
        if (stpC2 < 0) { stpC2 = 0; }
        var statsLeftX = cx - Math.sqrt(stpC2.toFloat()).toNumber() + 6; //  ≈ 55

        // ── Marine grid: rows computed from dividers (fills available space evenly)
        var divTop  = safeTop + 82;   //  ≈ 94
        var divBot  = safeTop + 188;  //  ≈ 200  (rowSpacing = (194-116)/3 = 26)
        var colHeaderY = divTop + 8;  //  ≈ 102  (moved up; formerly below)
        var gridTopY   = colHeaderY + GRID_TOP_PADDING;   //  ≈ 116
        var gridBotY   = divBot - GRID_BOTTOM_PADDING;    //  ≈ 189
        var rowSpacing = (gridBotY - gridTopY) / 3;       //  ≈ 24
        var midRow1    = gridTopY + rowSpacing / 2;       //  ≈ 128
        var midRow2    = midRow1  + rowSpacing;           //  ≈ 152
        var midRow3    = midRow2  + rowSpacing;           //  ≈ 176
        var sunCY   = safeTop + 203;  //  ≈ 215  (3px gap after divBot at 200)

        // ── Time: top-right, X clamped to safe circle at timeY ───────────────
        var timeY    = safeTop + 60;  //  ≈ 72
        var timeDy   = timeY - cy;
        var timeChord2 = safeR * safeR - timeDy * timeDy;
        if (timeChord2 < 0) { timeChord2 = 0; }
        var timeHC   = Math.sqrt(timeChord2.toFloat()).toNumber();
        var timeX    = cx + timeHC - 10;

        // ── Marine column icon-anchor X positions ─────────────────────────────
        var colW     = safeR * 2 / 3;
        var col1X    = cx - safeR + 6;           //  ≈ 18
        var col2X    = cx - colW / 2 + 6;        //  ≈ 97
        var col3X    = cx + colW / 2 + 6;        //  ≈ 175
        var cellGap  = 4;
        var col1TxtX = col1X + ICON_W_GRID + cellGap;  //  ≈ 39
        var col2TxtX = col2X + ICON_W_GRID + cellGap;  //  ≈ 118
        var col3TxtX = col3X + ICON_W_GRID + cellGap;  //  ≈ 196

        // ── Column header centre X ────────────────────────────────────────────
        // colHeaderY already computed above (divTop + 8)
        var col1CX     = (col1X + col2X) / 2;             //  ≈ 57
        var col2CX     = cx;                               //  ≈ 130
        var col3CX     = (col3X + cx + safeR - 6) / 2;   //  ≈ 208

        // ── Battery icon + text — simple bottom placement ─────────────────────
        var batTextY = safeBot - BAT_Y_INSET;             //  ≈ 234

        // ── Sun zone: push icons to safe-circle edges at sunCY ────────────────
        var sunDy    = sunCY - cy;
        var sunC2    = safeR * safeR - sunDy * sunDy;
        if (sunC2 < 0) { sunC2 = 0; }
        var sunHC    = Math.sqrt(sunC2.toFloat()).toNumber();
        var sunLeft  = cx - sunHC + 2;                       //  ≈ 43 (pushed outward)
        var sunRight = cx + sunHC - 2;                       //  ≈ 217
        var riseIcCX = sunLeft  + SUN_IC_SIZE / 2;          // sunrise icon CENTRE X  ≈ 54
        var setIcCX  = sunRight - SUN_IC_SIZE / 2;          // sunset  icon CENTRE X  ≈ 206
        var sunFL_x  = riseIcCX + SUN_IC_SIZE / 2 + 2;     // left text anchor       ≈ 67
        var sunSS_x  = setIcCX  - SUN_IC_SIZE / 2 - 2;     // right text anchor      ≈ 195

        // ── Extras: date divider + column separators ──────────────────────────
        var dateDivY = dateY + 14;
        var sepX1    = col2X - 7;                        //  ≈ 90  (left of col2 icon)
        var sepX2    = col3X - 7;                        //  ≈ 168 (left of col3 icon)
        var sepPad   = (gridBotY - gridTopY) / 10;      //  ≈ 7   (10% pad each end)
        var sepTopY  = gridTopY + sepPad;                //  ≈ 123
        var sepBotY  = gridBotY - sepPad;                //  ≈ 182

        // ── Data freshness: between date divider and time, right-justified ──
        var dataStatusY  = dateDivY + 6;                 //  ≈ 44  (centred between date div & time)
        var dsDy         = dataStatusY - cy;
        var dsC2         = safeR * safeR - dsDy * dsDy;
        if (dsC2 < 0) { dsC2 = 0; }
        var dataStatusRX = cx + Math.sqrt(dsC2.toFloat()).toNumber() - 8;  // right edge with margin

        return {
            "w" => w, "h" => h, "cx" => cx, "cy" => cy, "safeR" => safeR,
            // Header
            "dateY" => dateY, "dateDivY" => dateDivY,
            "stepsY" => stepsY, "calY" => calY, "hrY" => hrY,
            "statsLeftX" => statsLeftX,
            // Time
            "timeY" => timeY, "timeX" => timeX,
            // Data freshness
            "dataStatusY" => dataStatusY, "dataStatusRX" => dataStatusRX,
            // Marine grid
            "divTop" => divTop, "divBot" => divBot,
            "midRow1" => midRow1, "midRow2" => midRow2, "midRow3" => midRow3,
            "col1X" => col1X, "col2X" => col2X, "col3X" => col3X,
            "col1TxtX" => col1TxtX, "col2TxtX" => col2TxtX, "col3TxtX" => col3TxtX,
            // Column headers
            "colHeaderY" => colHeaderY,
            "col1CX" => col1CX, "col2CX" => col2CX, "col3CX" => col3CX,
            // Column separators
            "sepX1" => sepX1, "sepX2" => sepX2,
            "sepTopY" => sepTopY, "sepBotY" => sepBotY,
            // Sun zone
            "sunCY" => sunCY, "sunFL_x" => sunFL_x, "sunSS_x" => sunSS_x,
            "sunRiseIcX" => riseIcCX, "sunSetIcX" => setIcCX,
            // Battery icon + text
            "batTextY" => batTextY
        };
    }

    // =========================================================================
    // _safeXAt — returns [leftX, rightX] safe draw bounds at given Y
    // =========================================================================
    private function _safeXAt(layout as Lang.Dictionary, y as Lang.Number) as Lang.Array {
        var cx    = layout["cx"] as Lang.Number;
        var cy    = layout["cy"] as Lang.Number;
        var safeR = layout["safeR"] as Lang.Number;
        var dy    = y - cy;
        var chord2 = safeR * safeR - dy * dy;
        if (chord2 < 0) { chord2 = 0; }
        var halfChord = Math.sqrt(chord2.toFloat()).toNumber();
        var margin = 6;
        return [cx - halfChord + margin, cx + halfChord - margin];
    }

    // =========================================================================
    // drawHeader — Zone 1: vector calendar date row + activity stack
    //
    // Date row:  _drawCalendarIcon + "Dow DD" text, centred in top band
    // Activity:  steps / calories / heart rate stacked on left side
    // =========================================================================
    private function drawHeader(
        dc       as Graphics.Dc,
        layout   as Lang.Dictionary,
        dateInfo as Gregorian.Info,
        steps    as Lang.Number,
        calories as Lang.Number,
        hr       as Lang.String
    ) as Void {
        var cx    = layout["cx"]    as Lang.Number;
        var dateY = layout["dateY"] as Lang.Number;

        // ── Date row: centered "Dow DD" — no icon ────────────────────────────
        var dateStr = dateInfo.day_of_week.substring(0, 3) + " " + dateInfo.day.toString();
        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, dateY, Graphics.FONT_TINY, dateStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // ── Thin divider under date ────────────────────────────────────────────
        var dateDivY = layout["dateDivY"] as Lang.Number;
        var ddb = _safeXAt(layout, dateDivY) as Lang.Array;
        dc.setColor(COLOR_CYAN_MID, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(ddb[0] as Lang.Number, dateDivY, ddb[1] as Lang.Number, dateDivY);

        // ── Activity stack (fixed left edge) ──────────────────────────────────
        var stepsY = layout["stepsY"] as Lang.Number;
        var calY   = layout["calY"]   as Lang.Number;
        var hrY    = layout["hrY"]    as Lang.Number;
        var sLeft  = layout["statsLeftX"] as Lang.Number;

        // Steps — shorten to "10.5k" format at 5+ digits to avoid overlap with time
        if (_icSteps != null) { dc.drawBitmap(sLeft, stepsY - ICON_H_TOP / 2, _icSteps); }
        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var stepsStr = steps.toString();
        if (steps >= 10000) {
            stepsStr = (steps / 1000).toString() + "." + ((steps % 1000) / 100).toString() + "k";
        }
        dc.drawText(sLeft + ICON_W_TOP + 3, stepsY, Graphics.FONT_XTINY,
            stepsStr, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Calories — shorten to "10.5k" format at 5+ digits (same as steps)
        if (_icCal != null) { dc.drawBitmap(sLeft, calY - ICON_H_TOP / 2, _icCal); }
        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var calStr = calories.toString();
        if (calories >= 10000) {
            calStr = (calories / 1000).toString() + "." + ((calories % 1000) / 100).toString() + "k";
        }
        dc.drawText(sLeft + ICON_W_TOP + 3, calY, Graphics.FONT_XTINY,
            calStr, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Heart rate — 14px icon, but text aligned to same X as steps/cal (ICON_W_TOP)
        if (_icHR != null) { dc.drawBitmap(sLeft, hrY - ICON_H_HR / 2, _icHR); }
        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(sLeft + ICON_W_TOP + 3, hrY, Graphics.FONT_XTINY,
            hr, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // =========================================================================
    // drawTime — Zone 2: large bold time (FONT_NUMBER_MEDIUM)
    // =========================================================================
    private function drawTime(
        dc        as Graphics.Dc,
        layout    as Lang.Dictionary,
        clockTime as System.ClockTime
    ) as Void {
        var timeX = layout["timeX"] as Lang.Number;
        var timeY = layout["timeY"] as Lang.Number;

        var hour = clockTime.hour;
        var is24h = System.getDeviceSettings().is24Hour;
        if (!is24h && hour > 12) { hour = hour - 12; }
        if (!is24h && hour == 0) { hour = 12; }

        var timeStr = hour.format("%02d") + ":" + clockTime.min.format("%02d");

        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            timeX,
            timeY,
            Graphics.FONT_NUMBER_MEDIUM,
            timeStr,
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    // =========================================================================
    // drawMarine — Zone 3: 3×3 marine data grid
    //
    // Column headers (FONT_XTINY, COLOR_SUBTLE) above top divider.
    // Grid:         Col1 (ENV)        Col2 (SWELL)       Col3 (WIND)
    //   Row 1:      Water temp        Wave height        Wind speed
    //   Row 2:      Air temp          Swell period       Wind dir arrow+text
    //   Row 3:      UV or Tide        Swell dir arrow    Wind 6h range
    //
    // Row 3 left column: UV index (default) or tide (if WorldTides key set).
    // =========================================================================
    private function drawMarine(dc as Graphics.Dc, layout as Lang.Dictionary) as Void {

        var col1X      = layout["col1X"]      as Lang.Number;
        var col2X      = layout["col2X"]      as Lang.Number;
        var col3X      = layout["col3X"]      as Lang.Number;
        var col2TxtX   = layout["col2TxtX"]   as Lang.Number;
        var col3TxtX   = layout["col3TxtX"]   as Lang.Number;
        var midRow1    = layout["midRow1"]    as Lang.Number;
        var midRow2    = layout["midRow2"]    as Lang.Number;
        var midRow3    = layout["midRow3"]    as Lang.Number;
        var divTop     = layout["divTop"]     as Lang.Number;
        var divBot     = layout["divBot"]     as Lang.Number;
        var colHeaderY = layout["colHeaderY"] as Lang.Number;
        var col1CX     = layout["col1CX"]     as Lang.Number;
        var col2CX     = layout["col2CX"]     as Lang.Number;
        var col3CX     = layout["col3CX"]     as Lang.Number;

        // ── Marine data (live from cache, falls back to demo if no cache yet) ───
        var d = _loadCachedData();
        var waterTemp        = d["waterTemp"]        as Lang.String;
        var waterLabel       = d["waterLabel"]       as Lang.String;
        var airTemp          = d["airTemp"]          as Lang.String;
        var airLabel         = d["airLabel"]         as Lang.String;
        var wave             = d["wave"]             as Lang.String;
        var waveLabel        = d["waveLabel"]        as Lang.String;
        var swellPeriod      = d["swellPeriod"]      as Lang.String;
        var swellPeriodLabel = d["swellPeriodLabel"] as Lang.String;
        var swellDirCard     = d["swellDirCard"]     as Lang.String;
        var swellBearing     = (d["swellBearing"]    as Lang.Number).toFloat();
        var windSpeed        = d["windSpeed"]        as Lang.String;
        var windLabel        = d["windLabel"]        as Lang.String;
        var windDirCard      = d["windDirCard"]      as Lang.String;
        var windBearing      = (d["windBearing"]     as Lang.Number).toFloat();
        var windMin          = d["windMin"]          as Lang.String;
        var windMax          = d["windMax"]          as Lang.String;
        var swellDirDeg      = d["swellDirDeg"]      as Lang.String;
        var windDirDeg       = d["windDirDeg"]       as Lang.String;
        var hasTide          = d["hasTide"]          as Lang.Boolean;

        // ── Column headers (below top divider — no collision with time) ───────
        dc.setColor(COLOR_SUBTLE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(col1CX, colHeaderY, Graphics.FONT_XTINY, "ENV",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(col2CX, colHeaderY, Graphics.FONT_XTINY, "SWELL",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(col3CX, colHeaderY, Graphics.FONT_XTINY, "WIND",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // ── Horizontal divider lines ──────────────────────────────────────────
        dc.setColor(COLOR_CYAN_MID, Graphics.COLOR_TRANSPARENT);
        var topB = _safeXAt(layout, divTop) as Lang.Array;
        var botB = _safeXAt(layout, divBot) as Lang.Array;
        dc.drawLine(topB[0] as Lang.Number, divTop, topB[1] as Lang.Number, divTop);
        dc.drawLine(botB[0] as Lang.Number, divBot, botB[1] as Lang.Number, divBot);

        // ── Vertical column separators (subtle, 80% height, gap at top+bottom) ─
        var sepX1   = layout["sepX1"]   as Lang.Number;
        var sepX2   = layout["sepX2"]   as Lang.Number;
        var sepTopY = layout["sepTopY"] as Lang.Number;
        var sepBotY = layout["sepBotY"] as Lang.Number;
        dc.drawLine(sepX1, sepTopY, sepX1, sepBotY);
        dc.drawLine(sepX2, sepTopY, sepX2, sepBotY);

        // ── ROW 1: Water | Wave | Wind speed ─────────────────────────────────
        drawMetricWithIcon(dc, col1X, midRow1, _icWaterT,  waterTemp,   waterLabel,       COLOR_VALUE);
        drawMetricWithIcon(dc, col2X, midRow1, _icSwellSz, wave,        waveLabel,        COLOR_VALUE);
        // Wind speed: vector icon (replaces pixelated PNG)
        _drawWindIcon(dc, col3X + ICON_W_GRID / 2, midRow1, ICON_W_GRID, COLOR_VALUE);
        drawMetricWithIcon(dc, col3X, midRow1, null, windSpeed,   windLabel,        COLOR_VALUE);

        // ── ROW 2: Air temp | Swell period | Wind direction ───────────────────
        drawMetricWithIcon(dc, col1X, midRow2, _icWeather,     airTemp,     airLabel,         COLOR_VALUE);
        // Swell period: vector clock icon (replaces pixelated PNG)
        _drawSwellPeriodIcon(dc, col2X + ICON_W_GRID / 2, midRow2, ICON_W_GRID, COLOR_VALUE);
        drawMetricWithIcon(dc, col2X, midRow2, null, swellPeriod, swellPeriodLabel, COLOR_VALUE);

        // Wind dir: red arrow + VALUE cardinal + DESC degrees (no overlap: LINE_GAP_PX)
        var arrowCX3 = col3X + ICON_W_GRID / 2;
        _drawArrow(dc, arrowCX3, midRow2, ((windBearing + 180.0f) - ((windBearing + 180.0f) >= 360.0f ? 360.0f : 0.0f)), 8, COLOR_RED);
        dc.setColor(COLOR_VALUE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(col3TxtX, midRow2 - LINE_GAP_PX, Graphics.FONT_XTINY, windDirCard,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(COLOR_DESC, Graphics.COLOR_TRANSPARENT);
        dc.drawText(col3TxtX, midRow2 + LINE_GAP_PX, Graphics.FONT_XTINY, windDirDeg,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // ── ROW 3: UV/Tide | Swell direction | Wind 6h min/max ───────────────
        if (hasTide) {
            // Tide mode: vector tide icon + height + trend
            _drawTideIcon(dc, col1X + ICON_W_GRID / 2, midRow3, ICON_W_GRID, COLOR_CYAN);
            drawMetricWithIcon(dc, col1X, midRow3, null,
                d["row3Value"] as Lang.String, d["row3Label"] as Lang.String, COLOR_VALUE);
        } else {
            // UV mode: vector "UV" in subtle yellow — thinner than FONT_XTINY
            _drawUVText(dc, col1X + ICON_W_GRID / 2, midRow3, 0xC8B860);
            drawMetricWithIcon(dc, col1X, midRow3, null,
                d["row3Value"] as Lang.String, d["row3Label"] as Lang.String, COLOR_VALUE);
        }

        // Swell dir: blue arrow + VALUE cardinal + DESC degrees (no overlap: LINE_GAP_PX)
        var arrowCX2 = col2X + ICON_W_GRID / 2;
        _drawArrow(dc, arrowCX2, midRow3, ((swellBearing + 180.0f) - ((swellBearing + 180.0f) >= 360.0f ? 360.0f : 0.0f)), 8, COLOR_CYAN);
        dc.setColor(COLOR_VALUE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(col2TxtX, midRow3 - LINE_GAP_PX, Graphics.FONT_XTINY, swellDirCard,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(COLOR_DESC, Graphics.COLOR_TRANSPARENT);
        dc.drawText(col2TxtX, midRow3 + LINE_GAP_PX, Graphics.FONT_XTINY, swellDirDeg,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Wind min/max: vector icon + min (white) / max (grey)
        _drawMinMaxIcon(dc, col3X + ICON_W_GRID / 2, midRow3, ICON_W_GRID, COLOR_VALUE);
        drawMetricWithIcon(dc, col3X, midRow3, null, windMin, windMax, COLOR_VALUE);
    }

    // =========================================================================
    // drawSunTimes — Zone 4: vector sunrise/sunset icons + computed times
    // =========================================================================
    private function drawSunTimes(
        dc       as Graphics.Dc,
        layout   as Lang.Dictionary,
        sunTimes as Lang.Dictionary
    ) as Void {
        var sunCY   = layout["sunCY"]      as Lang.Number;
        var sunFL_x = layout["sunFL_x"]    as Lang.Number;
        var sunSS_x = layout["sunSS_x"]    as Lang.Number;
        var riseIcX = layout["sunRiseIcX"] as Lang.Number;
        var setIcX  = layout["sunSetIcX"]  as Lang.Number;

        // Vector icons centred at (icX, sunCY)
        _drawSunriseIcon(dc, riseIcX, sunCY, SUN_IC_SIZE, COLOR_ORANGE);
        _drawSunsetIcon(dc, setIcX, sunCY, SUN_IC_SIZE, COLOR_ORANGE);

        // Left text: FL above SR — SOLAR_LINE_GAP half-gap
        dc.setColor(COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(sunFL_x, sunCY - SOLAR_LINE_GAP, Graphics.FONT_XTINY,
            "FL " + sunTimes["firstLight"],
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(sunFL_x, sunCY + SOLAR_LINE_GAP, Graphics.FONT_XTINY,
            "SR " + sunTimes["sunrise"],
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Right text: SS above LL — SOLAR_LINE_GAP half-gap
        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(sunSS_x, sunCY - SOLAR_LINE_GAP, Graphics.FONT_XTINY,
            "SS " + sunTimes["sunset"],
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(sunSS_x, sunCY + SOLAR_LINE_GAP, Graphics.FONT_XTINY,
            "LL " + sunTimes["lastLight"],
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // =========================================================================
    // drawBattery — Zone 5: small battery icon + "NN%" text, bottom-center
    // =========================================================================
    private function drawBattery(
        dc         as Graphics.Dc,
        layout     as Lang.Dictionary,
        batteryPct as Lang.Number
    ) as Void {
        var cx    = layout["cx"]       as Lang.Number;
        var textY = layout["batTextY"] as Lang.Number;
        // Icon centred left of cx; text starts just right of centre
        _drawBatteryIcon(dc, cx - 16, textY, batteryPct);
        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx + 2, textY, Graphics.FONT_XTINY,
            batteryPct.toString() + "%",
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // =========================================================================
    // drawDataStatus — data freshness indicator between date and time
    //
    // Positioned right-justified, between date divider and time display.
    // No cache:     "Waiting..." in COLOR_DESC (subtle grey)
    // <60 min:      "Xm ago" in COLOR_DESC
    // >=60 min:     "Xh ago" or "X.5h ago" in COLOR_DESC (rounds to nearest 0.5h)
    // =========================================================================
    private function drawDataStatus(dc as Graphics.Dc, layout as Lang.Dictionary) as Void {
        var statusY = layout["dataStatusY"]  as Lang.Number;
        var statusX = layout["dataStatusRX"] as Lang.Number;

        var cacheTime = Application.Storage.getValue("cacheTime");
        dc.setColor(COLOR_DESC, Graphics.COLOR_TRANSPARENT);
        if (cacheTime == null) {
            dc.drawText(statusX, statusY, Graphics.FONT_XTINY, "Waiting...",
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            var ageSeconds = Time.now().value() - (cacheTime as Lang.Number);
            var ageMins = ageSeconds / 60;
            var ageStr = "";
            if (ageMins < 60) {
                ageStr = ageMins.toString() + "m ago";
            } else {
                // Round to nearest 0.5h: 60-89m=1h, 90-119m=1.5h, 120-149m=2h, etc.
                var halfHours = ageMins / 30;  // integer division
                if (halfHours % 2 == 0) {
                    ageStr = (halfHours / 2).toString() + "h ago";
                } else {
                    ageStr = (halfHours / 2).toString() + ".5h ago";
                }
            }
            dc.drawText(statusX, statusY, Graphics.FONT_XTINY, ageStr,
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // =========================================================================
    // _drawBatteryIcon — vector battery outline + proportional fill
    //
    // cx, cy = icon centre. No PNG — crisp at native resolution.
    // Outline: BAT_ICON_W × BAT_ICON_H rect + nub on right.
    // Fill: color-coded green/amber/red proportional to percent.
    // =========================================================================
    private function _drawBatteryIcon(
        dc      as Graphics.Dc,
        cx      as Lang.Number,
        cy      as Lang.Number,
        percent as Lang.Number
    ) as Void {
        var w    = BAT_ICON_W;
        var h    = BAT_ICON_H;
        var nubH = h / 2;
        var left = cx - w / 2;
        var top  = cy - h / 2;

        // Outline
        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawRectangle(left, top, w, h);

        // Nub on right side
        dc.fillRectangle(left + w, top + (h - nubH) / 2, BAT_ICON_NUB, nubH);

        // Fill proportional to %
        var fillW = ((w - 4) * percent / 100).toNumber();
        if (fillW > 0) {
            var fillColor = COLOR_BATTERY;
            if (percent < 30)      { fillColor = COLOR_RED;    }
            else if (percent < 60) { fillColor = 0xFFAA00;     }
            dc.setColor(fillColor, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(left + 2, top + 2, fillW, h - 4);
        }
    }

    // =========================================================================
    // drawMetricWithIcon — icon on left, value + descriptor stacked right
    //
    // anchorX = left edge of icon (col1X/col2X/col3X).
    // rowCY   = row vertical centre.
    // Both value and descriptor use FONT_XTINY.
    // =========================================================================
    private function drawMetricWithIcon(
        dc         as Graphics.Dc,
        anchorX    as Lang.Number,
        rowCY      as Lang.Number,
        icon       as WatchUi.BitmapResource?,
        valueStr   as Lang.String,
        descStr    as Lang.String,
        valueColor as Lang.Number
    ) as Void {
        if (icon != null) {
            dc.drawBitmap(anchorX, rowCY - ICON_H_GRID / 2, icon);
        }
        var textX = anchorX + ICON_W_GRID + 4;

        dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(textX, rowCY - LINE_GAP_PX,
            Graphics.FONT_XTINY, valueStr,  // TIER 1: FONT_XTINY (SDK minimum; hierarchy via color)
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(COLOR_DESC, Graphics.COLOR_TRANSPARENT);
        dc.drawText(textX, rowCY + LINE_GAP_PX,
            Graphics.FONT_XTINY, descStr,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // =========================================================================
    // _drawCalendarIcon — vector calendar (crisp at any size, replaces PNG)
    //
    // cx, cy = icon centre. sz = bounding size in px. color = fill/stroke color.
    // Draws: outer rectangle, filled header stripe (top ~30%), horizontal mid line.
    // =========================================================================
    private function _drawCalendarIcon(
        dc    as Graphics.Dc,
        cx    as Lang.Number,
        cy    as Lang.Number,
        sz    as Lang.Number,
        color as Lang.Number
    ) as Void {
        var s    = sz / 2;
        var left = cx - s;
        var top  = cy - s;

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);

        // Outer rectangle
        dc.drawRectangle(left, top, sz, sz);

        // Filled header stripe (top ~30%)
        var hdrH = sz * 3 / 10;
        if (hdrH < 3) { hdrH = 3; }
        dc.fillRectangle(left + 1, top + 1, sz - 2, hdrH);

        // Horizontal mid grid line
        var midY = top + sz / 2 + 1;
        dc.drawLine(left + 2, midY, left + sz - 3, midY);
    }

    // =========================================================================
    // _drawSunriseIcon — vector sun arc + horizon + rays (replaces sunrise.png)
    //
    // cx, cy = icon centre. sz = bounding box size. color = icon colour.
    // =========================================================================
    private function _drawSunriseIcon(
        dc    as Graphics.Dc,
        cx    as Lang.Number,
        cy    as Lang.Number,
        sz    as Lang.Number,
        color as Lang.Number
    ) as Void {
        var sunR   = sz / 4;              // sun radius
        var horizY = cy + sunR / 2 + 1;  // horizon Y (pushes sun up into icon)

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);

        // Horizon line
        dc.drawLine(cx - sz / 2, horizY, cx + sz / 2, horizY);

        // Sun semicircle above horizon
        dc.drawArc(cx, horizY, sunR, Graphics.ARC_COUNTER_CLOCKWISE, 180, 0);

        // Three rays: top, upper-left, upper-right
        var ro = sunR + 2;          // ray start (just outside sun circle)
        var re = ro + sz / 6;       // ray end

        // Top ray
        dc.drawLine(cx, horizY - ro, cx, horizY - re);

        // 45° diagonal rays (approx: multiply by 0.7)
        var d1 = (ro.toFloat() * 0.7f).toNumber();
        var d2 = (re.toFloat() * 0.7f).toNumber();
        dc.drawLine(cx - d1, horizY - d1, cx - d2, horizY - d2);
        dc.drawLine(cx + d1, horizY - d1, cx + d2, horizY - d2);
    }

    // =========================================================================
    // _drawSunsetIcon — sun sinking below horizon (distinct from sunrise)
    //
    // Sunrise: sun ABOVE horizon, rays pointing UP.
    // Sunset:  sun ON/BELOW horizon, rays angled DOWNWARD.
    // =========================================================================
    private function _drawSunsetIcon(
        dc    as Graphics.Dc,
        cx    as Lang.Number,
        cy    as Lang.Number,
        sz    as Lang.Number,
        color as Lang.Number
    ) as Void {
        var sunR   = sz / 4;              // sun radius (same as sunrise)
        var horizY = cy + sunR / 2 + 1;  // SAME horizon Y as sunrise — aligned

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);

        // Horizon line (same Y as sunrise horizon)
        dc.drawLine(cx - sz / 2, horizY, cx + sz / 2, horizY);

        // Sun semicircle BELOW horizon (arc through bottom)
        dc.drawArc(cx, horizY, sunR, Graphics.ARC_CLOCKWISE, 180, 0);

        // Three downward rays from below horizon
        var ro = sunR + 2;          // ray start (just outside sun circle)
        var re = ro + sz / 6;       // ray end

        // Bottom ray (straight down)
        dc.drawLine(cx, horizY + ro, cx, horizY + re);

        // 45° diagonal rays downward
        var d1 = (ro.toFloat() * 0.7f).toNumber();
        var d2 = (re.toFloat() * 0.7f).toNumber();
        dc.drawLine(cx - d1, horizY + d1, cx - d2, horizY + d2);
        dc.drawLine(cx + d1, horizY + d1, cx + d2, horizY + d2);
    }

    // =========================================================================
    // _drawMinMaxIcon — vector up/down arrows (range symbol, replaces PNG)
    //
    // cx, cy = icon centre. sz = bounding size. color = icon colour.
    // Two filled triangles: up arrow (max) on top, down arrow (min) on bottom.
    // =========================================================================
    private function _drawMinMaxIcon(
        dc    as Graphics.Dc,
        cx    as Lang.Number,
        cy    as Lang.Number,
        sz    as Lang.Number,
        color as Lang.Number
    ) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var half = sz / 2;
        var aw   = sz / 3;   // arrow half-width
        var gap  = 2;         // gap between arrows at centre

        // Up arrow (max) — top half
        dc.fillPolygon([
            [cx, cy - half],
            [cx - aw, cy - gap],
            [cx + aw, cy - gap]
        ]);

        // Down arrow (min) — bottom half
        dc.fillPolygon([
            [cx, cy + half],
            [cx - aw, cy + gap],
            [cx + aw, cy + gap]
        ]);
    }

    // =========================================================================
    // _drawTideIcon — vector 3-wave-lines (water/tide symbol, replaces PNG)
    //
    // cx, cy = icon centre. sz = bounding size. color = line colour.
    // Draws three horizontal wavy lines stacked vertically — universal water symbol.
    // =========================================================================
    private function _drawTideIcon(
        dc    as Graphics.Dc,
        cx    as Lang.Number,
        cy    as Lang.Number,
        sz    as Lang.Number,
        color as Lang.Number
    ) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var half = sz / 2;
        var amp  = 2;               // wave amplitude (px)
        var sp   = sz / 4 + 1;     // ~5px vertical spacing between lines
        var q    = half / 2;        // quarter width for wave segment

        for (var row = -1; row <= 1; row++) {
            var y  = cy + row * sp;
            var x0 = cx - half;

            dc.drawLine(x0,     y,       x0 + q, y - amp);
            dc.drawLine(x0 + q, y - amp, cx,     y);
            dc.drawLine(cx,     y,       cx + q, y + amp);
            dc.drawLine(cx + q, y + amp, cx + half, y);
        }
    }

    // =========================================================================
    // _drawSwellPeriodIcon — vector clock/stopwatch (time-period symbol)
    //
    // cx, cy = icon centre. sz = bounding size. color = icon colour.
    // Draws: circle outline + two clock hands (12-o'clock + 3-o'clock).
    // =========================================================================
    private function _drawSwellPeriodIcon(
        dc    as Graphics.Dc,
        cx    as Lang.Number,
        cy    as Lang.Number,
        sz    as Lang.Number,
        color as Lang.Number
    ) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var r = sz / 2 - 1;

        // Circle
        dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, 0, 360);

        // Minute hand (12-o'clock — straight up, ~70% radius)
        var hLen = r * 7 / 10;
        dc.drawLine(cx, cy, cx, cy - hLen);

        // Hour hand (3-o'clock — pointing right, ~50% radius)
        var sLen = r / 2;
        dc.drawLine(cx, cy, cx + sLen, cy);

        // Centre dot
        dc.fillCircle(cx, cy, 1);
    }

    // =========================================================================
    // _drawWindIcon — vector wind symbol (three curved flowing lines)
    //
    // cx, cy = icon centre. sz = bounding size. color = icon colour.
    // Draws three horizontal lines with curved hooks at the end — universal wind.
    // =========================================================================
    private function _drawWindIcon(
        dc    as Graphics.Dc,
        cx    as Lang.Number,
        cy    as Lang.Number,
        sz    as Lang.Number,
        color as Lang.Number
    ) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var half = sz / 2;
        var sp   = sz / 4 + 1;   // vertical spacing between lines (~6px)

        // Three flowing lines at y offsets: -sp, 0, +sp
        // Each line: horizontal segment + small upward hook at the right end
        for (var row = -1; row <= 1; row++) {
            var y  = cy + row * sp;
            var x0 = cx - half;
            var x1 = cx + half;

            // Vary line lengths for a natural look
            if (row == -1) { x0 = cx - half + 3; }     // top line shorter
            if (row ==  1) { x0 = cx - half + 2; }     // bottom line slightly shorter

            // Main horizontal stroke
            dc.drawLine(x0, y, x1 - 2, y);

            // Curved hook at end (upward flick — 2px up, 2px right)
            dc.drawLine(x1 - 2, y, x1, y - 2);
        }
    }

    // =========================================================================
    // _drawUVText — vector "UV" letters drawn with 1px lines
    //
    // cx, cy = centre point for the two-letter label.
    // Thinner than FONT_XTINY because drawLine uses 1px stroke width
    // vs the font renderer's 2px+ bitmap strokes.
    // Letter height: 8px. Total width: ~14px (U=5, gap=2, V=5).
    // =========================================================================
    private function _drawUVText(
        dc    as Graphics.Dc,
        cx    as Lang.Number,
        cy    as Lang.Number,
        color as Lang.Number
    ) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var h = 4;  // half-height of letters (8px total)
        var w = 2;  // half-width of each letter (5px total)

        // "U" — left of centre: left stroke down, bottom curve, right stroke up
        var ux = cx - 4;  // centre of U
        dc.drawLine(ux - w, cy - h, ux - w, cy + h - 1);  // left vertical
        dc.drawLine(ux - w, cy + h - 1, ux - w + 1, cy + h);  // bottom-left curve
        dc.drawLine(ux - w + 1, cy + h, ux + w - 1, cy + h);  // bottom flat
        dc.drawLine(ux + w - 1, cy + h, ux + w, cy + h - 1);  // bottom-right curve
        dc.drawLine(ux + w, cy + h - 1, ux + w, cy - h);  // right vertical

        // "V" — right of centre: left diagonal down to tip, right diagonal up
        var vx = cx + 4;  // centre of V
        dc.drawLine(vx - w, cy - h, vx, cy + h);      // left diagonal
        dc.drawLine(vx, cy + h, vx + w, cy - h);       // right diagonal
    }

    // =========================================================================
    // _drawWaveIcon — vector wave (swell/wave height symbol)
    //
    // cx, cy = icon centre. sz = bounding size. color = icon colour.
    // Draws two wave curves — a larger crest on top and smaller one below.
    // Replaces swell_size.png bitmap (had blue dot artifact at small sizes).
    // =========================================================================
    private function _drawWaveIcon(
        dc    as Graphics.Dc,
        cx    as Lang.Number,
        cy    as Lang.Number,
        sz    as Lang.Number,
        color as Lang.Number
    ) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var half = sz / 2;

        // Upper wave (larger crest) — arc from left to right, peaking above centre
        var waveY1 = cy - 2;
        dc.drawLine(cx - half, waveY1 + 2, cx - half + 3, waveY1);
        dc.drawLine(cx - half + 3, waveY1, cx - 1, waveY1 - 3);
        dc.drawLine(cx - 1, waveY1 - 3, cx + 3, waveY1);
        dc.drawLine(cx + 3, waveY1, cx + half, waveY1 + 2);

        // Lower wave (smaller) — shifted down and slightly narrower
        var waveY2 = cy + 4;
        dc.drawLine(cx - half + 2, waveY2 + 1, cx - half + 5, waveY2);
        dc.drawLine(cx - half + 5, waveY2, cx, waveY2 - 2);
        dc.drawLine(cx, waveY2 - 2, cx + 4, waveY2);
        dc.drawLine(cx + 4, waveY2, cx + half - 2, waveY2 + 1);
    }

    // =========================================================================
    // _drawUVIcon — vector sun with rays (UV index symbol)
    //
    // cx, cy = icon centre. sz = bounding size. color = icon colour.
    // Draws: filled circle (sun) + 4 short rays (cardinal directions).
    // =========================================================================
    private function _drawUVIcon(
        dc    as Graphics.Dc,
        cx    as Lang.Number,
        cy    as Lang.Number,
        sz    as Lang.Number,
        color as Lang.Number
    ) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var r = sz / 4;  // sun radius

        // Sun disc
        dc.fillCircle(cx, cy, r);

        // Four rays (N, S, E, W)
        var ri = r + 2;      // ray inner edge
        var ro = r + sz / 5; // ray outer edge
        dc.drawLine(cx, cy - ri, cx, cy - ro);         // top
        dc.drawLine(cx, cy + ri, cx, cy + ro);         // bottom
        dc.drawLine(cx - ri, cy, cx - ro, cy);         // left
        dc.drawLine(cx + ri, cy, cx + ro, cy);         // right
    }

    // =========================================================================
    // _drawArrow — filled equilateral triangle pointing in bearingDeg direction
    //
    // 0° = North (up), increases clockwise (compass convention).
    // tip at radius r from centre; tail at r×0.55 at ±2.3 rad either side.
    // =========================================================================
    private function _drawArrow(
        dc         as Graphics.Dc,
        cx         as Lang.Number,
        cy         as Lang.Number,
        bearingDeg as Lang.Float,
        r          as Lang.Number,
        color      as Lang.Number
    ) as Void {
        var rad  = bearingDeg * Math.PI / 180.0f;
        var sinB = Math.sin(rad);
        var cosB = Math.cos(rad);

        var tipX = cx + (r.toFloat() * sinB).toNumber();
        var tipY = cy - (r.toFloat() * cosB).toNumber();

        var leftRad  = rad + 2.3f;
        var rightRad = rad - 2.3f;
        var tailR    = r * 0.55f;

        var leftX  = cx + (tailR * Math.sin(leftRad)).toNumber();
        var leftY  = cy - (tailR * Math.cos(leftRad)).toNumber();
        var rightX = cx + (tailR * Math.sin(rightRad)).toNumber();
        var rightY = cy - (tailR * Math.cos(rightRad)).toNumber();

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([[tipX, tipY], [leftX, leftY], [rightX, rightY]]);
    }

    // =========================================================================
    // SOLAR MATH — unchanged from Phase 2
    //
    // Computes sunrise, sunset, civil twilight (first/last light) from GPS coords.
    // Returns Dictionary: "firstLight", "sunrise", "sunset", "lastLight" → HH:MM.
    // =========================================================================
    private function _computeSunTimes(
        year   as Lang.Number,
        month  as Lang.Number,
        day    as Lang.Number,
        latDeg as Lang.Float,
        lonDeg as Lang.Float
    ) as Lang.Dictionary {

        var y = year;
        var m = month;
        var d = day;

        if (m <= 2) { y = y - 1; m = m + 12; }

        var A  = (y / 100).toNumber();
        var B  = 2 - A + (A / 4).toNumber();
        var jd = (365.25f * (y + 4716)).toNumber() + (30.6001f * (m + 1)).toNumber() + d + B - 1524.5f;

        var T  = (jd - 2451545.0f) / 36525.0f;

        var L0 = 280.46646f + 36000.76983f * T;
        L0 = _modAngle(L0);

        var M  = 357.52911f + 35999.05029f * T;
        M = _modAngle(M);
        var Mrad = M * Math.PI / 180.0f;

        var C = (1.914602f - 0.004817f * T) * Math.sin(Mrad)
              + 0.019993f * Math.sin(2.0f * Mrad);

        var sunLon = L0 + C;

        var omega    = 125.04f - 1934.136f * T;
        var omRad    = omega * Math.PI / 180.0f;
        var appLon   = sunLon - 0.00569f - 0.00478f * Math.sin(omRad);
        var appLonRad = appLon * Math.PI / 180.0f;

        var eps0 = 23.0f + 26.0f / 60.0f + 21.448f / 3600.0f - (46.8150f / 3600.0f) * T;
        var eps  = eps0 + 0.00256f * Math.cos(omRad);
        var epsRad = eps * Math.PI / 180.0f;

        var sinDec = Math.sin(epsRad) * Math.sin(appLonRad);
        var decRad = Math.asin(sinDec);

        var y2    = Math.tan(epsRad / 2.0f);
        y2 = y2 * y2;
        var l0Rad = L0 * Math.PI / 180.0f;
        var mRad2 = M  * Math.PI / 180.0f;
        var eot = 4.0f * (180.0f / Math.PI) * (
              y2 * Math.sin(2.0f * l0Rad)
            - 2.0f * 0.016708634f * Math.sin(mRad2)
            + 4.0f * 0.016708634f * y2 * Math.sin(mRad2) * Math.cos(2.0f * l0Rad)
            - 0.5f * y2 * y2 * Math.sin(4.0f * l0Rad)
            - 1.25f * 0.016708634f * 0.016708634f * Math.sin(2.0f * mRad2)
        );

        var latRad = latDeg * Math.PI / 180.0f;

        var haSunrise = _calcHourAngle(latRad, decRad, -0.8333f);
        var haCivil   = _calcHourAngle(latRad, decRad, -6.0f);

        var solarNoonUTC  = 720.0f - 4.0f * lonDeg - eot;
        var sunriseUTC    = solarNoonUTC - haSunrise * 4.0f;
        var sunsetUTC     = solarNoonUTC + haSunrise * 4.0f;
        var firstLightUTC = solarNoonUTC - haCivil * 4.0f;
        var lastLightUTC  = solarNoonUTC + haCivil * 4.0f;

        var utcOffsetMins = System.getClockTime().timeZoneOffset / 60;

        return {
            "firstLight" => _minsToHHMM((firstLightUTC + utcOffsetMins).toNumber()),
            "sunrise"    => _minsToHHMM((sunriseUTC    + utcOffsetMins).toNumber()),
            "sunset"     => _minsToHHMM((sunsetUTC     + utcOffsetMins).toNumber()),
            "lastLight"  => _minsToHHMM((lastLightUTC  + utcOffsetMins).toNumber())
        };
    }

    private function _calcHourAngle(
        latRad as Lang.Float,
        decRad as Lang.Float,
        altDeg as Lang.Float
    ) as Lang.Float {
        var altRad = altDeg * Math.PI / 180.0f;
        var cosHA  = (Math.sin(altRad) - Math.sin(latRad) * Math.sin(decRad))
                   / (Math.cos(latRad) * Math.cos(decRad));
        if (cosHA >  1.0f) { cosHA =  1.0f; }
        if (cosHA < -1.0f) { cosHA = -1.0f; }
        return (Math.acos(cosHA) * 180.0f / Math.PI);
    }

    private function _modAngle(angle as Lang.Float) as Lang.Float {
        while (angle <    0.0f) { angle = angle + 360.0f; }
        while (angle >= 360.0f) { angle = angle - 360.0f; }
        return angle;
    }

    private function _minsToHHMM(totalMins as Lang.Number) as Lang.String {
        while (totalMins <    0)  { totalMins = totalMins + 1440; }
        while (totalMins >= 1440) { totalMins = totalMins - 1440; }
        var h = totalMins / 60;
        var m = totalMins % 60;
        return h.format("%02d") + ":" + m.format("%02d");
    }

    // =========================================================================
    // _demoData — hardcoded demo values (shown before first API response)
    //
    // Row 3 left column: UV index (default) or tide (if key configured).
    // Demo always shows UV since no key is configured at first boot.
    // =========================================================================
    private function _demoData() as Lang.Dictionary {
        return {
            "waterTemp"       => "23\u00B0C", "waterLabel"       => "Warm",
            "airTemp"         => "22\u00B0C", "airLabel"         => "Mod",
            "wave"            => "1.3m",      "waveLabel"        => "Med",
            "swellPeriod"     => "12s",       "swellPeriodLabel" => "Long",
            "swellDirCard"    => "SW",        "swellDirDeg"      => "228\u00B0",
            "swellBearing"    => 228,
            "windSpeed"       => "6kn",       "windLabel"        => "Low",
            "windDirCard"     => "SE",        "windDirDeg"       => "132\u00B0",
            "windBearing"     => 132,
            "windMin"         => "6kn",       "windMax"          => "18kn",
            "hasTide"         => false,
            "row3Value"       => "5",         "row3Label"        => "Mod"
        };
    }

    // =========================================================================
    // _loadCachedData — reads from Application.Storage (written by delegate).
    //
    // Returns dictionary with all marine data fields. Row 3 left column is
    // dynamic: shows tide (if WorldTides data in Storage) or UV index (default).
    // Falls back to _demoData() if no cache exists yet.
    // =========================================================================
    private function _loadCachedData() as Lang.Dictionary {
        // No cache yet — first run or background never fired (no network)
        if (Application.Storage.getValue("cacheTime") == null) {
            return _demoData();
        }
        // Also fall back if cacheTime is set but no actual data exists
        if (Application.Storage.getValue("waveHeight") == null &&
            Application.Storage.getValue("seaTemp") == null) {
            return _demoData();
        }

        // Read raw values from storage (null if that API call failed)
        var waveHRaw = Application.Storage.getValue("waveHeight") as Lang.Float?;
        var wavePRaw = Application.Storage.getValue("wavePeriod") as Lang.Float?;
        var waveDRaw = Application.Storage.getValue("waveDir")    as Lang.Number?;
        var windSRaw = Application.Storage.getValue("windSpeed")  as Lang.Float?;
        var windDRaw = Application.Storage.getValue("windDir")    as Lang.Number?;
        var windMnRaw= Application.Storage.getValue("windMinKn")  as Lang.Float?;
        var windMxRaw= Application.Storage.getValue("windMaxKn")  as Lang.Float?;
        var seaTRaw  = Application.Storage.getValue("seaTemp")    as Lang.Float?;
        var airTRaw  = Application.Storage.getValue("airTemp")    as Lang.Float?;
        var tideHRaw = Application.Storage.getValue("tideHeight") as Lang.Float?;
        var uvIdxRaw = Application.Storage.getValue("uvIndex")    as Lang.Float?;

        // Format display strings — "--" when value unavailable
        var waveHStr = (waveHRaw != null) ? waveHRaw.format("%.1f") + "m" : "--";
        var wavePStr = (wavePRaw != null) ? wavePRaw.format("%.0f") + "s" : "--";
        var waveDCard = (waveDRaw != null) ? _bearingToCard(waveDRaw) : "--";
        var waveDDeg  = (waveDRaw != null) ? waveDRaw.format("%d") + "\u00B0" : "--";
        var windSStr  = (windSRaw != null) ? windSRaw.format("%.0f") + "kn" : "--";
        var windDCard = (windDRaw != null) ? _bearingToCard(windDRaw) : "--";
        var windDDeg  = (windDRaw != null) ? windDRaw.format("%d") + "\u00B0" : "--";
        var windMnStr = (windMnRaw != null) ? windMnRaw.format("%.0f") + "kn" : "--";
        var windMxStr = (windMxRaw != null) ? windMxRaw.format("%.0f") + "kn" : "--";
        var seaTStr   = (seaTRaw  != null) ? seaTRaw.format("%.0f") + "\u00B0C" : "--";
        var airTStr   = (airTRaw  != null) ? airTRaw.format("%.0f") + "\u00B0C" : "--";

        // Row 3 left column: tide (if data exists in storage) or UV index
        var hasTide = (tideHRaw != null);
        var r3Value = "--";
        var r3Label = "--";
        if (hasTide) {
            r3Value = tideHRaw.format("%.1f") + "m";
            r3Label = _classifyTide(tideHRaw);
        } else if (uvIdxRaw != null) {
            r3Value = uvIdxRaw.format("%.0f");
            r3Label = _classifyUV(uvIdxRaw);
        }

        return {
            "waterTemp"        => seaTStr,
            "waterLabel"       => (seaTRaw  != null) ? _classifySeaTemp(seaTRaw)  : "--",
            "airTemp"          => airTStr,
            "airLabel"         => (airTRaw  != null) ? _classifyAirTemp(airTRaw) : "--",
            "wave"             => waveHStr,
            "waveLabel"        => (waveHRaw != null) ? _classifyWave(waveHRaw)   : "--",
            "swellPeriod"      => wavePStr,
            "swellPeriodLabel" => (wavePRaw != null) ? _classifyPeriod(wavePRaw) : "--",
            "swellDirCard"     => waveDCard,
            "swellDirDeg"      => waveDDeg,
            "swellBearing"     => (waveDRaw != null) ? waveDRaw : 0,
            "windSpeed"        => windSStr,
            "windLabel"        => (windSRaw != null) ? _classifyWind(windSRaw)   : "--",
            "windDirCard"      => windDCard,
            "windDirDeg"       => windDDeg,
            "windBearing"      => (windDRaw != null) ? windDRaw : 0,
            "windMin"          => windMnStr,
            "windMax"          => windMxStr,
            "hasTide"          => hasTide,
            "row3Value"        => r3Value,
            "row3Label"        => r3Label
        };
    }

    // =========================================================================
    // Classification helpers — convert raw numeric values to descriptor labels
    // =========================================================================

    private function _classifyWave(m as Lang.Float) as Lang.String {
        if (m < 0.3f) { return "Flat"; }
        if (m < 0.5f) { return "Tiny"; }
        if (m < 1.0f) { return "Small"; }
        if (m < 1.5f) { return "Med"; }
        if (m < 2.0f) { return "Mod"; }
        if (m < 3.0f) { return "Large"; }
        return "XL";
    }

    private function _classifyPeriod(s as Lang.Float) as Lang.String {
        if (s < 8.0f)  { return "Short"; }
        if (s < 12.0f) { return "Med"; }
        return "Long";
    }

    // Wind: >20kn = High, 12-20kn = Mod, <12kn = Low
    private function _classifyWind(kn as Lang.Float) as Lang.String {
        if (kn < 12.0f) { return "Low"; }
        if (kn < 20.0f) { return "Mod"; }
        return "High";
    }

    // Sea temp: >20°C = Warm, 17-20°C = Mod, 7-17°C = Cool, <7°C = Cold
    private function _classifySeaTemp(c as Lang.Float) as Lang.String {
        if (c < 7.0f)  { return "Cold"; }
        if (c < 17.0f) { return "Cool"; }
        if (c < 20.0f) { return "Mod"; }
        return "Warm";
    }

    // Air temp: >=30°C = Hot, 22-30°C = Mod, <22°C = Cold
    private function _classifyAirTemp(c as Lang.Float) as Lang.String {
        if (c < 22.0f) { return "Cold"; }
        if (c < 30.0f) { return "Mod"; }
        return "Hot";
    }

    // Tide height: >1.5m = High, 0.5-1.5m = Mod, <0.5m = Low
    // Based on global tidal ranges — works for micro-tidal (Perth/Fremantle ~0.3-0.8m)
    // and meso-tidal coasts (Sydney ~1-2m, Brisbane ~1-2.5m)
    private function _classifyTide(m as Lang.Float) as Lang.String {
        var abs = (m >= 0.0f) ? m : -m;  // handle negative (below chart datum)
        if (abs < 0.5f) { return "Low"; }
        if (abs < 1.5f) { return "Mod"; }
        return "High";
    }

    // UV index: <3 Low, 3-5 Mod, 6-7 High, 8-10 VHigh, >=11 Extreme
    private function _classifyUV(idx as Lang.Float) as Lang.String {
        if (idx < 3.0f)  { return "Low"; }
        if (idx < 6.0f)  { return "Mod"; }
        if (idx < 8.0f)  { return "High"; }
        if (idx < 11.0f) { return "VHigh"; }
        return "Ext";
    }

    // Bearing (0-359°) → 16-point cardinal string (N, NNE, NE, ... NNW)
    private function _bearingToCard(deg as Lang.Number) as Lang.String {
        var dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE",
                    "S","SSW","SW","WSW","W","WNW","NW","NNW"];
        return dirs[((deg + 11) / 22) % 16];
    }

}

