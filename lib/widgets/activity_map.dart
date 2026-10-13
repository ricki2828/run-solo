import 'package:flutter/material.dart';

import '../app/format.dart';
import '../app/services.dart';
import '../map/map_surface.dart';
import '../map/route_builder.dart';
import '../platform/gateway.dart' show Units;
import '../theme/theme.dart';

/// The map that leads a Home run card: full width, the route in the run
/// colour, and the run's climb over the map's lower left. The map credit
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
              left: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  key: const ValueKey('activity-map-climb'),
                  padding: const EdgeInsets.fromLTRB(
                    Space.x12,
                    Space.x16,
                    Space.x16,
                    Space.x8,
                  ),
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.bottomLeft,
                      radius: 1.3,
                      colors: [
                        t.inkPrimary.withValues(alpha: 0.6),
                        t.inkPrimary.withValues(alpha: 0),
                      ],
                    ),
                  ),
                  child: Text(
                    '▲ ${Fmt.elevation(climb, units)} CLIMB',
                    style: RunSoloType.heading19.copyWith(color: t.bgBase),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
