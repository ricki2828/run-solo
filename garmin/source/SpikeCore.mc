import Toybox.Application.Storage;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// Completion callback for one transmit(): reports ok/error and elapsed ms back to the core.
class SendListener extends Communications.ConnectionListener {
    var _core;
    var _label;
    var _t0;
    var _cb;
    var _quiet;

    function initialize(core, label, cb, quiet) {
        Communications.ConnectionListener.initialize();
        _core = core;
        _label = label;
        _cb = cb;
        _quiet = quiet;
        _t0 = System.getTimer();
    }

    function onComplete() {
        var dt = System.getTimer() - _t0;
        if (!_quiet) {
            _core.log(_label + " ok " + dt + "ms");
        }
        if (_cb != null) {
            _cb.invoke(true, dt);
        }
    }

    function onError() {
        var dt = System.getTimer() - _t0;
        _core.log(_label + " FAIL " + dt + "ms");
        if (_cb != null) {
            _cb.invoke(false, dt);
        }
    }
}

// All spike state and tests. Pages: 0 link/id, 1 burst (background/kill test), 2 throughput,
// 3 storage + memory, 4 sample size, 5 results (SELECT re-sends them to the phone).
class SpikeCore {
    const PAGES = 6;
    const TP_CHUNKS = 25;     // x 1000 chars = 25 KB payload
    const BURST_N = 10;
    const BURST_MS = 5000;
    const PTS = 50;           // points per sample-size message

    var page = 0;
    var logLines = [];
    var res = {};
    var tx = 0;
    var rx = 0;
    var helloT0 = 0;

    var _kb = null;
    var _tm = null;
    var _job = 0;             // 1 burst, 2 storage
    var _i = 0;
    var _stage = 0;
    var _valA = null;
    var _valB = null;

    var _tpBusy = false;
    var _tpI = 0;
    var _tpFail = 0;
    var _tpT0 = 0;
    var _bOk = 0;
    var _bFail = 0;

    function initialize() {
        _tm = new Timer.Timer();
    }

    // ---- plumbing -------------------------------------------------------------------------

    function log(s) {
        logLines.add(s);
        if (logLines.size() > 40) {
            logLines = logLines.slice(1, null);
        }
        System.println(s);
        WatchUi.requestUpdate();
    }

    function appId() {
        return WatchUi.loadResource(Rez.Strings.AppId);
    }

    function kb() {
        if (_kb == null) {
            var s = "";
            for (var i = 0; i < 100; i += 1) {
                s = s + "0123456789";
            }
            _kb = s;
        }
        return _kb;
    }

    function sendMsg(d, label, cb, quiet) {
        tx += 1;
        try {
            Communications.transmit(d, null, new SendListener(self, label, cb, quiet));
        } catch (ex) {
            log(label + " throw " + ex.getErrorMessage());
            if (cb != null) {
                cb.invoke(false, 0);
            }
        }
    }

    function turn(d) {
        page = (page + d + PAGES) % PAGES;
        WatchUi.requestUpdate();
    }

    function run() {
        if (page == 0) {
            doHello();
        } else if (page == 1) {
            startBurst();
        } else if (page == 2) {
            startThroughput();
        } else if (page == 3) {
            startStorage();
        } else if (page == 4) {
            doSample();
        } else {
            sendResults();
        }
    }

    // ---- (a) two-way messages, (f) app id -----------------------------------------------------

    function doHello() {
        helloT0 = System.getTimer();
        sendMsg({"t" => "hello", "n" => tx, "app" => appId(), "dev" => System.getDeviceSettings().partNumber}, "hello", null, false);
    }

