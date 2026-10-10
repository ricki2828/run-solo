/// The map choice for Free and Trail runs: offline Topo (MapLibre over an
/// installed pack) or Google's terrain map. Every other run type, and every
/// place no pack covers, goes straight to the wrapped Google factory.
///
/// One engine is mounted at a time (T0 spike: ~55 MB more RAM with both, and
/// the live screen is the tightest place for memory). The choice is
/// remembered in [AppSettings.topoMap]; a run outside every installed pack
/// falls back to Google (or the route on our own canvas) with a one-line
/// prompt that opens Settings, Offline maps.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/routes.dart';
import '../state/live_route.dart';
import '../state/settings.dart';
import '../theme/theme.dart';
import '../topo/pack_manager.dart';
import '../topo/pack_models.dart';
import 'gradient_legend.dart';
import 'map_surface.dart';
import 'route_builder.dart';
import 'snapshot_cache.dart';
import 'cached_map_card.dart';
import 'render_queue.dart';

/// The Topo drawing side: the MapLibre widgets in production, plain boxes in
/// tests (a platform view renders nothing under `flutter_test`).
abstract class TopoEngine {
  /// Run detail map (4:3 card or full screen when [interactive]).
  Widget detail(
    InstalledPack pack, {
    required RouteGeometry route,
    List<GeoPoint>? plan,
    Color? routeColor,
    bool interactive = false,
  });

  /// The record screen's follow-the-runner map.
  Widget live(
    InstalledPack pack, {
    required LiveRouteTrack track,
    required Color color,
    List<GeoPoint>? plan,
  });

  /// The one-shot map behind a Home card: must call [onSnapshot] with a
  /// verified PNG that already has the route in [routeColor] drawn in, or
  /// [onFailed].
  Widget card(
    InstalledPack pack,
    RouteGeometry route, {
    required Color routeColor,
    required ValueChanged<Uint8List> onSnapshot,
    required ValueChanged<MapFailure> onFailed,
  });
}

class TopoMapSurfaceFactory implements MapSurfaceFactory {
  TopoMapSurfaceFactory({
    required this.packs,
    required this.settings,
    required this.fallback,
    required this.engine,
    MapCardStore? cache,
    RenderQueue? queue,
  }) : _cache = cache ?? MapSnapshotCache.shared,
       _queue = queue ?? RenderQueue.shared;

  final PackManager packs;
  final SettingsController settings;

  /// Google (or whatever the build uses without Topo).
  final MapSurfaceFactory fallback;
  final TopoEngine engine;
  final MapCardStore _cache;
  final RenderQueue _queue;

  /// A pack-only phone (no Maps key) still gets maps where a pack covers.
  @override
  bool get available => fallback.available || packs.installed.isNotEmpty;

  bool get _topoWanted => settings.settings.topoMap;

  /// The installed pack that holds the whole of [b], or null.
  InstalledPack? packForBounds(GeoBounds? b) {
    if (b == null) return null;
    final p = packs.packCovering(b.centre.lat, b.centre.lon);
    if (p == null) return null;
    return p.region.contains(b.south, b.west) &&
            p.region.contains(b.north, b.east)
        ? p
        : null;
  }

  @override
  bool needsGoogle(RouteGeometry route, {bool terrain = false}) =>
      !(terrain && _topoWanted && packForBounds(route.bounds) != null);

  @override
  Widget build(
    BuildContext context,
    RouteGeometry route, {
    bool interactive = false,
    ValueChanged<int?>? onLapTap,
    bool terrain = false,
    List<GeoPoint>? plan,
    Color? routeColor,
  }) {
    Widget google() => fallback.build(
      context,
      route,
      interactive: interactive,
      onLapTap: onLapTap,
      terrain: terrain,
      plan: plan,
      routeColor: routeColor,
    );
    if (!terrain || route.isEmpty) return google();
    return ListenableBuilder(
      listenable: Listenable.merge([settings, packs]),
      builder: (context, _) {
        final pack = _topoWanted ? packForBounds(route.bounds) : null;
        return _Choice(
          pack: pack,
          topoWanted: _topoWanted,
          onToggle: _setTopo,
          child: pack == null
              ? google()
              : engine.detail(
                  pack,
                  route: route,
                  plan: plan,
                  routeColor: routeColor,
                  interactive: interactive,
                ),
        );
      },
    );
  }

  @override
  Widget buildLive(
    BuildContext context, {
    required LiveRouteTrack track,
    required Color color,
    List<GeoPoint>? plan,
    bool terrain = false,
  }) {
    Widget google() => fallback.buildLive(
      context,
      track: track,
      color: color,
      plan: plan,
      terrain: terrain,
    );
    if (!terrain) return google();
    return _LiveChoice(factory: this, track: track, color: color, plan: plan);
  }

