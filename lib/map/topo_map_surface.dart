/// T0 spike: the second map engine behind [MapSurfaceFactory]. A Topo map
/// reads a regional PMTiles file from disk (`pmtiles://file://`) through
/// `maplibre_gl`. Stub only: run detail and live map draw the route over the
/// tiles; cards fall back to [RouteShape]. Not wired into
/// `AppServices.production()` (see ~/ai/state/run-supreme-topo-t0.md).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:path_provider/path_provider.dart';

import '../state/live_route.dart';
import 'map_surface.dart';
import 'route_builder.dart';

/// Where the spike's pack lives once copied out of the APK. MapLibre Native
/// reads tiles, glyphs and style by path, so nothing can stay inside assets.
class TopoPack {
  const TopoPack._(this.dir);
  final String dir;

  String get pmtilesPath => '$dir/sbg.pmtiles';
  String get stylePath => '$dir/style.json';

  /// The style as a JSON string (for the `setStyle(json)` path).
  String get styleJson => jsonEncode(topoStyle(dir));

  static Future<TopoPack>? _prepared;

  /// Copies the asset pmtiles + glyph range to the app files dir (once per
  /// process) and writes `style.json` there.
  static Future<TopoPack> prepare() => _prepared ??= _prepare();

  static Future<TopoPack> _prepare() async {
    final root = await getApplicationSupportDirectory();
    final dir = '${root.path}/topo';
    await Directory('$dir/glyphs/NotoSans').create(recursive: true);
    Future<void> copy(String asset, String to) async {
      final data = await rootBundle.load(asset);
      await File(to).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }

    await copy('assets/topo/sbg.pmtiles', '$dir/sbg.pmtiles');
    await copy(
      'assets/topo/glyphs/NotoSans/0-255.pbf',
      '$dir/glyphs/NotoSans/0-255.pbf',
    );
    await File('$dir/style.json').writeAsString(jsonEncode(topoStyle(dir)));
    return TopoPack._(dir);
  }
}

/// Night Session greys over the Protomaps schema. Glyphs are `file://`
/// because the native engine fetches them itself.
Map<String, Object?> topoStyle(String dir) {
  const font = ['NotoSans'];
  Map<String, Object?> fill(
    String id,
    String layer,
    String color, {
    List<Object?>? filter,
    int minzoom = 0,
  }) => {
    'id': id,
    'type': 'fill',
    'source': 'topo',
    'source-layer': layer,
    'minzoom': minzoom,
    'filter': ?filter,
    'paint': {'fill-color': color},
  };
  Map<String, Object?> line(
    String id,
    List<Object?> filter,
    String color,
    Object width, {
    List<double>? dash,
  }) => {
    'id': id,
    'type': 'line',
    'source': 'topo',
    'source-layer': 'roads',
    'filter': filter,
    'layout': {'line-cap': 'round', 'line-join': 'round'},
    'paint': {
      'line-color': color,
      'line-width': width,
      'line-dasharray': ?dash,
    },
  };
  Map<String, Object?> label(
    String id,
    String layer,
    double size, {
    List<Object?>? filter,
    bool along = false,
  }) => {
    'id': id,
    'type': 'symbol',
    'source': 'topo',
    'source-layer': layer,
    'filter': ?filter,
    'layout': {
      'text-field': ['get', 'name'],
      'text-font': font,
      'text-size': size,
      if (along) 'symbol-placement': 'line',
    },
    'paint': {
      'text-color': '#8A8F98',
      'text-halo-color': '#050506',
      'text-halo-width': 1.5,
    },
  };
  return {
    'version': 8,
    'name': 'topo-t0',
    'glyphs': 'file://$dir/glyphs/{fontstack}/{range}.pbf',
    'sources': {
      'topo': {
        'type': 'vector',
        'url': 'pmtiles://file://$dir/sbg.pmtiles',
        'attribution': '(c) OpenStreetMap contributors, Protomaps',
      },
    },
    'layers': [
      {
        'id': 'bg',
        'type': 'background',
        'paint': {'background-color': '#050506'},
      },
      fill('earth', 'earth', '#0B0D0F'),
      fill('landcover', 'landcover', '#0F1614'),
      fill('landuse', 'landuse', '#0F1614'),
      fill('water', 'water', '#16212B'),
      fill('buildings', 'buildings', '#1A1D21', minzoom: 13),
      line('road-major', ['in', 'kind', 'highway', 'major_road'], '#4A5058', 3),
      line(
        'road-minor',
        ['in', 'kind', 'medium_road', 'minor_road', 'other'],
        '#2F343A',
        1.6,
      ),
      line('path', ['==', 'kind', 'path'], '#8A8F98', 1.4, dash: [2, 1.5]),
      label('road-names', 'roads', 11, along: true),
      label('places', 'places', 14),
    ],
  };
}

