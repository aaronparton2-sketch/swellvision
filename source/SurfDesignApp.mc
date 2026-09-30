import Toybox.Application;
import Toybox.Background;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;

// ─────────────────────────────────────────────────────────────────────────────
// SurfDesignApp — Entry Point
//
// Phase 3.3 changes:
//   - Initial temporal event reduced to 5 min (data appears quickly after install)
//   - onBackgroundData() re-registers 30-min recurring temporal event
//     (fixes bug: without re-registration, background only fires once)
//   - getServiceDelegate() returns SurfDesignDelegate for background web requests
// ─────────────────────────────────────────────────────────────────────────────
class SurfDesignApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    // Called when the watch face becomes active (user selects it)
    function onStart(state as Lang.Dictionary?) as Void {
    }

    // Called when the watch face is stopped (user navigates away)
    function onStop(state as Lang.Dictionary?) as Void {
    }

    // Return the background service delegate — runs in a separate OS process.
    // The OS calls this when a temporal event fires or on first background run.
    // (:background) annotation is REQUIRED on real devices — tells the OS which
    // code to load in the background process. Without it, delegate never fires.
    (:background)
    function getServiceDelegate() {
        return [new SurfDesignDelegate()];
    }

    // Called when the background delegate exits via Background.exit(data).
    // The delegate writes directly to Application.Storage, so data here is null.
    // MUST re-register the temporal event here — without this, background only fires once.
    (:background)
    function onBackgroundData(data) as Void {
        Background.registerForTemporalEvent(new Time.Duration(30 * 60));
    }

    // Return the first View to display + register background refresh schedule.
    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        // First background fetch ~5 min after install (data appears quickly).
        // Subsequent refreshes every 30 min (re-registered in onBackgroundData).
        Background.registerForTemporalEvent(new Time.Duration(5 * 60));
        return [new SurfDesignView()];
    }

}