  @override
  Widget buildCard(
    BuildContext context,
    RouteGeometry route, {
    required String runId,
    Color? routeColor,
    bool terrain = false,
  }) {
    final pack = terrain && _topoWanted ? packForBounds(route.bounds) : null;
    if (pack == null || route.isEmpty) {
      return fallback.buildCard(
        context,
        route,
        runId: runId,
        routeColor: routeColor,
        terrain: terrain,
      );
    }
    final hash = routeFingerprint(route);
    final colour =
        routeColor ?? Theme.of(context).extension<RunSoloTokens>()!.inkPrimary;
    return Stack(
      fit: StackFit.expand,
      children: [
        CachedMapCard(
          route: route,
          routeColor: routeColor,
          bakedRoute: true,
          cacheKey: (size, dpr) => MapSnapshotCache.keyFor(
            runId: runId,
            styleVersion: kMapStyleVersion,
            routeHash: hash,
            width: size.width,
            height: size.height,
            pixelRatio: dpr,
            engine:
                'topo-${pack.id}-${pack.version}-'
                '${colour.toARGB32().toRadixString(16)}',
          ),
          cache: _cache,
          queue: _queue,
          renderer: (size, onSnapshot, onFailed) => engine.card(
            pack,
            route,
            routeColor: colour,
            onSnapshot: onSnapshot,
            onFailed: onFailed,
          ),
        ),
        if (pack.region.mapText.isNotEmpty)
          Positioned(
            left: Space.x8,
            right: Space.x8,
            bottom: Space.x4,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.bottomRight,
                child: CreditPlate(pack: pack, tappable: false, compact: true),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Future<void> pruneCards(Set<String> liveRunIds) =>
      fallback.pruneCards(liveRunIds);

  Future<void> _setTopo(bool on) =>
      settings.update((s) => s.copyWith(topoMap: on));
}

/// The live map with the engine latched once a pack covers the runner: a
/// fix that wobbles over a pack's edge must not swap engines mid-run. It
/// re-looks only when the runner has really left the pack (or the choice or
/// the installed set changes).
class _LiveChoice extends StatefulWidget {
  const _LiveChoice({
    required this.factory,
    required this.track,
    required this.color,
    this.plan,
  });
  final TopoMapSurfaceFactory factory;
  final LiveRouteTrack track;
  final Color color;
  final List<GeoPoint>? plan;

  @override
  State<_LiveChoice> createState() => _LiveChoiceState();
}

class _LiveChoiceState extends State<_LiveChoice> {
  String? _latchedId;

  InstalledPack? _pick() {
    final f = widget.factory;
    if (!f._topoWanted) {
      _latchedId = null;
      return null;
    }
    final last = widget.track.last;
    final at = last ?? widget.plan?.firstOrNull;
    if (at == null) return null;
    if (_latchedId != null) {
      for (final p in f.packs.installed) {
        if (p.id == _latchedId && p.region.contains(at.lat, at.lon)) return p;
      }
    }
    final p = f.packs.packCovering(at.lat, at.lon);
    _latchedId = p?.id;
    return p;
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.factory;
    return ListenableBuilder(
      listenable: Listenable.merge([f.settings, f.packs, widget.track]),
      builder: (context, _) {
        final pack = _pick();
        return _Choice(
          pack: pack,
          topoWanted: f._topoWanted,
          onToggle: f._setTopo,
          legend:
              (widget.plan?.any((p) => p.ele != null) ?? false) ||
              widget.track.elevations.any((e) => e != null),
          child: pack == null
              ? f.fallback.buildLive(
                  context,
                  track: widget.track,
                  color: widget.color,
                  plan: widget.plan,
                  terrain: true,
                )
              : f.engine.live(
                  pack,
                  track: widget.track,
                  color: widget.color,
                  plan: widget.plan,
                ),
        );
      },
    );
  }
}

/// The chosen map plus the switch, the "download" line when Topo is wanted
/// but nothing covers, and the pack's attribution when Topo is showing.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.pack,
    required this.topoWanted,
    required this.onToggle,
    required this.child,
    this.legend = false,
  });

  /// Show the gradient key: only while Topo is the map drawing the gradient.
  final bool legend;
  final InstalledPack? pack;
  final bool topoWanted;
  final Future<void> Function(bool) onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final showing = pack;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Keyed by engine: a switch disposes the old map before the new one
        // is built, so two engines are never alive together.
        KeyedSubtree(
          key: ValueKey(showing == null ? 'engine-google' : 'engine-topo'),
          child: child,
        ),
        Positioned(
          top: Space.x8,
          right: Space.x8,
          child: MapStyleToggle(topo: topoWanted, onChanged: onToggle),
        ),
        if (showing != null && legend)
          const Positioned(
            left: Space.x8,
            bottom: Space.x48,
            child: GradientLegend(),
          ),
        if (showing != null && showing.region.mapText.isNotEmpty)
          Positioned(
            left: Space.x8,
            right: Space.x8,
            bottom: Space.x8,
            child: Align(
              alignment: Alignment.bottomRight,
              child: CreditPlate(pack: showing),
            ),
          ),
        if (showing == null && topoWanted)
          Positioned(
            left: Space.x8,
            right: Space.x8,
            bottom: Space.x8,
            child: const _DownloadPrompt(),
          ),
      ],
    );
  }
}