class TopoMapSurfaceFactory implements MapSurfaceFactory {
  const TopoMapSurfaceFactory();

  @override
  bool get available => true;

  @override
  Widget build(
    BuildContext context,
    RouteGeometry route, {
    bool interactive = false,
    ValueChanged<int?>? onLapTap,
    bool terrain = false,
  }) {
    if (route.isEmpty) return RouteShape(route: route);
    return TopoMap(route: route.points);
  }

  @override
  Widget buildLive(
    BuildContext context, {
    required LiveRouteTrack track,
    required Color color,
    List<GeoPoint>? plan,
    bool terrain = false,
  }) => ListenableBuilder(
    listenable: track,
    builder: (context, _) => TopoMap(route: track.points, color: color),
  );

  @override
  Widget buildCard(
    BuildContext context,
    RouteGeometry route, {
    required String runId,
    Color? routeColor,
  }) => RouteShape(route: route, color: routeColor);

  @override
  Future<void> pruneCards(Set<String> liveRunIds) async {}
}

/// A MapLibre map over the local pack with [route] drawn on top. [viaJson]
/// hands the style over as a JSON string instead of a file path (the spike
/// compares both, because `takeSnapshot` re-reads the style by URI).
class TopoMap extends StatefulWidget {
  const TopoMap({
    super.key,
    required this.route,
    this.color = const Color(0xFFF2EFE6),
    this.centre,
    this.zoom = 14.5,
    this.viaJson = false,
    this.onReady,
  });
  final List<GeoPoint> route;
  final Color color;
  final GeoPoint? centre;
  final double zoom;
  final bool viaJson;

  /// Fired when the style has loaded; hands over the controller (spike hook).
  final void Function(ml.MapLibreMapController controller)? onReady;

  @override
  State<TopoMap> createState() => _TopoMapState();
}

class _TopoMapState extends State<TopoMap> {
  late final Future<TopoPack> _pack = TopoPack.prepare();
  ml.MapLibreMapController? _controller;

  @override
  Widget build(BuildContext context) => FutureBuilder<TopoPack>(
    future: _pack,
    builder: (context, snap) {
      final pack = snap.data;
      if (pack == null) return const ColoredBox(color: Color(0xFF050506));
      final c = widget.centre ?? const GeoPoint(1.3115, 103.8150);
      return ml.MapLibreMap(
        styleString: widget.viaJson ? pack.styleJson : pack.stylePath,
        initialCameraPosition: ml.CameraPosition(
          target: ml.LatLng(c.lat, c.lon),
          zoom: widget.zoom,
        ),
        onMapCreated: (controller) => _controller = controller,
        onStyleLoadedCallback: _onStyle,
        rotateGesturesEnabled: false,
        tiltGesturesEnabled: false,
      );
    },
  );

  Future<void> _onStyle() async {
    final controller = _controller;
    if (controller == null) return;
    if (widget.route.length > 1) {
      await controller.addLine(
        ml.LineOptions(
          geometry: [for (final p in widget.route) ml.LatLng(p.lat, p.lon)],
          lineColor:
              '#${(widget.color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
          lineWidth: 4,
        ),
      );
    }
    widget.onReady?.call(controller);
  }
}
