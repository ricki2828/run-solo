/// The spoken start briefing for a planned session (C2b A2, eng-review #1, #2, #9, #10, #15).
///
/// A briefing is a TEMPLATE with slots: `{session}`, `{pace}`, `{minutes}`, `{distance}`, `{reps}`. The recorder
/// fills them on the device, in the runner's units, from the same values the in-run cues use, so no number is ever
/// written by a model or a server (see `StartBriefing.kt`). This file holds the Dart side:
///
/// - the app's OWN template for a plan session ([StartBriefing.fallback]), spoken when the coach has no briefing for
///   the session (or its template does not render within the cap);
/// - the content FINGERPRINT that matches a coach briefing to the session actually started
///   ([StartBriefing.fingerprint]), the same algorithm as the server's `briefing.py` (FINGERPRINT section) and tested
///   against its fixture;
/// - the derivations the config needs ([StartBriefing.plan]).
///
/// Pure and synchronous: the Start path reads nothing over the network.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:run_engine/run_engine.dart' as engine;

import 'companion.dart'
    show companionPaceFacts, companionPlanType, companionTemplateFacts;

/// What the config carries for a briefed session: the app's own template and what its slots speak.
class BriefingPlan {
  const BriefingPlan({
    required this.fallback,
    required this.minutes,
    required this.distanceM,
    required this.reps,
    required this.sessionName,
  });

  /// The app's own template (slots only, at most [StartBriefing.maxWords] words once rendered).
  final String fallback;

  /// `{minutes}`: the planned duration, null when the plan holds none.
  final int? minutes;

  /// `{distance}`: a long run's minimum distance (the LONG test), null otherwise.
  final double? distanceM;

  /// `{reps}`: the work reps, null for a session with none.
  final int? reps;

  /// `{session}`: the name as spoken, null for an easy or long run.
  final String? sessionName;
}

abstract final class StartBriefing {
  /// Words, counted on the RENDERED text. The recorder re-counts and falls back; it never truncates.
  static const maxWords = 40;

  static const fingerprintVersion = 'v1';

  /// The template for a planned session, or null for a run that keeps its own start line (goal, event, trail,
  /// Cooper, laps, Free). [hasPace]: the recorder has a target pace to speak for `{pace}`.
  static BriefingPlan? plan(
    engine.BlockSession? session, {
    required bool hasPace,
  }) {
    if (session == null || session.kind == engine.BlockKind.goal) return null;
    final minutes = session.minutes != null && session.minutes! > 0
        ? session.minutes
        : null;
    final distanceM =
        session.kind == engine.BlockKind.long &&
            session.minDistanceM != null &&
            session.minDistanceM! > 0
        ? session.minDistanceM
        : null;
    final interval = session.kind == engine.BlockKind.interval;
    final reps = interval ? _repsOf(session) : null;
    final name = interval ? _spokenName(session) : null;
    return BriefingPlan(
      fallback: fallback(
        kind: session.kind,
        norwegian: session.presetId == engine.SessionSpec.norwegian4x4Id,
        hasSession: name != null,
        hasMinutes: minutes != null,
        hasDistance: distanceM != null,
        hasReps: reps != null,
        hasPace: hasPace,
      ),
      minutes: minutes,
      distanceM: distanceM,
      reps: reps,
      sessionName: name,
    );
  }

  /// The app's own briefing, as a template: the kind is named first, then one pacing line. It keeps the intro
  /// content the run already had (a Norwegian 4x4 says "Warm up as long as you like."). Only slots the caller can
  /// fill are used, so it always renders; every variant is at most [maxWords] words rendered
  /// (`voice_copy.tsv` holds each one, in km and miles).
  static String fallback({
    required engine.BlockKind kind,
    bool norwegian = false,
    bool hasSession = false,
    bool hasMinutes = false,
    bool hasDistance = false,
    bool hasReps = false,
    bool hasPace = false,
  }) {
    switch (kind) {
      case engine.BlockKind.easy:
        return '${hasMinutes ? 'Easy run, {minutes}.' : 'Easy run.'} '
            'Keep it relaxed and conversational. If you cannot chat, ease off.';
      case engine.BlockKind.long:
        final size = hasMinutes
            ? ', {minutes}'
            : hasDistance
            ? ', {distance} or more'
            : '';
        return 'Long run$size. '
            'Start patient and steady, and save something for the last third.';
      case engine.BlockKind.goal:
        return ''; // a goal run keeps its own start line ([plan] never asks)
      case engine.BlockKind.interval:
        final head = hasSession ? '{session}.' : 'Quality session.';
        if (norwegian) {
          final work = hasReps
              ? 'Then {reps}, hard but even'
              : 'Then go hard but even';
          return '$head Warm up as long as you like. '
              '$work${hasPace ? ', holding {pace}' : ''}. Jog the recoveries.';
        }
        final today = hasReps ? ' Today is {reps}.' : '';
        final hold = hasPace
            ? 'Hold {pace} on each one'
            : 'Run each one hard but even';
        return '$head$today $hold and jog the recoveries.';
    }
  }