/// Topo | Google, two segments, 48 dp tall hit area.
class MapStyleToggle extends StatelessWidget {
  const MapStyleToggle({
    super.key,
    required this.topo,
    required this.onChanged,
  });
  final bool topo;
  final Future<void> Function(bool topo) onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    Widget seg(String label, bool on, bool value) => Semantics(
      button: true,
      selected: on,
      label: '$label map',
      excludeSemantics: true,
      child: InkResponse(
        key: ValueKey('map-style-${label.toLowerCase()}'),
        onTap: on ? null : () => onChanged(value),
        child: Container(
          constraints: const BoxConstraints(minWidth: 56),
          height: 36,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: Space.x12),
          decoration: BoxDecoration(
            color: on ? t.inkPrimary : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            label,
            style: RunSoloType.label13.copyWith(
              color: on ? t.bgBase : t.inkSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
    return Container(
      key: const ValueKey('map-style-toggle'),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: t.bgBase.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: t.inkMuted.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [seg('Topo', topo, true), seg('Google', !topo, false)],
      ),
    );
  }
}

/// `© OpenStreetMap contributors | Protomaps | © Mapterhorn | Copernicus
/// DEM` as short whole names: `OSM`, `Protomaps`, `Mapterhorn`, `Copernicus`.
List<String> creditNames(String mapText) => [
  for (final raw in mapText.split('|'))
    if (raw.trim().isNotEmpty)
      raw
          .replaceAll('©', '')
          .replaceAll('contributors', '')
          .replaceAll(RegExp(r'\bDEM\b'), '')
          .replaceAll('OpenStreetMap', 'OSM')
          .trim(),
];

/// The most whole names that fit [maxWidth] on one line, as `© A · B · C`;
/// a trailing `…` shows when some were left out. Never cuts a word.
String creditLine(
  List<String> names,
  double maxWidth,
  TextStyle style,
  TextDirection dir,
) {
  double width(String t) {
    final p = TextPainter(
      text: TextSpan(text: t, style: style),
      textDirection: dir,
      maxLines: 1,
    )..layout();
    return p.width;
  }

  for (var n = names.length; n > 0; n--) {
    final line =
        '© ${names.take(n).join(' · ')}${n < names.length ? ' …' : ''}';
    if (width(line) <= maxWidth) return line;
  }
  return '©';
}

/// One compact line of credit on the map. Tapping opens the pack's full
/// credits. MapLibre's own button is hidden under it.
class CreditPlate extends StatelessWidget {
  const CreditPlate({
    super.key,
    required this.pack,
    this.tappable = true,
    this.compact = false,
  });
  final InstalledPack pack;
  final bool tappable;

  /// Home cards: smaller type and up to two lines, so every name shows.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final style = RunSoloType.micro11.copyWith(
      color: t.inkSecondary,
      fontSize: compact ? 9 : null,
    );
    final names = creditNames(pack.region.mapText);
    final plate = LayoutBuilder(
      builder: (context, c) {
        // Padding of 8 each side inside the plate.
        final line = compact
            ? '© ${names.join(' · ')}'
            : creditLine(
                names,
                (c.maxWidth.isFinite ? c.maxWidth : 400) - 16,
                style,
                Directionality.of(context),
              );
        return DecoratedBox(
          decoration: BoxDecoration(
            color: t.bgBase.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Text(
              line,
              key: const ValueKey('topo-attribution'),
              maxLines: compact ? 2 : 1,
              softWrap: compact,
              style: style,
            ),
          ),
        );
      },
    );
    if (!tappable) return plate;
    return Semantics(
      button: true,
      label: 'Map credits',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('topo-credits-button'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => showCredits(context, pack),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Align(widthFactor: 1, child: plate),
        ),
      ),
    );
  }
}

/// The pack's full credits, each with its licence.
Future<void> showCredits(BuildContext context, InstalledPack pack) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final t = Theme.of(context).extension<RunSoloTokens>()!;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Space.x16),
            child: Column(
              key: const ValueKey('topo-credits-sheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Map data',
                  style: RunSoloType.heading19.copyWith(color: t.inkPrimary),
                ),
                for (final c in pack.region.credits)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.x12),
                    child: Text(
                      c.license == null ? c.text : '${c.text}\n${c.license}',
                      style: RunSoloType.label13.copyWith(
                        color: t.inkSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

const String kDownloadMapPrompt = 'Download the offline map for this area';

class _DownloadPrompt extends StatelessWidget {
  const _DownloadPrompt();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      label: kDownloadMapPrompt,
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('map-download-prompt'),
        onTap: () => Navigator.of(context).pushNamed(Routes.offlineMaps),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: Space.x12),
          decoration: BoxDecoration(
            color: t.bgBase.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(Radii.card),
          ),
          child: Row(
            children: [
              Icon(Icons.download_outlined, size: 20, color: t.inkPrimary),
              const SizedBox(width: Space.x8),
              Expanded(
                child: Text(
                  kDownloadMapPrompt,
                  style: RunSoloType.label13.copyWith(color: t.inkPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
