import 'package:flutter/material.dart';

import '../app/format.dart';
import '../app/services.dart';
import '../map/map_surface.dart';
import '../map/route_builder.dart';
import '../platform/gateway.dart' show Units;
import '../theme/theme.dart';

/// True when [route] has at least two distinct points (about 1 m apart), so
/// there is a line to draw; a stationary or one-fix track has none.
bool routeHasShape(RouteGeometry route) {
  final pts = route.points;
  if (pts.length < 2) return false;
  final first = pts.first;
  for (final p in pts.skip(1)) {
    if ((p.lat - first.lat).abs() > 1e-5 || (p.lon - first.lon).abs() > 1e-5) {
      return true;
    }
  }
  return false;
}

/// The map that leads a Home run card: full width, the route in the run
/// colour, and the run's climb over the map's top left. The map credit
/// stays bottom right, where the tile licence needs it. [maps] defaults to
/// the app's factory; the topo-surface harness passes its own.
class ActivityMapHeader extends StatelessWidget {
  const ActivityMapHeader({
    super.key,
    required this.route,
    required this.runId,
    required this.color,
    required this.terrain,
    required this.climbM,
    required this.units,
    this.maps,
  });

  final RouteGeometry route;
  final String runId;
  final Color color;
  final bool terrain;
  final double? climbM;
  final Units units;
  final MapSurfaceFactory? maps;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final climb = climbM;
    if (!routeHasShape(route)) return const SizedBox.shrink();
    return SizedBox(
      height: 168,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          (maps ?? AppServices.of(context).maps).buildCard(
            context,
            route,
            runId: runId,
            routeColor: color,
            terrain: terrain,
          ),
          if (climb != null && climb >= 1)
            Positioned(
              left: Space.x12,
              top: Space.x12,
              child: IgnorePointer(
                child: Container(
                  key: const ValueKey('activity-map-climb'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.x8,
                    vertical: Space.x4,
                  ),
                  decoration: BoxDecoration(
                    color: t.inkPrimary.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(Radii.button),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.terrain, size: 16, color: t.bgBase),
                      const SizedBox(width: Space.x4),
                      Text(
                        '${Fmt.elevation(climb, units)} CLIMB',
                        style: RunSoloType.heading19.copyWith(color: t.bgBase),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
