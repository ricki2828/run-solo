import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.WatchUi;

// Phase 0 spike (Run Supreme Garmin plan, exit checks a-f). Throwaway: no recorder, no UI polish.
class SpikeApp extends Application.AppBase {
    var core;

    function initialize() {
        AppBase.initialize();
        core = new SpikeCore();
    }

    function onStart(state) {
        Communications.registerForPhoneAppMessages(method(:onPhone));
    }

    function onStop(state) {
        Communications.registerForPhoneAppMessages(null);
    }

    function onPhone(msg) {
        core.onPhone(msg.data);
    }

    function getInitialView() {
        var view = new SpikeView();
        return [view, new SpikeDelegate()];
    }
}

function getApp() {
    return Application.getApp();
}
