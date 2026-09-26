import 'package:flutter/material.dart';

import '../app/event_names.dart';
import '../app/format.dart';
import '../app/services.dart';
import '../state/courses.dart';
import '../state/history_store.dart';
import '../theme/theme.dart';
import '../widgets/delta_glyph.dart';
import 'run_detail_screen.dart';

/// "23:20" for whole seconds.
String _clock(double seconds) => Fmt.clock((seconds.round()) * 1000);

/// K1 on the verdict of an event run (A10.3 slot, above DETAILS): its course
/// (rename, move, board), the official time and where it ranks.
class EventPanel extends StatelessWidget {
  const EventPanel({
    super.key,
    required this.detail,
    required this.all,
    required this.onChanged,
  });
  final RunDetail detail;

  /// Every run, for the course labels and the rank.
  final List<RunSummary> all;

  /// After an edit: reload the verdict (the official time recomputes it).
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final courseId = detail.sidecar.parkrun?.courseId;
    final official = detail.sidecar.parkrun?.officialTimeSeconds;
    final labels = CourseLabels(all, services.courseNames);
    final board = courseId == null
        ? null
        : CourseBoard.fold(all, courseId, now: services.now());
    final rank = board?.rankOf(detail.run.id);
    return Column(
      key: const ValueKey('event-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Row(
          key: const ValueKey('event-course'),
          label: 'COURSE',
          value: courseId == null
              ? 'Tagged once GPS has a fix'
              : labels.labelOf(courseId),
          onTap: courseId == null
              ? null
              : () => showCourseSheet(
                  context,
                  runId: detail.run.id,
                  courseId: courseId,
                  labels: labels,
                ).then((changed) => changed ? onChanged() : null),
        ),
        _Row(
          key: const ValueKey('event-official'),
          label: 'OFFICIAL TIME',
          value: official == null
              ? 'Enter official time'
              : '${_clock(official.toDouble())} · Edit',
          onTap: () => showOfficialTimeSheet(
            context,
            detail: detail,
          ).then((changed) => changed ? onChanged() : null),
        ),
        if (board != null && rank != null && board.ranked.length > 1)
          _Row(
            key: const ValueKey('event-rank'),
            label: 'ON THIS COURSE',
            // Rank on the board as it is now; a later run can have moved
            // it, so the verdict's NEW BEST and "#2" never read as a clash.
            value:
                board.ranked.any((e) => e.run.start.isAfter(detail.run.start))
                ? '#$rank of ${board.ranked.length} today · See the board'
                : '#$rank of ${board.ranked.length} · See the board',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CourseBoardScreen(courseId: courseId!),
              ),
            ),
          )
        else if (courseId != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.x8),
            child: Text(
              'First ${kEventNames.parkrun} on this course. '
              'The board starts here.',
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({super.key, required this.label, required this.value, this.onTap});
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: onTap != null,
      label: '$label, $value',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              SizedBox(
                width: 120,
                child: Text(
                  label,
                  style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                ),
              ),
              Expanded(
                child: Text(
                  value,
                  style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                ),
              ),
              if (onTap != null)
                Icon(Icons.chevron_right, color: t.inkSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rename the course, move this run to another one, or open its board.
/// Returns true when something changed.
Future<bool> showCourseSheet(
  BuildContext context, {
  required String runId,
  required String courseId,
  required CourseLabels labels,
}) async {
  final services = AppServices.of(context);
  final name = TextEditingController(
    text: services.courseNames.nameOf(courseId) ?? '',
  );
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      final t = Theme.of(context).extension<RunSoloTokens>()!;
      final others = labels.courseIds.where((c) => c != courseId).toList();
      return Padding(
        padding: EdgeInsets.only(
          left: Space.screenGutter,
          right: Space.screenGutter,
          top: Space.x24,
          bottom: MediaQuery.of(context).viewInsets.bottom + Space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              labels.labelOf(courseId).toUpperCase(),
              style: RunSoloType.title28,
            ),
            const SizedBox(height: Space.x16),
            TextField(
              key: const ValueKey('course-name'),
              controller: name,
              maxLength: CourseNamesController.maxLength,
              decoration: InputDecoration(
                labelText: 'Course name',
                hintText: labels.labelOf(courseId),
              ),
            ),
            FilledButton(
              key: const ValueKey('course-save'),
              onPressed: () async {
                await services.courseNames.rename(courseId, name.text);
                if (context.mounted) Navigator.of(context).pop(true);
              },
              child: const Text('SAVE NAME'),
            ),
            if (others.isNotEmpty) ...[
              const SizedBox(height: Space.x24),
              Text(
                'WRONG COURSE? MOVE THIS RUN TO',
                style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
              ),
              for (final c in others)
                ListTile(
                  key: ValueKey('course-move-$c'),
                  minTileHeight: 56,
                  contentPadding: EdgeInsets.zero,
                  title: Text(labels.labelOf(c)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await services.history.setCourse(runId, c);
                    if (context.mounted) Navigator.of(context).pop(true);
                  },
                ),
            ],
          ],
        ),
      );
    },
  );
  return changed ?? false;
}

