Preview renderer for `assets/maps/aurora_topo.json` (dev tool, not shipped).

    cd tools/topo/preview && npm i
    GLYPHS_DIR=<dir holding "Noto Sans Regular|Medium|Italic"/{0-255,256-511,768-1023}.pbf> \
      node shot.js ../../../assets/maps/aurora_topo.json \
      '[{"pack":"umbria","lon":12.60,"lat":43.07,"zoom":14,"route":true,"out":"/tmp/u14.png"}]'

Packs are read from `PACKS` in shot.js (`topo-packs-out/<id>/`). Chromium is `/snap/bin/chromium`;
software WebGL (swiftshader) works on the aarch64 host. `route:true` draws one test line per
run-type colour. Glyphs: copy from https://protomaps.github.io/basemaps-assets/fonts/ (do not hotlink in the app).
