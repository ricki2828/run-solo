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
  function when(iso) {
    var d = new Date(iso + "T12:00:00");
    return d.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
  }

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

  function message(title, text) {
    app.replaceChildren();
    var p = el("p", "state");
    p.appendChild(el("b", null, title));
    p.appendChild(document.createTextNode(text));
    app.appendChild(p);
  }

  function bars(values, cls, lane) {
    var wrap = el("div", "bars " + cls + " " + lane);
    var max = Math.max.apply(null, values);
    var min = Math.min.apply(null, values);
    var spread = 1 - min / max;   // how far the slowest is behind the fastest, as speed
    values.forEach(function (v) {
      var i = el("i");
      // taller = faster (speed = 1/time). A spread under 3% is shown flat rather than blown up.
      var f = spread < 0.03 ? 0.8 : 0.4 + 0.6 * ((min / v) - (min / max)) / (1 - min / max);
      i.style.height = Math.round(f * 100) + "%";
      wrap.appendChild(i);
    });
    return wrap;
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
      head.appendChild(el("span", "eyebrow", when(l.date) + " · " + (l.title || TYPE_NAME[l.type] || l.type)));
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
        body.appendChild(bars(l.reps.map(function (r) { return r.time_s; }), "reps", l.lane));
        body.appendChild(el("div", "axis", l.reps.length + " reps"));
      } else if (l.splits) {
        body.appendChild(bars(l.splits.map(function (s) { return s.pace_s; }), "splits", l.lane));
        body.appendChild(el("div", "axis", "pace per km"));
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
    app.appendChild(el("p", "foot", "Only your own runs. Nothing here is new data."));
  }

  function run() {
    app.replaceChildren();
    var l = data.latest;
    var card = el("section", "card " + l.lane);
    var head = el("div", "head");
    head.appendChild(el("span", "eyebrow", when(l.date) + " · " + (l.title || TYPE_NAME[l.type] || l.type)));
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
    if (l.reps) rows("Reps", l.reps, function (r) { return Math.floor(r.time_s / 60) + ":" + String(Math.round(r.time_s % 60)).padStart(2, "0"); }, function (r, i) { return "Rep " + (i + 1); });
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
    if (!init) { message("Open from Telegram", "This page works inside the Run Supreme bot chat."); return; }
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
        if (e === "reopen") message("Reopen me", "This session has expired. Close it and open it again from the coach message.");
        else if (e === "unlinked") message("Not linked", "Turn on the companion in the Run Supreme app first.");
        else message("No signal", "Couldn't load your week. Try again in a moment.");
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