    function onPhone(data) {
        rx += 1;
        if (!(data instanceof Lang.Dictionary)) {
            log("rx non-dict");
            return;
        }
        var t = data["t"];
        if ("echo".equals(t)) {
            var rtt = System.getTimer() - helloT0;
            res["rttMs"] = rtt;
            res["echoPhoneBg"] = data["bg"];
            log("echo rtt " + rtt + "ms bg=" + data["bg"]);
        } else if ("ping".equals(t)) {
            sendMsg({"t" => "pong", "n" => data["n"]}, "pong", null, false);
            log("ping " + data["n"]);
        } else if ("tp".equals(t)) {
            res["tpPhoneMs"] = data["ms"];
            res["tpPhoneWireB"] = data["bytes"];
            res["tpPhoneGot"] = data["got"];
            log("phone got " + data["got"] + " wire " + data["bytes"] + "B " + data["ms"] + "ms");
        } else if ("sz".equals(t)) {
            res["wire" + data["f"]] = data["bytes"];
            log("wire " + data["f"] + " " + data["bytes"] + "B/" + data["k"] + "pts");
        } else {
            log("rx " + t);
        }
        WatchUi.requestUpdate();
    }

    // ---- (c) burst of messages, for backgrounding and kill/reopen the phone app -------------------

    function startBurst() {
        if (_job != 0) { return; }
        _job = 1;
        _i = 0;
        _bOk = 0;
        _bFail = 0;
        log("burst start");
        burstTick();
        _tm.start(method(:onTick), BURST_MS, true);
    }

    function burstTick() {
        sendMsg({"t" => "burst", "n" => _i, "up" => System.getTimer()}, "burst" + _i, method(:onBurstDone), true);
        _i += 1;
    }

    function onBurstDone(ok, dt) {
        if (ok) { _bOk += 1; } else { _bFail += 1; }
        res["burstOk"] = _bOk;
        res["burstFail"] = _bFail;
        if (_bOk + _bFail >= BURST_N) {
            log("burst ok " + _bOk + " fail " + _bFail);
            sendResults();
        }
    }

    // ---- (b) throughput: 25 KB in 25 chunks, sequential -------------------------------------------

    function startThroughput() {
        if (_tpBusy) { return; }
        _tpBusy = true;
        _tpI = 0;
        _tpFail = 0;
        _tpT0 = System.getTimer();
        log("tp start");
        sendChunk();
    }

    function sendChunk() {
        sendMsg({"t" => "chunk", "i" => _tpI, "n" => TP_CHUNKS, "d" => kb()}, "chunk" + _tpI, method(:onChunkDone), true);
    }

    function onChunkDone(ok, dt) {
        if (ok) { _tpI += 1; } else { _tpFail += 1; }
        if (_tpI >= TP_CHUNKS || _tpFail > 5) {
            var ms = System.getTimer() - _tpT0;
            _tpBusy = false;
            res["tpChunksOk"] = _tpI;
            res["tpFail"] = _tpFail;
            res["tpMs"] = ms;
            if (ms > 0) {
                res["tpBytesPerSec"] = (_tpI * 1000 * 1000) / ms;
            }
            log("tp " + _tpI + "/" + TP_CHUNKS + " fail " + _tpFail + " " + ms + "ms");
            sendResults();
        } else {
            sendChunk();
        }
    }

    // ---- (d) Storage and memory limits, stepped by a timer so the watchdog never trips ------------

    function memSnap() {
        var s = System.getSystemStats();
        res["memTotal"] = s.totalMemory;
        res["memFree"] = s.freeMemory;
        res["memUsed"] = s.usedMemory;
    }

    function startStorage() {
        if (_job != 0) { return; }
        _job = 2;
        _stage = 0;
        _i = 0;
        memSnap();
        try { Storage.clearValues(); } catch (ex) { }
        log("storage start");
        _tm.start(method(:onTick), 100, true);
    }

    function onTick() {
        if (_job == 1) {
            if (_i >= BURST_N) { _tm.stop(); _job = 0; return; }
            burstTick();
        } else if (_job == 2) {
            storageTick();
        }
    }

    function makeStr(n) {
        var s = "";
        for (var i = 0; i < n / 1000; i += 1) {
            s = s + kb();
        }
        return s;
    }

    function pointA() {
        return [1, 1234, -567, 12, 321, 150];   // dt s, dLat, dLon (~1 m units), alt m, speed cm/s, hr
    }

