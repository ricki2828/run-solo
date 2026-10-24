import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class SpikeView extends WatchUi.View {
    function initialize() {
        View.initialize();
    }

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth();
        var h = dc.getHeight();
        var font = Graphics.FONT_XTINY;
        var lh = dc.getFontHeight(font);
        var lines = getApp().core.pageLines();
        var y = (h * 0.12).toNumber();
        var bottom = (h * 0.9).toNumber();
        for (var i = 0; i < lines.size(); i += 1) {
            if (y + lh > bottom) {
                break;
            }
            dc.drawText(w / 2, y, font, lines[i], Graphics.TEXT_JUSTIFY_CENTER);
            y += lh;
        }
    }
}

// START/SELECT or a tap runs the page's test; DOWN/UP or a vertical swipe changes page; BACK exits.
class SpikeDelegate extends WatchUi.BehaviorDelegate {
    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onSelect() {
        getApp().core.run();
        return true;
    }

    function onNextPage() {
        getApp().core.turn(1);
        return true;
    }

    function onPreviousPage() {
        getApp().core.turn(-1);
        return true;
    }
}