/// Official time entry (K1): mm:ss, checked against the GPS finish the same
/// way the engine checks it, and said plainly when it is off. Returns true
/// when the time was saved or cleared.
Future<bool> showOfficialTimeSheet(
  BuildContext context, {
  required RunDetail detail,
}) async {
  final services = AppServices.of(context);
  final have = detail.sidecar.parkrun?.officialTimeSeconds;
  final gps = gpsFinishSeconds(detail.analysis.intervals);
  final text = TextEditingController(
    text: have == null ? '' : _clock(have.toDouble()),
  );
  String? error;
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) {
        final t = Theme.of(context).extension<RunSoloTokens>()!;
        Future<void> save() async {
          final s = parseFinishTime(text.text);
          final problem = officialTimeProblem(s, gps);
          if (problem != null) {
            setSheet(() => error = problem);
            return;
          }
          await services.history.setOfficialTime(detail.run.id, s);
          if (context.mounted) Navigator.of(context).pop(true);
        }

        return Padding(
          padding: EdgeInsets.only(
            left: Space.screenGutter,
            right: Space.screenGutter,
            top: Space.x24,
            bottom: MediaQuery.of(context).viewInsets.bottom + Space.x24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('OFFICIAL TIME', style: RunSoloType.title28),
              const SizedBox(height: Space.x8),
              Text(
                gps == null
                    ? 'Your time from the results page.'
                    : 'Your time from the results page. GPS had '
                          '${_clock(gps)}.',
                style: RunSoloType.body15.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x16),
              TextField(
                key: const ValueKey('official-time'),
                controller: text,
                autofocus: true,
                keyboardType: TextInputType.datetime,
                style: RunSoloType.display44,
                decoration: InputDecoration(
                  hintText: '23:20',
                  errorText: error,
                  errorMaxLines: 3,
                ),
                onSubmitted: (_) => save(),
              ),
              const SizedBox(height: Space.x16),
              FilledButton(
                key: const ValueKey('official-save'),
                onPressed: save,
                child: const Text('SAVE'),
              ),
              if (have != null)
                TextButton(
                  key: const ValueKey('official-clear'),
                  onPressed: () async {
                    await services.history.setOfficialTime(detail.run.id, null);
                    if (context.mounted) Navigator.of(context).pop(true);
                  },
                  child: const Text('Use the GPS time instead'),
                ),
            ],
          ),
        );
      },
    ),
  );
  return changed ?? false;
}

/// One course's board (K1; A10.2 detail layout): best, trend, last 5 and
/// every run ranked with its heat-adjusted twin.
class CourseBoardScreen extends StatefulWidget {
  const CourseBoardScreen({super.key, required this.courseId});
  final String courseId;

  @override
  State<CourseBoardScreen> createState() => _CourseBoardScreenState();
}