    function bytesFor(k) {
        var b = new [k * 10]b;                   // 10 B per point: dt u8, dLat s16, dLon s16, alt s16, spd u16... packed LE
        for (var i = 0; i < k; i += 1) {
            var o = i * 10;
            b[o] = 1;
            b[o + 1] = 1234 & 0xFF; b[o + 2] = (1234 >> 8) & 0xFF;
            b[o + 3] = (-567) & 0xFF; b[o + 4] = ((-567) >> 8) & 0xFF;
            b[o + 5] = 12; b[o + 6] = 0;
            b[o + 7] = 321 & 0xFF; b[o + 8] = (321 >> 8) & 0xFF;
            b[o + 9] = 150;
        }
        return b;
    }

    function arrayFor(k) {
        var a = [];
        for (var i = 0; i < k; i += 1) {
            a.add(pointA());
        }
        return a;
    }

    function makeVal(kind) {
        if (kind == 0) { return kb(); }
        if (kind == 1) {
            if (_valA == null) { _valA = arrayFor(100); }
            return _valA;
        }
        if (_valB == null) { _valB = bytesFor(100); }
        return _valB;
    }

    // Writes up to 10 values per tick. Returns true when full or at maxN.
    function fillTick(prefix, kind, maxN) {
        for (var k = 0; k < 10; k += 1) {
            if (_i >= maxN) {
                return true;
            }
            try {
                Storage.setValue(prefix + _i, makeVal(kind));
                _i += 1;
            } catch (ex) {
                log(prefix + " stop at " + _i + ": " + ex.getErrorMessage());
                return true;
            }
        }
        return false;
    }

    // Deletes up to 20 values per tick (from _i down). Returns true when none left.
    function wipeTick(prefix) {
        for (var k = 0; k < 20; k += 1) {
            if (_i <= 0) {
                return true;
            }
            _i -= 1;
            Storage.deleteValue(prefix + _i);
        }
        return false;
    }

    function storageTick() {
        var sizes = [1000, 2000, 4000, 8000, 16000, 32000];
        try {
            if (_stage == 0) {
                // largest single value that Storage accepts (RAM-guarded, uncatchable OOM otherwise)
                if (_i >= sizes.size()) { _stage = 1; _i = 0; return; }
                var n = sizes[_i];
                if (System.getSystemStats().freeMemory < 4 * n + 8000) {
                    log("val " + n + " skipped (RAM)");
                    res["storeValSkipped"] = n;
                    _stage = 1; _i = 0; return;
                }
                try {
                    Storage.setValue("probe", makeStr(n));
                    res["storeValMaxChars"] = n;
                    _i += 1;
                } catch (ex) {
                    log("val " + n + " rejected: " + ex.getErrorMessage());
                    _stage = 1; _i = 0;
                }
                Storage.deleteValue("probe");
            } else if (_stage == 1) {
                if (fillTick("k", 0, 4000)) {
                    res["storeKvals1000ch"] = _i;     // number of 1000-char strings that fit
                    log("storage " + _i + " x 1000ch");
                    _stage = 2;
                }
            } else if (_stage == 2) {
                if (wipeTick("k")) { _stage = 3; _i = 0; }
            } else if (_stage == 3) {
                if (fillTick("pa", 1, 400)) {
                    res["storePtsArrays"] = _i * 100;  // 6-Number points that fit
                    log("storage " + (_i * 100) + " A pts");
                    _stage = 4;
                }
            } else if (_stage == 4) {
                if (wipeTick("pa")) { _stage = 5; _i = 0; }
            } else if (_stage == 5) {
                if (fillTick("pb", 2, 400)) {
                    res["storePtsBytes"] = _i * 100;   // 10-byte packed points that fit
                    log("storage " + (_i * 100) + " B pts");
                    _stage = 6;
                }
            } else if (_stage == 6) {
                if (wipeTick("pb")) {
                    _tm.stop();
                    _job = 0;
                    memSnap();
                    log("storage done");
                    sendResults();
                }
            }
        } catch (ex2) {
            log("storage err " + ex2.getErrorMessage());
            _tm.stop();
            _job = 0;
        }
    }