  // ---------------------------------------------------------------------------------------------- fingerprint

  /// "v1|kind=..|min=..|dist_m=..|reps=..|pace_lo=..|pace_hi=..": one line, fields in this order. Every number is
  /// converted with round-half-up, `floor(x + 0.5)`, and written as a plain integer; an absent value is empty.
  static String canonical({
    required String kind,
    num? minutes,
    num? distanceM,
    num? reps,
    num? paceLo,
    num? paceHi,
  }) {
    String f(num? v) => v == null ? '' : '${(v + 0.5).floor()}';
    return '$fingerprintVersion|kind=$kind|min=${f(minutes)}|dist_m=${f(distanceM)}'
        '|reps=${f(reps)}|pace_lo=${f(paceLo)}|pace_hi=${f(paceHi)}';
  }

  /// The first 16 lowercase hex characters of SHA-256 over the UTF-8 [canonical] string.
  static String fingerprint({
    required String kind,
    num? minutes,
    num? distanceM,
    num? reps,
    num? paceLo,
    num? paceHi,
  }) {
    final c = canonical(
      kind: kind,
      minutes: minutes,
      distanceM: distanceM,
      reps: reps,
      paceLo: paceLo,
      paceHi: paceHi,
    );
    return sha256.convert(utf8.encode(c)).toString().substring(0, 16);
  }

  /// The fingerprint of the session actually started, from exactly the facts the run upload sends the server as
  /// `plan_next` (so the two ends cannot drift): `type`, `minutes`, `distance_m`, the template id and name, and the
  /// pace band. Reps come from an "NxM" in the template id or name, like the server.
  static String fingerprintOf(
    engine.BlockSession session, {
    engine.TargetPaces? paces,
  }) {
    int? within(num? v, int lo, int hi) {
      if (v == null) return null;
      final r = v.round();
      return r >= lo && r <= hi ? r : null;
    }

    final template = companionTemplateFacts(session);
    final pace = companionPaceFacts(session, paces);
    return fingerprint(
      kind: companionPlanType(session.kind),
      minutes: within(session.minutes, 1, 600),
      distanceM: within(session.minDistanceM, 500, 100000),
      reps: repsFrom(
        template['session_id'] as String?,
        template['session_name'] as String?,
      ),
      paceLo: pace['target_pace_lo_s'] as num?,
      paceHi: pace['target_pace_hi_s'] as num?,
    );
  }

  static final _repsRe = RegExp(
    r'(?<!\d)(\d{1,2})\s*x\s*\d',
    caseSensitive: false,
  );

  /// The work reps from an "NxM" in the template id, else the name (`norwegian_4x4` is 4), as the server derives them.
  static int? repsFrom(String? sessionId, String? sessionName) {
    for (final text in [sessionId, sessionName]) {
      final m = _repsRe.firstMatch(text ?? '');
      if (m != null) return int.parse(m.group(1)!);
    }
    return null;
  }

  // ---------------------------------------------------------------------------------------------- slot values

  /// `{reps}`: the reps the plan actually runs for this session (they change week to week: 3, 4 or 5 for a
  /// Norwegian 4x4), else the catalogue default for the preset. NOT the NxM in the name: [repsFrom] is only for the
  /// fingerprint (the server contract). The recorder re-reads the reps from the session it records.
  static int? _repsOf(engine.BlockSession s) {
    final id = s.presetId;
    final reps =
        s.reps ??
        (id == null ? null : engine.SessionCatalogue.byId(id)?.defaultReps);
    return reps != null && reps > 0 ? reps : null;
  }

  /// `{session}`: the session's name as the voice says it. The plan's own name carries the reps the runner will do
  /// ("6 × 400 m"), which the catalogue name does not.
  static String? _spokenName(engine.BlockSession s) {
    final raw = s.presetId == null ? null : s.name;
    return raw == null ? null : spoken(raw);
  }

  /// "Norwegian 4x4" is "Norwegian 4 by 4", "6 × 400 m" is "6 by 400 metres", "30/30s" is "30 30s": what a voice can
  /// read. Null when nothing readable is left.
  static String? spoken(String name) {
    var s = name
        .replaceAllMapped(
          RegExp(r'(\d)\s*[x×]\s*(\d)', caseSensitive: false),
          (m) => '${m[1]} by ${m[2]}',
        )
        .replaceAllMapped(RegExp(r'(\d)\s*m\b'), (m) => '${m[1]} metres')
        .replaceAllMapped(
          RegExp(r'(\d+)\s*km\b'),
          (m) => '${m[1]} ${m[1] == '1' ? 'kilometre' : 'kilometres'}',
        )
        .replaceAll(RegExp(r'[/_-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.length > 40) {
      // At a word boundary, like the recorder's own speakable().
      final cut = s.substring(0, 40);
      final space = cut.lastIndexOf(' ');
      s = (space > 0 ? cut.substring(0, space) : cut).trim();
    }
    return RegExp(r'[A-Za-z0-9]').hasMatch(s) ? s : null;
  }
}
