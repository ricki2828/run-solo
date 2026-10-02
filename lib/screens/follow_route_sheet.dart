/// Follow a route: choose one on Start (Free, Trail and Goal runs). A sheet
/// with the routes kept on the phone, "Import a GPX or TCX file" and "Run a
/// past route again". Imported files are read on the phone and only the
/// simplified route is kept; nothing is sent anywhere.
library;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart' show Units;
import '../platform/transfer_gateway.dart' show RouteFileTooBig;
import '../state/history_store.dart';
import '../state/route_library.dart';
import '../theme/theme.dart';

/// Said once under the route on Start and in the sheet: the turn cues are the
/// route's shape, not map data.
const String kTurnHintsLine =
    'Turn hints come from the route shape, not trail data.';

/// "6.20 km · 180 m climb · from a file".
String routeSubtitle(engine.SavedRoute r, Units units) {
  final parts = <String>[
    Fmt.distance(r.distanceM, units),
    if (r.climbM != null) '${Fmt.elevation(r.climbM, units)} climb',
    switch (r.source) {
      engine.RouteSource.run => 'from a past run',
      engine.RouteSource.gpx => 'GPX file',
      engine.RouteSource.tcx => 'TCX file',
    },
  ];
  return parts.join(' · ');
}

/// Resolves the chosen route, or null when the sheet was closed.
Future<engine.SavedRoute?> showFollowRouteSheet(
  BuildContext context, {
  String? selectedId,
}) {
  final t = Theme.of(context).extension<RunSoloTokens>()!;
  return showModalBottomSheet<engine.SavedRoute>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: t.bgBase,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    ),
    builder: (_) => FollowRouteSheet(selectedId: selectedId),
  );
}

class FollowRouteSheet extends StatefulWidget {
  const FollowRouteSheet({super.key, this.selectedId});
  final String? selectedId;

  @override
  State<FollowRouteSheet> createState() => _FollowRouteSheetState();
}

class _FollowRouteSheetState extends State<FollowRouteSheet> {
  bool _busy = false;
  bool _pastRuns = false;
  String? _error;
  List<RunSummary>? _runs;

  Future<void> _import() async {
    final services = AppServices.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final picked = await services.transfer.pickRouteFile();
      if (picked == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final route = await services.routes.importText(
        picked.text,
        fallbackName: _nameOf(picked.name),
      );
      if (mounted) Navigator.of(context).pop(route);
    } on engine.ImportFormatException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _importMessage(e);
        });
      }
    } on RouteFileTooBig catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    } on RouteLibraryFull catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not read that file. Pick a GPX or TCX route.';
        });
      }
    }
  }

  /// "Hill loop.gpx" -> "Hill loop".
  static String _nameOf(String file) {
    final dot = file.lastIndexOf('.');
    final base = dot > 0 ? file.substring(0, dot) : file;
    return base.trim().isEmpty ? 'Imported route' : base.trim();
  }

  static String _importMessage(engine.ImportFormatException e) {
    final m = e.message;
    if (m.contains('shorter')) {
      return 'That route is under 200 m. Pick a longer one.';
    }
    if (m.contains('longer')) {
      return 'That route is over 300 km. Pick a shorter one.';
    }
    return 'That is not a route Run Supreme can follow. Pick a GPX or TCX '
        'file with a route or a track in it.';
  }

  Future<void> _showPastRuns() async {
    final services = AppServices.of(context);
    setState(() {
      _pastRuns = true;
      _error = null;
    });
    final all = await services.history.list();
    if (!mounted) return;
    setState(() {
      // Outdoor runs with a fix and a route worth following, newest first.
      _runs = [
        for (final r in all)
          if (!r.missing && r.startPoint != null && r.distanceM >= 200) r,
      ].take(30).toList();
    });
  }

  Future<void> _useRun(RunSummary r) async {
    final services = AppServices.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final detail = await services.history.load(r.id);
      if (detail == null) throw StateError('run gone');
      final name =
          r.customTitle ??
          (r.place != null ? '${r.place} run' : runIdentityTitle(r));
      final route = await services.routes.addFromRun(detail.run, name: name);
      if (mounted) Navigator.of(context).pop(route);
    } on RouteLibraryFull catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'That run has no route to follow.';
        });
      }
    }
  }

  Future<void> _delete(engine.SavedRoute r) async {
    final services = AppServices.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${r.name}"?'),
        content: const Text('The route leaves this phone. Your runs stay.'),
        actions: [
          TextButton(
            key: const ValueKey('route-delete-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('KEEP'),
          ),
          TextButton(
            key: const ValueKey('route-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
    if (ok == true) await services.routes.remove(r.id);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final units = services.settings.settings.units;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.screenGutter,
          Space.x4,
          Space.screenGutter,
          Space.x24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _pastRuns ? 'RUN A PAST ROUTE' : 'FOLLOW A ROUTE',
              style: RunSoloType.title28.copyWith(color: t.inkPrimary),
            ),
            const SizedBox(height: Space.x8),
            Text(
              'Route files stay on your phone. Run Supreme shows how far is '
              'left and tells you when you leave the route.',
              key: const ValueKey('follow-privacy'),
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x16),
            if (_pastRuns)
              ..._pastRunsBody(t, units)
            else
              ..._libraryBody(t, units, services),
            if (_error != null) ...[
              const SizedBox(height: Space.x12),
              Text(
                _error!,
                key: const ValueKey('follow-error'),
                style: RunSoloType.body15.copyWith(color: t.semWarn),
              ),
            ],
            const SizedBox(height: Space.x16),
            Text(
              kTurnHintsLine,
              key: const ValueKey('follow-turn-hints'),
              style: RunSoloType.label13.copyWith(color: t.inkSecondary),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _libraryBody(
    RunSoloTokens t,
    Units units,
    AppServices services,
  ) {
    return [
      _SheetButton(
        key: const ValueKey('follow-import'),
        label: 'Import a GPX or TCX file',
        onTap: _busy ? null : _import,
      ),
      const SizedBox(height: Space.x8),
      _SheetButton(
        key: const ValueKey('follow-past-run'),
        label: 'Run a past route again',
        onTap: _busy ? null : _showPastRuns,
      ),
      const SizedBox(height: Space.x16),
      ListenableBuilder(
        listenable: services.routes,
        builder: (context, _) {
          final routes = services.routes.routes;
          if (routes.isEmpty) {
            return Text(
              'No saved routes yet.',
              key: const ValueKey('follow-empty'),
              style: RunSoloType.body15.copyWith(color: t.inkMuted),
            );
          }
          return Column(
            key: const ValueKey('follow-list'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'SAVED ROUTES',
                style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
              ),
              for (final r in routes)
                _RouteTile(
                  route: r,
                  subtitle: routeSubtitle(r, units),
                  selected: r.id == widget.selectedId,
                  onTap: () => Navigator.of(context).pop(r),
                  onDelete: () => _delete(r),
                ),
            ],
          );
        },
      ),
    ];
  }

  List<Widget> _pastRunsBody(RunSoloTokens t, Units units) {
    final runs = _runs;
    return [
      if (runs == null)
        Text(
          'Looking through your runs…',
          style: RunSoloType.body15.copyWith(color: t.inkMuted),
        )
      else if (runs.isEmpty)
        Text(
          'No outdoor runs with a route yet.',
          key: const ValueKey('follow-no-runs'),
          style: RunSoloType.body15.copyWith(color: t.inkMuted),
        )
      else
        for (final r in runs)
          InkWell(
            key: ValueKey('past-run-${r.id}'),
            onTap: _busy ? null : () => _useRun(r),
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(vertical: Space.x8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: t.lineHair)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    runIdentityTitle(r),
                    style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                  ),
                  Text(
                    '${runWhereWhen(r)} · ${Fmt.distance(r.distanceM, units)}',
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                ],
              ),
            ),
          ),
      const SizedBox(height: Space.x12),
      _SheetButton(
        key: const ValueKey('follow-back'),
        label: 'Back to routes',
        onTap: _busy ? null : () => setState(() => _pastRuns = false),
      ),
    ];
  }
}

