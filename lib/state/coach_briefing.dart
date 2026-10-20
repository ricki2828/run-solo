/// The coach's start briefing as the app holds it (C2b A3, eng-review #2, #3, #15).
///
/// `GET /v1/me/briefing` is fetched on Home load and after a run upload, never at Start. The answer is kept here
/// (and mirrored to the secret store so it survives a restart) keyed by `(session_ref, fingerprint)`. At Start the
/// recorder asks [BriefingCache.choose], which is synchronous and reads only what is already in memory.
///
/// Reply handling (server contract in `companion-server/companion/coach/briefing.py`):
/// - 200 with a template: replace the cache.
/// - 200 `{"status":"suppress"}`: a safety block is on. Keep a suppress marker (with the time) and speak NO briefing
///   at Start, neither the coach's nor the app's own: the plain start line.
/// - 202 `{"status":"pending"}`: a job is running. Keep the cache.
/// - 204: nothing to say. Clear the cache; the app's own briefing may still be spoken.
/// - offline or any other error: keep the cache.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// One cached answer: a template for one session, or the suppress marker.
@immutable
class CachedBriefing {
  const CachedBriefing.template({
    required String this.sessionRef,
    required String this.fingerprint,
    required String this.template,
    required this.generatedAt,
    required this.savedAt,
  }) : suppress = false;

  const CachedBriefing.suppress({required this.savedAt})
    : suppress = true,
      sessionRef = null,
      fingerprint = null,
      template = null,
      generatedAt = null;

  final bool suppress;
  final String? sessionRef;
  final String? fingerprint;
  final String? template;

  /// The server's `generated_at`: a template's age is counted from it.
  final DateTime? generatedAt;

  /// When this app stored it: a suppress marker's age is counted from it.
  final DateTime savedAt;

  Map<String, Object?> toJson() => {
    'suppress': suppress,
    'session_ref': sessionRef,
    'fingerprint': fingerprint,
    'template': template,
    'generated_at': generatedAt?.toUtc().toIso8601String(),
    'saved_at': savedAt.toUtc().toIso8601String(),
  };

  /// Null for anything odd: a bad cache is no cache.
  static CachedBriefing? fromJson(Object? j) {
    if (j is! Map) return null;
    final saved = j['saved_at'];
    final savedAt = saved is String ? DateTime.tryParse(saved) : null;
    if (savedAt == null) return null;
    if (j['suppress'] == true) return CachedBriefing.suppress(savedAt: savedAt);
    final ref = j['session_ref'], fp = j['fingerprint'], t = j['template'];
    final gen = j['generated_at'];
    if (ref is! String || fp is! String || t is! String || t.isEmpty) {
      return null;
    }
    return CachedBriefing.template(
      sessionRef: ref,
      fingerprint: fp,
      template: t,
      generatedAt: gen is String ? DateTime.tryParse(gen) : null,
      savedAt: savedAt,
    );
  }

  static CachedBriefing? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  String encode() => jsonEncode(toJson());

  /// A 200 with a `template` is a briefing, a 200 `{"status":"suppress"}` is the marker; anything else is null.
  static CachedBriefing? fromReply(Map<String, Object?> j, DateTime now) {
    if (j['status'] == 'suppress' && j['template'] == null) {
      return CachedBriefing.suppress(savedAt: now);
    }
    final ref = j['session_ref'], fp = j['fingerprint'], t = j['template'];
    final gen = j['generated_at'];
    if (ref is! String || ref.isEmpty) return null;
    if (fp is! String || fp.isEmpty) return null;
    if (t is! String || t.trim().isEmpty) return null;
    return CachedBriefing.template(
      sessionRef: ref,
      fingerprint: fp,
      template: t,
      generatedAt: gen is String ? DateTime.tryParse(gen) : null,
      savedAt: now,
    );
  }
}

/// What Start does with the cache for the session it is starting.
@immutable
class BriefingChoice {
  const BriefingChoice({this.template, this.suppress = false});

  /// The coach's template, matched to this session and fresh; null otherwise.
  final String? template;

  /// A fresh suppress marker: speak no briefing at all.
  final bool suppress;

  static const none = BriefingChoice();
}

abstract final class BriefingCache {
  /// A cached briefing or marker older than this is ignored (the server drops its own after the same time).
  static const maxAge = Duration(hours: 36);

  /// The pure decision. [sessionRef] and [fingerprint] are those of the session actually being started (null when
  /// the run is not today's planned session: nothing is used then, not even a suppress marker, because no briefing
  /// would be spoken anyway).
  static BriefingChoice choose(
    CachedBriefing? cached, {
    required String? sessionRef,
    required String? fingerprint,
    required DateTime now,
  }) {
    if (cached == null || sessionRef == null || fingerprint == null) {
      return BriefingChoice.none;
    }
    if (cached.suppress) {
      return now.difference(cached.savedAt) < maxAge
          ? const BriefingChoice(suppress: true)
          : BriefingChoice.none;
    }
    final gen = cached.generatedAt;
    if (gen == null || now.difference(gen) >= maxAge) {
      return BriefingChoice.none;
    }
    if (cached.sessionRef != sessionRef || cached.fingerprint != fingerprint) {
      return BriefingChoice.none;
    }
    return BriefingChoice(template: cached.template);
  }
}
