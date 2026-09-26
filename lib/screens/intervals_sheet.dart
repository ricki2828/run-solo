import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/services.dart';
import '../state/sessions.dart';
import '../theme/theme.dart';
import '../widgets/structure_glyph.dart';

/// What the Intervals sheet hands back: a session id to pick, or "build".
sealed class SheetResult {
  const SheetResult();
}

class PickSession extends SheetResult {
  const PickSession(this.id);
  final String id;
}

class BuildCustom extends SheetResult {
  const BuildCustom();
}

/// Purpose lines (design brief A8; max 9 words). The catalogue's own
/// `purpose` is the fallback for an id not listed here.
const Map<String, String> kPurpose = {
  'norwegian-4x4': 'The VO2 max classic. Four hard reps.',
  '30-30s': '30 s fast, 30 s jog. Short and sharp.',
  '1-min-reps': 'The classic starter session.',
  'pyramid': '1-2-3-4-3-2-1 min, up and down.',
  'tempo': 'Comfortably hard, in long blocks.',
  '400s': 'Track speed. Even splits win.',
  'yasso-800s': 'Marathon staple. Jog the same time back.',
  '1km-repeats': '5k to 10k pace work.',
  'fartlek': 'Surges by feel. You press LAP.',
};

/// The Intervals sheet (A8): Last used, Popular (the eight presets, plan
/// §3.1 order), My sessions, Fartlek, + Build your own. Full height.
Future<SheetResult?> showIntervalsSheet(
  BuildContext context, {
  required String currentId,
}) {
  final t = Theme.of(context).extension<RunSoloTokens>()!;
  return showModalBottomSheet<SheetResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: t.bgBase,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    ),
    builder: (_) => IntervalsSheet(currentId: currentId),
  );
}

class IntervalsSheet extends StatefulWidget {
  const IntervalsSheet({super.key, required this.currentId});
  final String currentId;

  @override
  State<IntervalsSheet> createState() => _IntervalsSheetState();
}

class _IntervalsSheetState extends State<IntervalsSheet> {
  /// Comparison keys that already have a run (the VERDICT tag, A8).
  Set<String> _keys = const {};
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    AppServices.of(context).history
        .list()
        .then((runs) {
          if (!mounted) return;
          setState(() {
            _keys = {
              for (final r in runs)
                if (r.comparisonKey ?? r.spec?.comparisonKey
                    case final String k)
                  k,
            };
          });
        })
        .catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final settings = services.settings.settings;
    return ListenableBuilder(
      listenable: services.sessions,
      builder: (context, _) {
        final customs = services.sessions.sessions;
        final edits = settings.allPresetEdits;
        engine.SessionSpec? resolve(String id) =>
            SessionChoice.resolve(id, edits: edits, customs: customs);
        final current = resolve(widget.currentId) != null
            ? widget.currentId
            : engine.SessionSpec.norwegian4x4Id;

        Widget card(String id, {bool selected = false}) {
          final spec = resolve(id);
          if (spec == null) return const SizedBox.shrink();
          final custom = services.sessions.byTemplateId(id);
          final key = spec.steps.isEmpty ? null : spec.comparisonKey;
          return SessionCard(
            key: ValueKey('sheet-$id'),
            spec: spec,
            purpose: custom != null
                ? null
                : kPurpose[id] ?? engine.SessionCatalogue.byId(id)?.purpose,
            selected: selected,
            verdict:
                key != null &&
                !SessionChoice.isFartlek(id) &&
                _keys.contains(key),
            onTap: () => Navigator.of(context).pop(PickSession(id)),
            onLongPress: custom == null
                ? null
                : () => _customMenu(context, custom),
          );
        }

        Widget eyebrow(String text) => Padding(
          padding: const EdgeInsets.only(top: Space.x24, bottom: Space.x8),
          child: Text(
            text,
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
        );

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 1,
          minChildSize: 0.5,
          builder: (context, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(
              Space.screenGutter,
              0,
              Space.screenGutter,
              Space.x32,
            ),
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Close',
                    constraints: const BoxConstraints(
                      minWidth: 56,
                      minHeight: 56,
                    ),
                    icon: Icon(Icons.arrow_back, color: t.inkPrimary),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: Space.x4),
                  Text(
                    'INTERVALS',
                    style: RunSoloType.title28.copyWith(color: t.inkPrimary),
                  ),
                ],
              ),
              eyebrow('LAST USED'),
              card(current, selected: true),
              eyebrow('POPULAR'),
              for (final p in engine.SessionCatalogue.presets)
                if (p.id != current)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.x8),
                    child: card(p.id),
                  ),
              if (customs.any((c) => c.templateId != current)) ...[
                eyebrow('MY SESSIONS'),
                for (final c in customs)
                  if (c.templateId != current)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.x8),
                      child: card(c.templateId),
                    ),
              ],
              eyebrow('BY FEEL'),
              if (current != engine.SessionSpec.fartlekId)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.x8),
                  child: card(engine.SessionSpec.fartlekId),
                ),
              _BuildYourOwn(
                full: services.sessions.full,
                onTap: () => Navigator.of(context).pop(const BuildCustom()),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Long-press on a saved session: rename, duplicate, delete (A8).
  Future<void> _customMenu(BuildContext context, CustomSession c) async {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final sessions = AppServices.of(context).sessions;
    HapticFeedback.selectionClick();
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: t.bgRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (key, label) in [
              ('rename', 'Rename'),
              ('duplicate', 'Duplicate'),
              ('delete', 'Delete'),
            ])
              ListTile(
                key: ValueKey('custom-$key'),
                minTileHeight: 56,
                title: Text(
                  label,
                  style: RunSoloType.body17.copyWith(
                    color: key == 'delete' ? t.semDanger : t.inkPrimary,
                  ),
                ),
                onTap: () => Navigator.pop(ctx, key),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'rename':
        final name = await _askName(context, c.name);
        if (name != null) await sessions.rename(c.id, name);
      case 'duplicate':
        if (sessions.full) {
          _snack(context, 'You have 20 sessions. Delete one first.');
        } else {
          await sessions.duplicate(c.id);
        }
      case 'delete':
        await sessions.delete(c.id);
    }
  }
}

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// A name prompt shared by the sheet (rename) and the builder.
Future<String?> _askName(BuildContext context, String initial) {
  final t = Theme.of(context).extension<RunSoloTokens>()!;
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: t.bgRaised,
      title: Text(
        'RENAME',
        style: RunSoloType.title28.copyWith(color: t.inkPrimary),
      ),
      content: TextField(
        key: const ValueKey('rename-field'),
        controller: ctl,
        autofocus: true,
        maxLength: 40,
        style: RunSoloType.body17.copyWith(color: t.inkPrimary),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('CANCEL'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
          child: const Text('SAVE'),
        ),
      ],
    ),
  );
}

