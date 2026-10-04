import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/block_plan.dart';
import '../state/home_progress.dart';
import '../theme/theme.dart';

/// The 4-week block: build one, see every session with its reason, swap a
/// session or end the plan. Never blocks a run; Home's Start is what runs it.
class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key, this.now});
  final DateTime Function()? now;

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  Future<PlanContext>? _ctx;
  bool _building = false;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ctx ??= _load();
  }

  Future<PlanContext> _load() async {
    final services = AppServices.of(context);
    final runs = await services.history.list();
    final live = services.live;
    var scores = const <engine.IdentityLane, engine.IdentityScore>{};
    if (live != null) {
      try {
        await live.prepare();
        scores = live.identityScores();
      } catch (_) {}
    }
    return PlanContext(runs: runs, scores: scores, now: _now);
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('PLAN')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([services.plans, services.settings]),
          builder: (context, _) => FutureBuilder<PlanContext>(
            future: _ctx,
            builder: (context, snap) {
              final ctx = snap.data;
              if (ctx == null) {
                return const Center(child: CircularProgressIndicator());
              }
              final plan = services.plans.plan;
              final view = ctx.view(plan);
              if (plan == null || view == null || _building) {
                return _CreateForm(
                  ctx: ctx,
                  onBuilt: () => setState(() => _building = false),
                );
              }
              return _PlanBody(
                view: view,
                ctx: ctx,
                onBuildNext: () => setState(() => _building = true),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CreateForm extends StatefulWidget {
  const _CreateForm({required this.ctx, required this.onBuilt});
  final PlanContext ctx;
  final VoidCallback onBuilt;

  @override
  State<_CreateForm> createState() => _CreateFormState();
}

class _CreateFormState extends State<_CreateForm> {
  engine.IdentityLane? _lane;
  int _perWeek = 3;

  static const _blurb = {
    engine.IdentityLane.aerobic: 'Your engine. Built on Norwegian 4x4s.',
    engine.IdentityLane.speed: 'Short, fast reps.',
    engine.IdentityLane.mid: 'Strength at 5K to 10K pace.',
    engine.IdentityLane.long: 'Long runs, building to 15K+.',
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final settings = services.settings.settings;
    final age = settings.birthYear == null
        ? null
        : widget.ctx.now.year - settings.birthYear!;
    final lane =
        _lane ??
        Recommendation.of(
          widget.ctx.scores,
          widget.ctx.runs,
          now: widget.ctx.now,
          sex: settings.profileSex,
          age: age,
          presetEdits: settings.allPresetEdits,
        ).lane;
    final name = lane.name.toUpperCase();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Space.screenGutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'BUILD YOUR 4 WEEKS',
            style: RunSoloType.display44.copyWith(color: t.inkPrimary),
          ),
          Text(
            'A plan around your scores. It follows what you actually run, and '
            'a missed session is skipped, never piled on.',
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x24),
          Text(
            'WHAT TO IMPROVE',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x8),
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x8,
            children: [
              for (final l in engine.IdentityLane.values)
                ChoiceChip(
                  key: ValueKey('plan-lane-${l.name}'),
                  label: Text(l.name.toUpperCase()),
                  showCheckmark: false,
                  selected: l == lane,
                  onSelected: (_) => setState(() => _lane = l),
                ),
            ],
          ),
          const SizedBox(height: Space.x8),
          Text(
            _blurb[lane]!,
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x24),
          Text(
            'RUNS A WEEK',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
          Row(
            children: [
              IconButton(
                key: const ValueKey('plan-fewer'),
                tooltip: 'Fewer runs',
                onPressed: _perWeek > engine.BlockPlanner.minPerWeek
                    ? () => setState(() => _perWeek--)
                    : null,
                icon: const Icon(Icons.remove),
              ),
              Text(
                '$_perWeek',
                key: const ValueKey('plan-per-week'),
                style: RunSoloType.display44.copyWith(color: t.inkPrimary),
              ),
              IconButton(
                key: const ValueKey('plan-more'),
                tooltip: 'More runs',
                onPressed: _perWeek < engine.BlockPlanner.maxPerWeek
                    ? () => setState(() => _perWeek++)
                    : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          Text(
            'Week 3 or 4 is lighter. Week 4 ends with a test that re-measures '
            '$name.',
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x24),
          FilledButton(
            key: const ValueKey('plan-build'),
            onPressed: () async {
              await services.plans.create(
                engine.BlockPlanner.build(
                  lane: lane,
                  perWeek: _perWeek,
                  start: widget.ctx.now,
                  baseline: widget.ctx.baseline,
                ),
              );
              widget.onBuilt();
            },
            child: const Text('Build my 4 weeks'),
          ),
        ],
      ),
    );
  }
}

class _PlanBody extends StatelessWidget {
  const _PlanBody({
    required this.view,
    required this.ctx,
    required this.onBuildNext,
  });
  final engine.BlockView view;
  final PlanContext ctx;
  final VoidCallback onBuildNext;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final units = services.settings.settings.units;
    final plan = view.plan;
    final lane = plan.lane.name.toUpperCase();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Space.screenGutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$lane BLOCK',
            style: RunSoloType.display44.copyWith(color: t.inkPrimary),
          ),
          Text(
            view.finished
                ? 'Done: ${view.doneCount} of ${view.totalCount} sessions.'
                : 'Week ${view.currentWeek} of 4 · ${view.doneCount} of '
                      '${view.totalCount} done · ${plan.perWeek} a week',
            key: const ValueKey('plan-summary'),
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
          if (view.shifts > 0) ...[
            const SizedBox(height: Space.x4),
            Text(
              PlanText.shiftLine(view.shifts),
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
          ],
          if (view.finished) ...[
            const SizedBox(height: Space.x12),
            FilledButton(
              key: const ValueKey('plan-build-next'),
              onPressed: onBuildNext,
              child: const Text('Build the next 4 weeks'),
            ),
          ],
          for (var w = 1; w <= engine.BlockPlanner.weeks; w++) ...[
            const SizedBox(height: Space.x24),
            Row(
              children: [
                Text(
                  'WEEK $w',
                  style: RunSoloType.heading19.copyWith(
                    color: view.currentWeek == w
                        ? t.inkPrimary
                        : t.inkSecondary,
                  ),
                ),
                if (PlanText.weekTag(plan, w) != null) ...[
                  const SizedBox(width: Space.x8),
                  Text(
                    PlanText.weekTag(plan, w)!,
                    style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                  ),
                ],
              ],
            ),
            for (final s in view.weeks[w - 1])
              _SessionRow(state: s, ctx: ctx, units: units),
          ],
          const SizedBox(height: Space.x24),
          Text(
            'Paces are True Pace estimates from your recent runs: flat ground, '
            'cool day.',
            style: RunSoloType.label13.copyWith(color: t.inkMuted),
          ),
          const SizedBox(height: Space.x12),
          TextButton(
            key: const ValueKey('plan-end'),
            onPressed: () => _confirmEnd(context, services),
            child: const Text('End plan'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmEnd(BuildContext context, AppServices services) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('End this plan?'),
        content: const Text('Your runs stay. Only the plan goes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep plan'),
          ),
          TextButton(
            key: const ValueKey('plan-end-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('End plan'),
          ),
        ],
      ),
    );
    if (ok == true) await services.plans.end();
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.state,
    required this.ctx,
    required this.units,
  });
  final engine.BlockSessionState state;
  final PlanContext ctx;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final s = state.session;
    final st = state.status;
    final open =
        st == engine.BlockStatus.planned || st == engine.BlockStatus.next;
    final (icon, tag, tagColor) = switch (st) {
      engine.BlockStatus.done => (Icons.check_circle, 'DONE', t.inkPrimary),
      engine.BlockStatus.next => (Icons.play_circle, 'NEXT', t.accentArc),
      engine.BlockStatus.missed => (
        Icons.remove_circle_outline,
        'MISSED',
        t.semWarn,
      ),
      engine.BlockStatus.planned => (Icons.circle_outlined, '', t.inkMuted),
    };
    final target = open ? PlanText.targetLine(s, ctx.vdot, units) : null;
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: tagColor),
          const SizedBox(width: Space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${s.name} · ${s.size}',
                  style: RunSoloType.body15.copyWith(
                    color: st == engine.BlockStatus.missed
                        ? t.inkSecondary
                        : t.inkPrimary,
                  ),
                ),
                Text(
                  '${engine.BlockResolver.dayName(state.date)} '
                  '${Fmt.dayMonth(state.date)}',
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
                Text(
                  state.note ?? s.reason,
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
                if (target != null)
                  Text(
                    target,
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
              ],
            ),
          ),
          if (tag.isNotEmpty) ...[
            const SizedBox(width: Space.x8),
            Text(tag, style: RunSoloType.micro11.copyWith(color: tagColor)),
          ],
          if (open && !s.isTest)
            Icon(Icons.swap_horiz, size: 20, color: t.inkMuted),
        ],
      ),
    );
    if (!open || s.isTest) return body;
    return InkWell(
      key: ValueKey('plan-row-${s.id}'),
      onTap: () => _swap(context),
      child: body,
    );
  }

  Future<void> _swap(BuildContext context) async {
    final services = AppServices.of(context);
    final alts = engine.BlockPlanner.alternatives(state.session);
    if (alts.isEmpty) return;
    final picked = await showModalBottomSheet<engine.BlockSession>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(Space.cardPadding),
              child: Text(
                'SWAP ${state.session.name.toUpperCase()}',
                style: RunSoloType.heading19,
              ),
            ),
            for (final a in alts)
              ListTile(
                key: ValueKey(
                  'plan-alt-${a.presetId ?? a.kind.name}-${a.minutes ?? a.reps}',
                ),
                title: Text('${a.name} · ${a.size}'),
                onTap: () => Navigator.of(ctx).pop(a),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await services.plans.swap(picked);
  }
}
