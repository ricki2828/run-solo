/// T0 spike entrypoint (`flutter build apk -t lib/topo_spike_main.dart`), never
/// shipped. Walks Google, Topo, Google, Topo (JSON style), then both at once,
/// and prints `TOPO_SPIKE ...` lines that tools/emulator_topo_spike.sh greps.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:path_provider/path_provider.dart';

import 'map/route_builder.dart';
import 'map/topo_map_surface.dart';

void log(String m) => debugPrint('TOPO_SPIKE $m');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _Spike()));
}

enum _Stage { google1, topo1, google2, topo2Json, both, done }

class _Spike extends StatefulWidget {
  const _Spike();

  @override
  State<_Spike> createState() => _SpikeState();
}

class _SpikeState extends State<_Spike> {
  _Stage _stage = _Stage.google1;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    log('start');
    for (final next in [
      _Stage.topo1,
      _Stage.google2,
      _Stage.topo2Json,
      _Stage.both,
      _Stage.done,
    ]) {
      await Future<void>.delayed(const Duration(seconds: 9));
      log('stage_end ${_stage.name}');
      if (!mounted) return;
      setState(() => _stage = next);
      log('stage_begin ${next.name}');
    }
    log('DONE');
  }

  static const _google = gm.GoogleMap(
    initialCameraPosition: gm.CameraPosition(
      target: gm.LatLng(1.3115, 103.8150),
      zoom: 15,
    ),
  );

  Widget _topo(String name, {bool viaJson = false}) => TopoMap(
    key: ValueKey(name),
    route: const [
      GeoPoint(1.3090, 103.8140),
      GeoPoint(1.3105, 103.8155),
      GeoPoint(1.3125, 103.8148),
    ],
    viaJson: viaJson,
    onReady: (c) => unawaited(_snapshot(name, c)),
  );

  Future<void> _snapshot(String name, ml.MapLibreMapController c) async {
    log('style_loaded $name');
    await Future<void>.delayed(const Duration(seconds: 3));
    try {
      final Uint8List png = await c.takeSnapshot();
      final codec = await ui.instantiateImageCodec(png);
      final img = (await codec.getNextFrame()).image;
      final raw = (await img.toByteData())!.buffer.asUint8List();
      final colours = <int>{};
      for (var i = 0; i + 3 < raw.length; i += 4 * 7) {
        colours.add(
          ((raw[i] >> 3) << 10) | ((raw[i + 1] >> 3) << 5) | (raw[i + 2] >> 3),
        );
      }
      log(
        'snapshot $name bytes=${png.length} ${img.width}x${img.height} '
        'distinct_colours=${colours.length}',
      );
      final dir = await getExternalStorageDirectory();
      if (dir != null) {
        await File('${dir.path}/snap_$name.png').writeAsBytes(png);
      }
    } on Object catch (e) {
      log('snapshot $name FAILED $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: switch (_stage) {
      _Stage.google1 || _Stage.google2 => _google,
      _Stage.topo1 => _topo('topo1'),
      _Stage.topo2Json => _topo('topo2json', viaJson: true),
      _Stage.both => Column(
        children: [
          const Expanded(child: _google),
          Expanded(child: _topo('both')),
        ],
      ),
      _Stage.done => const Center(child: Text('done')),
    },
  );
}