/// One session (A8 card): name + estimate, purpose, structure line, glyph.
/// The whole card is the tap target, min 88 dp. Selected = 2 dp Bone border.
class SessionCard extends StatelessWidget {
  const SessionCard({
    super.key,
    required this.spec,
    required this.onTap,
    this.purpose,
    this.selected = false,
    this.verdict = false,
    this.onLongPress,
  });

  final engine.SessionSpec spec;
  final String? purpose;
  final bool selected;

  /// The comparison key already has a run: this session gets a verdict.
  final bool verdict;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final fartlek = spec.templateId == engine.SessionSpec.fartlekId;
    final structure = SessionText.structure(spec);
    return Semantics(
      button: true,
      selected: selected,
      label: '${spec.name}. ${purpose ?? ''} $structure',
      excludeSemantics: true,
      child: Material(
        color: t.bgRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.card),
          side: BorderSide(
            color: selected ? t.inkPrimary : Colors.transparent,
            width: 2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 88),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: Space.x12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Name then the tag, the estimate pinned right.
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                spec.name.toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: RunSoloType.title28.copyWith(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: t.inkPrimary,
                                ),
                              ),
                            ),
                            if (verdict) ...[
                              const SizedBox(width: Space.x8),
                              const VerdictTag(),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: Space.x8),
                      if (!fartlek)
                        Text(
                          '~${SessionText.estimateMinutes(spec)} min',
                          style: RunSoloType.label13.copyWith(
                            color: t.inkMuted,
                          ),
                        ),
                    ],
                  ),
                  if (purpose != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      purpose!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                    ),
                  ],
                  const SizedBox(height: 2),
                  Text(
                    structure,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RunSoloType.label13.copyWith(color: t.inkPrimary),
                  ),
                  if (!fartlek) ...[
                    const SizedBox(height: Space.x8),
                    StructureGlyph(spec: spec),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "VERDICT": this session already has runs to compare against (A8).
class VerdictTag extends StatelessWidget {
  const VerdictTag({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.chip),
        border: Border.all(color: t.inkMuted),
      ),
      child: Text(
        'VERDICT',
        style: RunSoloType.label13.copyWith(
          fontSize: 10,
          letterSpacing: 0.8,
          color: t.inkSecondary,
        ),
      ),
    );
  }
}

class _BuildYourOwn extends StatelessWidget {
  const _BuildYourOwn({required this.full, required this.onTap});
  final bool full;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      enabled: !full,
      label: full ? 'Build your own. 20 saved, delete one first' : null,
      child: InkWell(
        key: const ValueKey('sheet-build'),
        onTap: full ? null : onTap,
        borderRadius: BorderRadius.circular(Radii.card),
        child: CustomPaint(
          painter: _DashedBorder(color: t.inkMuted),
          child: Container(
            constraints: const BoxConstraints(minHeight: 72),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.centerLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '+ BUILD YOUR OWN',
                  style: RunSoloType.title28.copyWith(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: full ? t.inkMuted : t.inkPrimary,
                  ),
                ),
                Text(
                  full
                      ? '20 saved. Delete one to build another.'
                      : 'Your reps, time or distance, your recovery.',
                  style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  _DashedBorder({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.5),
          const Radius.circular(Radii.card),
        ),
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 9) {
        canvas.drawPath(m.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color;
}

/// Exposed for the builder's name field.
Future<String?> askSessionName(BuildContext context, String initial) =>
    _askName(context, initial);