class _RouteTile extends StatelessWidget {
  const _RouteTile({
    required this.route,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });
  final engine.SavedRoute route;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.lineHair)),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              key: ValueKey('route-${route.id}'),
              onTap: onTap,
              child: Container(
                constraints: const BoxConstraints(minHeight: 56),
                padding: const EdgeInsets.symmetric(vertical: Space.x8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected ? '${route.name} · chosen' : route.name,
                      style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                    ),
                    Text(
                      subtitle,
                      style: RunSoloType.label13.copyWith(
                        color: t.inkSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            key: ValueKey('route-delete-${route.id}'),
            tooltip: 'Delete route',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline, color: t.inkSecondary),
          ),
        ],
      ),
    );
  }
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        foregroundColor: t.inkPrimary,
        side: BorderSide(color: t.lineHair),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.button),
        ),
      ),
      child: Text(label, style: RunSoloType.body15),
    );
  }
}

/// Start's row under the run type: "Follow a route ›", or the chosen route
/// with Change and a clear button.
class FollowRouteRow extends StatelessWidget {
  const FollowRouteRow({
    super.key,
    required this.route,
    required this.units,
    required this.onChoose,
    required this.onClear,
  });
  final engine.SavedRoute? route;
  final Units units;
  final VoidCallback onChoose;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final r = route;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: const ValueKey('follow-route-row'),
          onTap: onChoose,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        r == null ? 'Follow a route' : 'Following: ${r.name}',
                        style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                      ),
                      if (r != null)
                        Text(
                          routeSubtitle(r, units),
                          key: const ValueKey('follow-route-sub'),
                          style: RunSoloType.label13.copyWith(
                            color: t.inkSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
                Text(
                  r == null ? 'Choose ›' : 'Change ›',
                  style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                ),
                if (r != null)
                  IconButton(
                    key: const ValueKey('follow-route-clear'),
                    tooltip: 'Stop following this route',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: onClear,
                    icon: Icon(Icons.close, color: t.inkSecondary),
                  ),
              ],
            ),
          ),
        ),
        if (r != null)
          Text(
            kTurnHintsLine,
            key: const ValueKey('follow-route-hints'),
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
      ],
    );
  }
}
