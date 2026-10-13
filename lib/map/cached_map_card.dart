/// The map background behind a Home recent-run card. Shows the cached map
/// snapshot (map only, dimmed) with the route drawn over it by [RouteShape]
/// in the run-type colour. Until a snapshot exists the card is today's
/// opaque [RouteShape], and the map renders once underneath it, one card at
/// a time through [RenderQueue]. A failed render leaves the [RouteShape]: no
/// caption, no blank box, and a persisted retry cap. No `google_maps_flutter`
/// import here, so the logic runs under flutter_test with a fake renderer.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'map_surface.dart';
import 'render_queue.dart';
import 'route_builder.dart';
import 'snapshot_cache.dart';

/// Builds the one-shot live map for the given card size. It must call
/// `onSnapshot` with a verified map-only PNG, or `onFailed(kind)`.
typedef CardMapRenderer = Widget Function(
  Size size,
  ValueChanged<Uint8List> onSnapshot,
  ValueChanged<MapFailure> onFailed,
);

/// Saturation 0.55: busy tile colours step back, the route stays the colour.
const List<double> _muted = [
  0.6457, 0.3218, 0.0325, 0, 0, //
  0.0957, 0.8718, 0.0325, 0, 0, //
  0.0957, 0.3218, 0.5825, 0, 0, //
  0, 0, 0, 1, 0, //
];

class CachedMapCard extends StatefulWidget {
  const CachedMapCard({
    super.key,
    required this.route,
    required this.cacheKey,
    required this.cache,
    required this.queue,
    required this.renderer,
    this.routeColor,
    this.bakedRoute = false,
  });
  final RouteGeometry route;

  /// The renderer's snapshot already has the route drawn in: no overlay.
  final bool bakedRoute;
  final Color? routeColor;
  final String Function(Size size, double pixelRatio) cacheKey;
  final MapCardStore cache;
  final RenderQueue queue;
  final CardMapRenderer renderer;

  @override
  State<CachedMapCard> createState() => _CachedMapCardState();
}

class _CachedMapCardState extends State<CachedMapCard> {
  String? _key;
  Size _size = Size.zero;
  Uint8List? _png;
  bool _rendering = false;
  RenderTicket? _ticket;
  bool _resizeScheduled = false;

  @override
  void dispose() {
    _ticket?.release();
    super.dispose();
  }

  /// Runs after layout, never inside build.
  void _resize(Size size, double dpr) {
    _resizeScheduled = false;
    if (!mounted || size.isEmpty) return;
    final key = widget.cacheKey(size, dpr);
    if (key == _key) return;
    _ticket?.release();
    _ticket = null;
    setState(() {
      _size = size;
      _key = key;
      _png = null;
      _rendering = false;
    });
    _load(key);
  }

  Future<void> _load(String key) async {
    final hit = await widget.cache.read(key);
    if (!mounted || _key != key) return;
    if (hit != null) {
      setState(() => _png = hit);
      return;
    }
    if (!await widget.cache.mayRender(key)) return;
    if (!mounted || _key != key) return;
    final ticket = widget.queue.enqueue();
    _ticket = ticket;
    final granted = await ticket.turn;
    if (!granted || !mounted || _key != key) {
      ticket.release();
      return;
    }
    setState(() => _rendering = true);
  }

  void _finish(String key) {
    _ticket?.release();
    _ticket = null;
    if (mounted && _key == key) setState(() => _rendering = false);
  }

  void _onSnapshot(String key, Uint8List png) {
    // The cache write must not depend on the card still being on screen.
    widget.cache.write(key, png);
    widget.cache.clearFailures(key);
    if (mounted && _key == key) setState(() => _png = png);
    _finish(key);
  }

  void _onFailed(String key, MapFailure kind) {
    widget.cache.recordFailure(key, kind);
    _finish(key);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return LayoutBuilder(
      builder: (context, c) {
        final size = Size(
          c.hasBoundedWidth ? c.maxWidth : 0,
          c.hasBoundedHeight ? c.maxHeight : 0,
        );
        if (!size.isEmpty && size != _size && !_resizeScheduled) {
          _resizeScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _resize(size, dpr),
          );
        }
        final key = _key;
        final png = _png;
        return Stack(
          fit: StackFit.expand,
          children: [
            // Live map sits under the opaque RouteShape while it renders.
            if (_rendering && png == null && key != null)
              widget.renderer(
                _size,
                (b) => _onSnapshot(key, b),
                (kind) => _onFailed(key, kind),
              ),
            if (png == null)
              RouteShape(
                route: widget.route,
                color: widget.routeColor,
                card: true,
              )
            else ...[
              Stack(
                fit: StackFit.expand,
                children: [
                  // A drawn route is muted ground for the glow to sit on; a
                  // baked route (Topo) keeps its own colours.
                  ColorFiltered(
                    colorFilter: widget.bakedRoute
                        ? const ColorFilter.mode(
                            Colors.transparent,
                            BlendMode.dst,
                          )
                        : const ColorFilter.matrix(_muted),
                    child: Image.memory(
                      png,
                      key: const ValueKey('card-map-image'),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => ColoredBox(color: t.bgRaised),
                    ),
                  ),
                  // Tint toward the run colour so the map reads as part of
                  // the card, then dim a touch so the place stays readable.
                  if (!widget.bakedRoute && widget.routeColor != null)
                    ColoredBox(
                      color: widget.routeColor!.withValues(alpha: 0.14),
                    ),
                  ColoredBox(color: t.bgBase.withValues(alpha: 0.1)),
                ],
              ),
              if (!widget.bakedRoute)
                RouteShape(
                  route: widget.route,
                  color: widget.routeColor,
                  overlay: true,
                ),
            ],
          ],
        );
      },
    );
  }
}
