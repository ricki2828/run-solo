/// The record screen's MAP view over `google_maps_flutter`: the Night Session
/// style, the route so far in the run-type colour, a marker at the current
/// position, and a north-up camera that follows the runner and recentres
/// about 8 s after the user stops panning. Only built while MAP is showing
/// and the screen is on (the record screen owns that); it reads the
/// recorder's copy of the route and never asks for a location itself.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;

import '../state/live_route.dart';
import '../theme/theme.dart';
import 'blank_snapshot.dart';
import 'map_surface.dart';

/// How long after the last pan the camera goes back to the runner.
const Duration kLiveMapRecentre = Duration(seconds: 8);

class LiveGoogleMap extends StatefulWidget {
  const LiveGoogleMap({super.key, required this.track, required this.color});
  final LiveRouteTrack track;
  final Color color;

  @override
  State<LiveGoogleMap> createState() => _LiveGoogleMapState();
}

class _LiveGoogleMapState extends State<LiveGoogleMap> {
  static String? _styleJson;
  static const double _followZoom = 17;

  gm.GoogleMapController? _controller;
  gm.BitmapDescriptor? _dot;
  bool _failed = false;
  bool _checked = false;
  bool _ready = false;
  bool _programmatic = false;
  Timer? _loadWatch;
  Timer? _recentre;

  @override
  void initState() {
    super.initState();
    widget.track.addListener(_onTrack);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    unawaited(_prepare());
    // A rejected key still creates the map (see GoogleRouteMap): if nothing
    // has settled in 10 s, show the route on our own canvas instead.
    _loadWatch = Timer(const Duration(seconds: 10), () {
      if (mounted && !_checked) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    widget.track.removeListener(_onTrack);
    _loadWatch?.cancel();
    _recentre?.cancel();
    super.dispose();
  }

  Future<void> _prepare() async {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    try {
      _styleJson ??= await rootBundle.loadString(
        'assets/maps/night_session.json',
      );
      final size = 22 * dpr;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final c = Offset(size / 2, size / 2);
      canvas.drawCircle(c, 10 * dpr, Paint()..color = t.inkPrimary);
      canvas.drawCircle(c, 7 * dpr, Paint()..color = widget.color);
      final image = await recorder.endRecording().toImage(
        size.ceil(),
        size.ceil(),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      _dot = gm.BytesMapBitmap(
        bytes!.buffer.asUint8List(),
        imagePixelRatio: dpr,
      );
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('live map: prepare failed ($e)');
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onTrack() {
    if (!mounted) return;
    setState(() {});
    if (_recentre == null || !_recentre!.isActive) unawaited(_follow());
  }

  Future<void> _follow() async {
    final c = _controller;
    final p = widget.track.last;
    if (c == null || p == null) return;
    _programmatic = true;
    try {
      await c.animateCamera(gm.CameraUpdate.newLatLng(gm.LatLng(p.lat, p.lon)));
    } catch (_) {
      // The map is optional; the run goes on.
    }
    // The move-started callback of our own move lands before this.
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      _programmatic = false;
    });
  }

  /// Any camera move we did not start is the user panning or zooming: hold
  /// still, then come back to the runner.
  void _onMoveStarted() {
    if (_programmatic) return;
    _recentre?.cancel();
    _recentre = Timer(kLiveMapRecentre, () {
      _recentre = null;
      if (mounted) unawaited(_follow());
    });
  }

  Future<void> _checkBlank() async {
    if (_checked) return;
    final c = _controller;
    if (c == null) return;
    _checked = true;
    _loadWatch?.cancel();
    try {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final png = await c.takeSnapshot();
      if (png == null) {
        if (mounted) setState(() => _failed = true);
        return;
      }
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      final rgba = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final blank =
          rgba == null ||
          isBlankSnapshot(
            rgba.buffer.asUint8List(),
            width: frame.image.width,
            height: frame.image.height,
          );
      if (blank && mounted) setState(() => _failed = true);
    } catch (e) {
      debugPrint('live map: snapshot check failed ($e)');
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = widget.track.points;
    if (_failed) return MapFailedCard(route: liveRouteGeometry(points));
    final last = widget.track.last;
    // Before the first fix there is nowhere to look yet.
    if (last == null || _styleJson == null) {
      return ColoredBox(
        color: Theme.of(context).extension<RunSoloTokens>()!.bgBase,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.card),
      child: gm.GoogleMap(
        key: const ValueKey('live-gmap'),
        initialCameraPosition: gm.CameraPosition(
          target: gm.LatLng(last.lat, last.lon),
          zoom: _followZoom,
        ),
        style: _styleJson,
        liteModeEnabled: false,
        mapToolbarEnabled: false,
        myLocationEnabled: false,
        myLocationButtonEnabled: false,
        compassEnabled: false,
        zoomControlsEnabled: false,
        buildingsEnabled: false,
        trafficEnabled: false,
        // North-up always: no rotate, no tilt.
        rotateGesturesEnabled: false,
        tiltGesturesEnabled: false,
        padding: const EdgeInsets.only(left: 8, bottom: 8),
        polylines: {
          if (points.length > 1)
            gm.Polyline(
              polylineId: const gm.PolylineId('live'),
              points: [for (final p in points) gm.LatLng(p.lat, p.lon)],
              color: widget.color,
              width: 5,
              jointType: gm.JointType.round,
              startCap: gm.Cap.roundCap,
              endCap: gm.Cap.roundCap,
            ),
        },
        markers: {
          if (_dot != null)
            gm.Marker(
              markerId: const gm.MarkerId('me'),
              position: gm.LatLng(last.lat, last.lon),
              icon: _dot!,
              anchor: const Offset(0.5, 0.5),
              flat: true,
            ),
        },
        onMapCreated: (c) => _controller = c,
        onCameraMoveStarted: _onMoveStarted,
        onCameraIdle: _checkBlank,
      ),
    );
  }
}