    // ---- (e) sample size: RAM per point here, wire size measured on the phone ---------------------------

    function doSample() {
        var m0 = System.getSystemStats().usedMemory;
        var a = arrayFor(PTS);
        var m1 = System.getSystemStats().usedMemory;
        var b = bytesFor(PTS);
        var m2 = System.getSystemStats().usedMemory;
        var dicts = [];
        for (var i = 0; i < PTS; i += 1) {
            dicts.add({"dt" => 1, "la" => 1234, "lo" => -567, "al" => 12, "sp" => 321, "hr" => 150});
        }
        var m3 = System.getSystemStats().usedMemory;
        res["ramPerPtArray"] = (m1 - m0) / PTS;
        res["ramPerPtBytes"] = (m2 - m1) / PTS;
        res["ramPerPtDict"] = (m3 - m2) / PTS;
        log("ram/pt A " + res["ramPerPtArray"] + " B " + res["ramPerPtBytes"] + " D " + res["ramPerPtDict"]);
        sendMsg({"t" => "smp", "f" => "A", "k" => PTS, "d" => a}, "smpA", null, false);
        sendMsg({"t" => "smp", "f" => "B", "k" => PTS, "d" => b}, "smpB", null, false);
        sendMsg({"t" => "smp", "f" => "D", "k" => PTS, "d" => dicts}, "smpD", null, false);
    }

    // ---- results -------------------------------------------------------------------------------------

    function sendResults() {
        memSnap();
        var d = {"t" => "res", "app" => appId(), "dev" => System.getDeviceSettings().partNumber, "tx" => tx, "rx" => rx};
        var ks = res.keys();
        for (var i = 0; i < ks.size(); i += 1) {
            d[ks[i]] = res[ks[i]];
        }
        sendMsg(d, "results", null, false);
    }

    // ---- display ---------------------------------------------------------------------------------------

    function v(k) {
        var x = res[k];
        return (x == null) ? "-" : x.toString();
    }

    function pageLines() {
        var names = ["link", "burst", "throughput", "storage", "sample", "results"];
        var s = System.getSystemStats();
        var out = ["G0 " + (page + 1) + "/" + PAGES + " " + names[page],
                   "mem " + (s.usedMemory / 1024) + "/" + (s.totalMemory / 1024) + "K tx" + tx + " rx" + rx];
        if (page == 0) {
            out.add("id " + appId().substring(0, 8) + "..");
            out.add("rtt " + v("rttMs") + "ms");
            out.add("START = hello");
        } else if (page == 1) {
            out.add("ok " + v("burstOk") + " fail " + v("burstFail"));
            out.add("START = 10 msgs/50s");
        } else if (page == 2) {
            out.add(v("tpChunksOk") + "/" + TP_CHUNKS + " fail " + v("tpFail"));
            out.add(v("tpMs") + "ms " + v("tpBytesPerSec") + "B/s");
            out.add("START = send 25KB");
        } else if (page == 3) {
            out.add("val max " + v("storeValMaxChars") + "ch");
            out.add("1k-strs " + v("storeKvals1000ch"));
            out.add("ptsA " + v("storePtsArrays") + " ptsB " + v("storePtsBytes"));
            out.add("START = run");
        } else if (page == 4) {
            out.add("ram/pt A" + v("ramPerPtArray") + " B" + v("ramPerPtBytes") + " D" + v("ramPerPtDict"));
            out.add("wire A" + v("wireA") + " B" + v("wireB") + " D" + v("wireD"));
            out.add("START = measure");
        } else {
            out.add("rtt " + v("rttMs") + " tp " + v("tpBytesPerSec") + "B/s");
            out.add("burst " + v("burstOk") + "/" + v("burstFail"));
            out.add("START = send all");
        }
        var n = logLines.size();
        if (n > 0) {
            out.add(logLines[n - 1]);
        }
        return out;
    }
}
