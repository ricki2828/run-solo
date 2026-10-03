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
import 'route_builder.dart';
import '../theme/theme.dart';
import 'blank_snapshot.dart';
import 'map_surface.dart';

/// How long after the last pan the camera goes back to the runner.
const Duration kLiveMapRecentre = Duration(seconds: 8);

class LiveGoogleMap extends StatefulWidget {
  const LiveGoogleMap({
    super.key,
    required this.track,
    required this.color,
    this.plan,
    this.terrain = false,
  });
  final LiveRouteTrack track;
  final Color color;

  /// A route being followed (Follow a route), drawn under the track.
  final List<GeoPoint>? plan;

  /// Google's terrain map (contours), for Free and Trail runs. Styles apply
  /// to the normal map type only, so terrain is Google's own look.
  final bool terrain;

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

  /// The polyline's points for display: appended as the route grows and
  /// thinned (Douglas-Peucker) when it passes [_maxDisplayPoints]; native
  /// keeps the full route. [_epoch] restarts it when the route is cleared.
  static const int _maxDisplayPoints = 2000;
  final List<gm.LatLng> _line = [];
  int _fed = 0;
  int _epoch = 0;

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
      if (!mounted || _checked) return;
      recordMapVerdict(
        'live map',
        const SnapshotVerdict(blank: true, reason: 'no idle in 10 s'),
        mapType: widget.terrain ? 'terrain' : 'night',
      );
      setState(() => _failed = true);
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

  /// The followed route as map points (made once per plan).
  List<gm.LatLng> _planCache = const [];
  List<GeoPoint>? _planFor;

  List<gm.LatLng> get _plan {
    final plan = widget.plan;
    if (!identical(plan, _planFor)) {
      _planFor = plan;
      _planCache = plan == null
          ? const []
          : [for (final p in plan) gm.LatLng(p.lat, p.lon)];
    }
    return _planCache;
  }

  void _syncLine() {
    final track = widget.track;
    if (track.epoch != _epoch || track.count < _fed) {
      _epoch = track.epoch;
      _line.clear();
      _fed = 0;
    }
    for (final p in track.since(_fed)) {
      _line.add(gm.LatLng(p.lat, p.lon));
    }
    _fed = track.count;
    if (_line.length > _maxDisplayPoints) {
      final thin = simplifyForDisplay([
        for (final p in _line) GeoPoint(p.latitude, p.longitude),
      ], _maxDisplayPoints ~/ 2);
      _line
        ..clear()
        ..addAll([for (final p in thin) gm.LatLng(p.lat, p.lon)]);
    }
  }

  void _onTrack() {
    if (!mounted) return;
    _syncLine();
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
        recordMapVerdict(
          'live map',
          const SnapshotVerdict(blank: true, reason: 'no snapshot'),
          mapType: widget.terrain ? 'terrain' : 'night',
        );
        if (mounted) setState(() => _failed = true);
        return;
      }
      final verdict = await judgeSnapshotPng(png);
      recordMapVerdict(
        'live map',
        verdict,
        mapType: widget.terrain ? 'terrain' : 'night',
      );
      final blank = verdict.blank;
      if (blank && mounted) setState(() => _failed = true);
    } catch (e) {
      debugPrint('live map: snapshot check failed ($e)');
      recordMapVerdict(
        'live map',
        SnapshotVerdict(blank: true, reason: 'snapshot error: $e'),
        mapType: widget.terrain ? 'terrain' : 'night',
      );
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return RouteShape(
        route: liveRouteGeometry(widget.track.points, plan: widget.plan),
        color: widget.plan == null ? null : widget.color,
        plan: widget.plan,
        caption: 'Map failed to load',
      );
    }
    if (_fed != widget.track.count) _syncLine();
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
        mapType: widget.terrain ? gm.MapType.terrain : gm.MapType.normal,
        style: widget.terrain ? null : _styleJson,
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
          // The route being followed: a dark casing and a muted Bone line,
          // under the runner's own track in the run type's colour.
          if (_plan.length > 1) ...[
            gm.Polyline(
              polylineId: const gm.PolylineId('plan-casing'),
              points: _plan,
              color: Theme.of(context).extension<RunSoloTokens>()!.bgBase,
              width: 9,
              jointType: gm.JointType.round,
              startCap: gm.Cap.roundCap,
              endCap: gm.Cap.roundCap,
            ),
            gm.Polyline(
              polylineId: const gm.PolylineId('plan'),
              points: _plan,
              color: Theme.of(context).extension<RunSoloTokens>()!.inkSecondary,
              width: 5,
              jointType: gm.JointType.round,
              startCap: gm.Cap.roundCap,
              endCap: gm.Cap.roundCap,
            ),
          ],
          if (_line.length > 1 && widget.terrain)
            gm.Polyline(
              polylineId: const gm.PolylineId('live-casing'),
              points: List.of(_line),
              color: Theme.of(context).extension<RunSoloTokens>()!.bgBase,
              width: 9,
              jointType: gm.JointType.round,
              startCap: gm.Cap.roundCap,
              endCap: gm.Cap.roundCap,
            ),
          if (_line.length > 1)
            gm.Polyline(
              polylineId: const gm.PolylineId('live'),
              points: List.of(_line),
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
