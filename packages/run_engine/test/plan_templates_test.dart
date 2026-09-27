import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// The bundled plan templates in assets/plans/ are the product (v1 plan
/// §7): they must parse against the engine codec and keep the shapes the
/// plan promises (the Norwegian is 16 4x4 sessions, and so on).
void main() {
  Directory plansDir() {
    var dir = Directory.current;
    for (var i = 0; i < 8; i++) {
      final candidate = Directory('${dir.path}/assets/plans');
      if (candidate.existsSync()) return candidate;
      dir = dir.parent;
    }
    fail('assets/plans not found above ${Directory.current.path}');
  }

  Map<String, PlanTemplate> loadAll() {
    final out = <String, PlanTemplate>{};
    for (final f in plansDir().listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      final t = PlanTemplate.fromJson(
        (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>(),
      );
      out[t.id] = t;
    }
    return out;
  }

  int sessionsOf(Map<String, PlanTemplate> all, String id, RunMode mode) =>
      all[id]!.weeks.expand((w) => w).where((s) => s.mode == mode).length;

  test('the three v1 templates ship and parse', () {
    final all = loadAll();
    expect(
      all.keys,
      unorderedEquals(['norwegian-4x4-8wk', '5k-8wk', 'base-4wk']),
    );
    expect(all['norwegian-4x4-8wk']!.name, '8 weeks of 4x4');
    expect(all['5k-8wk']!.name, '5k in 8 weeks');
    expect(all['base-4wk']!.name, '4-week base');
  });

  test('week counts match the ids', () {
    final all = loadAll();
    expect(all['norwegian-4x4-8wk']!.weekCount, 8);
    expect(all['5k-8wk']!.weekCount, 8);
    expect(all['base-4wk']!.weekCount, 4);
  });

  test('session mix matches v1 plan §7', () {
    final all = loadAll();
    // Norwegian: 16 4x4 ("5 of 16" in the brief) plus easy runs.
    expect(sessionsOf(all, 'norwegian-4x4-8wk', RunMode.intervals), 16);
    expect(
      sessionsOf(all, 'norwegian-4x4-8wk', RunMode.free),
      greaterThanOrEqualTo(8),
    );
    // 5k: one 4x4 a week plus two free runs.
    expect(sessionsOf(all, '5k-8wk', RunMode.intervals), 8);
    expect(sessionsOf(all, '5k-8wk', RunMode.free), 16);
    // Base: free runs only.
    expect(sessionsOf(all, 'base-4wk', RunMode.intervals), 0);
    expect(sessionsOf(all, 'base-4wk', RunMode.free), 12);
  });

  test('the Norwegian builds 3 to 4 reps and 3:30 down to 3:00', () {
    final t = loadAll()['norwegian-4x4-8wk']!;
    final f4s = t.weeks
        .map((w) => w.firstWhere((s) => s.kind == PlanSessionKind.fourByFour))
        .toList();
    expect(f4s.first.reps, 3);
    expect(f4s.first.recoverySeconds, 210);
    expect(f4s.last.reps, 4);
    expect(f4s.last.recoverySeconds, 180);
    // Recovery never lengthens and reps never drop across the plan.
    for (var i = 1; i < f4s.length; i++) {
      expect(f4s[i].reps!, greaterThanOrEqualTo(f4s[i - 1].reps!));
      expect(
        f4s[i].recoverySeconds!,
        lessThanOrEqualTo(f4s[i - 1].recoverySeconds!),
      );
    }
  });

  test('every 4x4 session maps to a session spec for Start pre-fill', () {
    for (final t in loadAll().values) {
      for (final s in t.weeks.expand((w) => w)) {
        if (s.kind == PlanSessionKind.fourByFour) {
          final spec = s.toSessionSpec()!;
          expect(spec.repCount, s.reps);
          expect(
            spec.steps.firstWhere((st) => !st.isWork).value,
            s.recoverySeconds,
          );
        }
        expect(s.label, isNotEmpty);
      }
    }
  });
}