class _CourseBoardScreenState extends State<CourseBoardScreen> {
  Future<List<RunSummary>>? _load;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load ??= AppServices.of(context).history.list();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    return FutureBuilder<List<RunSummary>>(
      future: _load,
      builder: (context, snap) {
        final runs = snap.data;
        if (runs == null) {
          return Scaffold(appBar: AppBar(title: const Text('BOARD')));
        }
        final board = CourseBoard.fold(
          runs,
          widget.courseId,
          now: services.now(),
        );
        final label = CourseLabels(
          runs,
          services.courseNames,
        ).labelOf(widget.courseId);
        final best = board.best;
        final n = board.ranked.length;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              '${label.toUpperCase()} · $n ${n == 1 ? 'RUN' : 'RUNS'}',
            ),
          ),
          body: ListView(
            key: const ValueKey('course-board'),
            padding: const EdgeInsets.all(Space.screenGutter),
            children: [
              if (best == null)
                Text(
                  'No finished ${kEventNames.parkrun} on this course yet.',
                  style: RunSoloType.body17.copyWith(color: t.inkSecondary),
                )
              else ...[
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _clock(best.finishSeconds),
                    style: RunSoloType.display96.copyWith(color: t.inkPrimary),
                  ),
                ),
                Row(
                  children: [
                    Text(
                      'Your best · ${Fmt.dayDate(best.run.start)}',
                      style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                    ),
                    if (best.official) ...[
                      const SizedBox(width: Space.x8),
                      const _OfficialTag(),
                    ],
                  ],
                ),
                const SizedBox(height: Space.x12),
                _Trend(secPerMonth: board.trendSecPerMonth),
                const SizedBox(height: Space.x24),
                _Eyebrow('LAST 5'),
                for (final e in board.last5)
                  _BoardRow(
                    rank: board.rankOf(e.run.id)!,
                    entry: e,
                    showHeat: false,
                  ),
                const SizedBox(height: Space.x24),
                _Eyebrow('ALL'),
                const _BoardHeader(),
                for (final (i, e) in board.ranked.indexed)
                  _BoardRow(rank: i + 1, entry: e, showHeat: true),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Trend as data (A10.2): glyph and words in Bone, never Arc. The glyph
/// is drawn (DeltaGlyph), since the UI font has no ▲.
class _Trend extends StatelessWidget {
  const _Trend({required this.secPerMonth});
  final double? secPerMonth;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final style = RunSoloType.label13.copyWith(
      color: t.inkPrimary,
      fontSize: 15,
    );
    final v = secPerMonth;
    final s = v?.abs().round();
    final text = switch (v) {
      null => 'Not enough runs yet for a trend',
      _ when s == 0 => 'Holding steady',
      _ when v < 0 => '$s s a month quicker',
      _ => '$s s a month slower',
    };
    return Row(
      key: const ValueKey('board-trend'),
      children: [
        if (v != null && s != 0) ...[
          DeltaGlyph(
            direction: v < 0 ? DeltaDirection.up : DeltaDirection.down,
            color: t.inkPrimary,
            size: 10,
          ),
          const SizedBox(width: 6),
        ],
        Text(text, style: style),
      ],
    );
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x8),
      child: Text(
        text,
        style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
      ),
    );
  }
}

class _OfficialTag extends StatelessWidget {
  const _OfficialTag();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: t.lineHair),
        borderRadius: BorderRadius.circular(Radii.chip),
      ),
      child: Text(
        'official',
        style: RunSoloType.label13.copyWith(
          fontSize: 10,
          color: t.inkSecondary,
        ),
      ),
    );
  }
}

class _BoardHeader extends StatelessWidget {
  const _BoardHeader();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final s = RunSoloType.micro11.copyWith(color: t.inkSecondary);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x4),
      child: Row(
        children: [
          SizedBox(width: 40, child: Text('#', style: s)),
          Expanded(child: Text('TIME', style: s)),
          Expanded(child: Text('DATE', style: s)),
          Expanded(
            child: Text('HEAT-ADJ', style: s, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class _BoardRow extends StatelessWidget {
  const _BoardRow({
    required this.rank,
    required this.entry,
    required this.showHeat,
  });
  final int rank;
  final CourseBoardEntry entry;
  final bool showHeat;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final num = RunSoloType.label13.copyWith(
      fontSize: 17,
      color: t.inkPrimary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final heat = entry.heatAdjustedSeconds;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => RunDetailScreen(runId: entry.run.id)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: Row(
                children: [
                  Text('$rank', style: num),
                  if (rank == 1) ...[
                    const SizedBox(width: 4),
                    // A10.2: the #1 row's 6 dp Arc dot; the only Arc here.
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: t.accentArc,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Text(_clock(entry.finishSeconds), style: num),
                  if (entry.official) ...[
                    const SizedBox(width: 6),
                    const _OfficialTag(),
                  ],
                ],
              ),
            ),
            Expanded(
              child: Text(
                Fmt.dayDate(entry.run.start),
                style: RunSoloType.body15.copyWith(color: t.inkSecondary),
              ),
            ),
            Expanded(
              child: Text(
                showHeat && heat != null ? _clock(heat) : '',
                textAlign: TextAlign.right,
                style: num.copyWith(color: t.inkSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
