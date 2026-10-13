(function () {
  "use strict";
  var tg = window.Telegram && window.Telegram.WebApp;
  var app = document.getElementById("app");
  var view = "home";
  var data = null;
  var picked = null;

  var LANE_NAME = { aerobic: "Aerobic", speed: "Speed", mid: "Mid", long: "Long" };
  var TYPE_NAME = { easy: "Easy run", long: "Long run", tempo: "Tempo", interval: "Intervals", race: "Race", cooper: "Cooper test", trail: "Trail run", quality: "Quality" };
  var DOW = ["M", "T", "W", "T", "F", "S", "S"];

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function tap() { try { tg.HapticFeedback.selectionChanged(); } catch (e) {} }
  function pace(s) { return s ? Math.floor(s / 60) + ":" + String(Math.round(s % 60)).padStart(2, "0") + "/km" : null; }
  function dur(s) {
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
    return h ? h + "h " + m + "m" : m + " min";
  }
  var WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  var MO = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  function when(iso) {   // "Tue 13 Oct", as the app writes it
    var p = iso.split("-"), d = new Date(Date.UTC(+p[0], +p[1] - 1, +p[2]));
    return WD[d.getUTCDay()] + " " + d.getUTCDate() + " " + MO[d.getUTCMonth()];
  }
  function mmss(s) { return Math.floor(s / 60) + ":" + String(Math.round(s % 60)).padStart(2, "0"); }

  function applyTheme() {
    var root = document.documentElement;
    var dark = tg ? tg.colorScheme === "dark" : window.matchMedia("(prefers-color-scheme: dark)").matches;
    root.setAttribute("data-theme", dark ? "dark" : "light");
    var p = (tg && tg.themeParams) || {};
    if (p.bg_color) root.style.setProperty("--ground", p.bg_color);
    if (p.text_color) root.style.setProperty("--ink", p.text_color);
    if (p.hint_color) root.style.setProperty("--quiet", p.hint_color);
    try {
      tg.setHeaderColor(p.bg_color || (dark ? "#0F1113" : "#FBFBF9"));
      tg.setBackgroundColor(p.bg_color || (dark ? "#0F1113" : "#FBFBF9"));
    } catch (e) {}
  }

  function message(title, text, steps) {
    app.replaceChildren();
    var hero = el("section", "hero");
    hero.appendChild(el("div", "eyebrow", "Run Supreme"));
    hero.appendChild(el("p", "big", title));
    hero.appendChild(el("p", "lede", text));
    if (steps) {
      var ol = el("ol", "steps");
      steps.forEach(function (s) { ol.appendChild(el("li", null, s)); });
      hero.appendChild(ol);
    }
    app.appendChild(hero);
  }

  // Pace bars, taller = faster. The scale spans at least 30 s/km, so near-equal splits look near-equal.
  function bars(values, lane) {
    var wrap = el("div", "bars " + lane);
    var min = Math.min.apply(null, values), max = Math.max.apply(null, values);
    var span = Math.max(max - min, 30);
    values.forEach(function (v) {
      var i = el("i");
      i.style.height = Math.round((0.4 + 0.6 * (1 - (v - min) / span)) * 100) + "%";
      wrap.appendChild(i);
    });
    return wrap;
  }

  function headline(l) {
    var h = el("span", "eyebrow");
    h.appendChild(el("span", "date", when(l.date)));
    h.appendChild(document.createTextNode(" \u00b7 " + (l.title || TYPE_NAME[l.type] || l.type)));
    return h;
  }

  function home() {
    app.replaceChildren();
    var w = data.week;

    var hero = el("section", "hero");
    hero.appendChild(el("div", "eyebrow", w.label + " · this week"));
    var big = el("p", "big", String(w.done_runs));
    big.appendChild(el("small", null, w.done_runs === 1 ? "run" : "runs"));
    hero.appendChild(big);
    hero.appendChild(el("p", null, w.done_km + " km done" + (w.next ? " · next: " + (TYPE_NAME[w.next.type] || w.next.type).toLowerCase() + " " + when(w.next.day) : "")));
    var days = el("div", "days");
    w.days.forEach(function (d, i) {
      var b = el("button", "day");
      b.type = "button";
      b.setAttribute("aria-pressed", picked === i ? "true" : "false");
      b.appendChild(el("span", "dow", DOW[i]));
      var dot = el("span", "dot");
      var km = 0;
      d.runs.forEach(function (r) { km += r.km; });
      if (d.runs.length) {
        dot.className = "dot has";
        dot.style.background = "var(--" + d.runs[0].lane + ")";
      }
      b.appendChild(dot);
      b.appendChild(el("span", "km", km ? String(Math.round(km * 10) / 10) : ""));
      b.setAttribute("aria-label", when(d.date) + (d.runs.length ? ", " + km.toFixed(1) + " km" : ", no run"));
      b.addEventListener("click", function () { tap(); picked = picked === i ? null : i; home(); });
      days.appendChild(b);
    });
    hero.appendChild(days);
    var line = el("p", "today-run");
    if (picked != null) {
      var d = w.days[picked];
      line.textContent = when(d.date) + ": " + (d.runs.length
        ? d.runs.map(function (r) { return (TYPE_NAME[r.type] || r.type) + " " + r.km + " km"; }).join(", ")
        : "no run");
    }
    hero.appendChild(line);
    app.appendChild(hero);

    var l = data.latest;
    if (l) {
      app.appendChild(el("h2", null, "Latest run"));
      var card = el("button", "card " + l.lane);
      card.type = "button";
      var head = el("div", "head");
      head.appendChild(headline(l));
      var b = el("b", null, String(l.km));
      b.appendChild(el("small", null, "km"));
      head.appendChild(b);
      card.appendChild(head);
      var body = el("div", "body");
      var facts = el("div", "facts");
      [[dur(l.duration_s), "time"], [pace(l.true_pace_s || l.pace_s), "pace"], [l.climb_m ? l.climb_m + " m" : null, "climb"]]
        .forEach(function (f) { if (f[0]) { var s = el("span"); s.appendChild(el("b", null, f[0])); s.appendChild(document.createTextNode(" " + f[1])); facts.appendChild(s); } });
      body.appendChild(facts);
      if (l.reps) {
        var chips = el("div", "chips");   // rep times, labelled: equal reps are the point of a 4x4, so no bars
        l.reps.forEach(function (r) { chips.appendChild(el("span", null, mmss(r.time_s))); });
        body.appendChild(chips);
        body.appendChild(el("div", "axis", l.reps.length + " reps, time each"));
      } else if (l.splits) {
        var ps = l.splits.map(function (s) { return s.pace_s; });
        body.appendChild(bars(ps, l.lane));
        body.appendChild(el("div", "axis", "pace per km, fastest " + pace(Math.min.apply(null, ps)) + ", slowest " + pace(Math.max.apply(null, ps))));
      }
      body.appendChild(el("span", "more", "See the detail"));
      card.appendChild(body);
      card.addEventListener("click", function () { tap(); show("run"); });
      app.appendChild(card);
    }

    app.appendChild(el("h2", null, "Your four lanes"));
    var grid = el("div", "lanes");
    data.lanes.forEach(function (ln) {
      var t = el("button", "lane " + ln.lane);
      t.type = "button";
      t.appendChild(el("span", "eyebrow", LANE_NAME[ln.lane]));
      var c = ln.change;
      var n = el("span", "n" + (c > 0 ? " up" : c < 0 ? " down" : ""), c == null ? "-" : (c > 0 ? "+" : c < 0 ? "−" : "") + Math.abs(c));
      t.appendChild(n);
      var cap = el("span", "cap", c == null ? "no moves yet" : "last " + (data.lane_days / 7) + " weeks");
      t.appendChild(cap);
      t.addEventListener("click", function () { tap(); });
      grid.appendChild(t);
    });
    app.appendChild(grid);
    app.appendChild(el("p", "foot", "Only your runs, from what your coach already has."));
  }

  function run() {
    app.replaceChildren();
    var l = data.latest;
    var card = el("section", "card " + l.lane);
    var head = el("div", "head");
    head.appendChild(headline(l));
    var b = el("b", null, String(l.km));
    b.appendChild(el("small", null, "km"));
    head.appendChild(b);
    card.appendChild(head);
    var body = el("div", "body");
    function rows(title, items, fmt, ranked) {
      body.appendChild(el("h2", null, title));
      var ul = el("ul", "rows");
      items.forEach(function (it, i) {
        var li = el("li");
        li.appendChild(el("span", null, ranked(it, i)));
        li.appendChild(el("b", null, fmt(it)));
        ul.appendChild(li);
      });
      body.appendChild(ul);
    }
    if (l.work_pace_s) body.appendChild(el("p", "facts", "Work pace " + pace(l.work_pace_s) + (l.rep_spread_s ? ", reps within " + l.rep_spread_s + " s" : "")));
    if (l.reps) rows("Reps", l.reps, function (r) { return mmss(r.time_s); }, function (r, i) { return "Rep " + (i + 1); });
    if (l.splits) rows("Splits", l.splits, function (s) { return pace(s.pace_s); }, function (s, i) { return s.km < 1 ? s.km + " km" : "Km " + (i + 1); });
    if (!l.reps && !l.splits) body.appendChild(el("p", "state", "No splits were sent for this run."));
    card.appendChild(body);
    app.appendChild(card);
  }

  function show(v) {
    view = v;
    try { if (v === "run") tg.BackButton.show(); else tg.BackButton.hide(); } catch (e) {}
    window.scrollTo(0, 0);
    if (v === "run" && data.latest) run(); else home();
  }

  function load() {
    var init = tg && tg.initData;
    if (!init) { message("Open from Telegram", "This page works inside your Run Supreme coach chat.", ["Open the coach chat in Telegram", "Tap Open the week under a run card"]); return; }
    fetch("api/me", { headers: { Authorization: "tma " + init }, cache: "no-store", credentials: "omit", referrerPolicy: "no-referrer" })
      .then(function (r) {
        if (r.status === 401) throw "reopen";
        if (r.status === 403) throw "unlinked";
        if (!r.ok) throw "fail";
        return r.json();
      })
      .then(function (j) {
        data = j;
        if (!j.latest && !j.week.done_runs) { home(); return; }
        show("home");
      })
      .catch(function (e) {
        if (e === "reopen") message("Reopen me", "This session has expired.", ["Close this page", "Tap Open the week again in the coach chat"]);
        else if (e === "unlinked") message("Not linked", "Your Telegram isn\u2019t connected to the Run Supreme app yet.", ["Open the Run Supreme app", "Go to Settings, then Run companion", "Tap Turn on and follow the steps"]);
        else message("No signal", "Couldn\u2019t load your week. Try again in a moment.");
      });
  }

  applyTheme();
  if (tg) {
    try { tg.ready(); tg.expand(); tg.disableVerticalSwipes && tg.disableVerticalSwipes(); } catch (e) {}
    try { if (tg.requestFullscreen && tg.isVersionAtLeast("8.0")) tg.requestFullscreen(); } catch (e) {}
    try { tg.onEvent("themeChanged", applyTheme); tg.BackButton.onClick(function () { tap(); show("home"); }); } catch (e) {}
  }
  load();
})();
