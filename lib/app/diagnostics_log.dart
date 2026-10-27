/// Crash and error capture that stays on the phone. Dart errors (framework,
/// async, zone) are appended to a small rolling file; Settings → About →
/// "Share diagnostics" hands that file, plus the native crash file, the exit
/// verdicts and the strap trail, to the system share sheet as one text
/// bundle. Nothing is sent anywhere by the app itself (no Data safety change).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;

import '../theme/theme.dart';
import 'version.dart';

/// Set by CI/release builds with `--dart-define=BUILD_SHA=<sha>`.
const String kBuildSha = String.fromEnvironment(
  'BUILD_SHA',
  defaultValue: 'dev',
);

/// The native side (MainActivity.kt) writes next to the Dart files.
const MethodChannel _native = MethodChannel('app.runsolo/diagnostics');

class DiagnosticsLog {
  DiagnosticsLog(
    this.dir, {
    this.version = kAppVersion,
    this.buildSha = kBuildSha,
    DateTime Function()? now,
    this.maxFileBytes = 256 * 1024,
  }) : _now = now ?? DateTime.now;

  /// The one log of this process; null in tests that do not install one.
  static DiagnosticsLog? instance;

  /// App files dir `/diagnostics` (the Kotlin handler writes here too).
  final Directory dir;
  final String version;
  final String buildSha;

  /// Two files of this size: 512 KB in all.
  final int maxFileBytes;
  final DateTime Function() _now;

  static const currentName = 'dart-errors.log';
  static const previousName = 'dart-errors.1.log';
  static const nativeCrashName = 'native-crash.log';
  static const bleTrailName = 'ble-trail.log';

  File get _current => File('${dir.path}/$currentName');
  File get _previous => File('${dir.path}/$previousName');

  static const _maxErrorChars = 4 * 1024;
  static const _maxStackChars = 8 * 1024;
  static const _maxMemory = 20;
  static const _repeatWindow = Duration(seconds: 60);

  /// Entries a failed file write kept (a dir that cannot be created must not
  /// lose the error); they go into the bundle too.
  final List<String> _memory = [];

  String? _lastKey;
  DateTime? _lastAt;
  int _repeats = 0;

  /// Append one entry. Synchronous and never throws: it runs while the app is
  /// already failing, and a log must not add a second failure. Each entry is
  /// size-capped, and the same error again within a minute only bumps a
  /// counter (no file IO), so a per-frame failure cannot flood the log.
  void record(Object error, StackTrace? stack, {String source = 'dart'}) {
    try {
      final at = _now();
      final errorText = _cap(redact(error.toString()), _maxErrorChars);
      final stackText = _cap(
        redact((stack ?? StackTrace.empty).toString()),
        _maxStackChars,
      );
      final key = '$source|${_firstLine(errorText)}|${_firstLine(stackText)}';
      if (key == _lastKey &&
          _lastAt != null &&
          at.difference(_lastAt!) < _repeatWindow) {
        _repeats++;
        return;
      }
      final entry = StringBuffer();
      if (_repeats > 0) {
        entry.writeln('(previous entry repeated $_repeats times)');
      }
      _repeats = 0;
      _lastKey = key;
      _lastAt = at;
      entry
        ..writeln(
          '--- ${at.toUtc().toIso8601String()} $source '
          'app=$version build=$buildSha',
        )
        ..writeln(errorText)
        ..writeln(stackText);
      _append(entry.toString());
    } catch (_) {}
  }

  void _append(String text) {
    try {
      dir.createSync(recursive: true);
      if (_current.existsSync() && _current.lengthSync() >= maxFileBytes) {
        if (_previous.existsSync()) _previous.deleteSync();
        _current.renameSync(_previous.path);
      }
      _current.writeAsStringSync(text, mode: FileMode.append);
    } catch (_) {
      _memory.add(text);
      if (_memory.length > _maxMemory) _memory.removeAt(0);
    }
  }

  static String _cap(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}\n(truncated)';

  static String _firstLine(String s) {
    final i = s.indexOf('\n');
    return i < 0 ? s : s.substring(0, i);
  }

  /// Strips what must never be shared by accident: coordinates and secrets.
  @visibleForTesting
  static String redact(String text) {
    var out = text;
    for (final (pattern, replacement) in _rules) {
      out = out.replaceAllMapped(pattern, (m) => replacement(m));
    }
    return out;
  }

  static final List<(RegExp, String Function(Match))> _rules = [
    // `LatLng(51.5, -0.12)` however few decimals.
    (RegExp(r'LatLng\([^)]*\)'), (_) => 'LatLng(<redacted>)'),
    // lat/lon/lng named values: `lat: 51.5074`, `"longitude":-0.12`, `lat 51.5`.
    (
      RegExp(
        r'''\b(lat(?:itude)?|lon(?:gitude)?|lng)(["']?\s*[:=]\s*|\s+)-?\d+(?:\.\d+)?''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}${m[2]}<redacted>',
    ),
    // A bare coordinate pair: `51.507, -0.127` or `51.507412 -0.127812`.
    (RegExp(r'-?\d{1,3}\.\d{3,}[\s,]+-?\d{1,3}\.\d{3,}'), (_) => '<coords>'),
    (RegExp(r'[\w.+-]+@[\w-]+(?:\.[\w-]+)+'), (_) => '<email>'),
    (
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      (_) => 'Bearer <redacted>',
    ),
    // token=..., api_key: ..., authorization=..., secret, password, and the
    // companion/Telegram ids.
    (
      RegExp(
        r'''(token|api[_-]?key|authorization|secret|password|chat_id|user_id|runner_id)(["']?\s*[:=]\s*["']?)[^\s"',;&]+''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}${m[2]}<redacted>',
    ),
    // Companion runner ids (`u_abc123`).
    (RegExp(r'\bu_[A-Za-z0-9]+'), (_) => 'u_<id>'),
    // Long opaque strings (keys, JWTs).
    (RegExp(r'[A-Za-z0-9_\-]{32,}'), (_) => '<redacted>'),
  ];

  /// Everything worth attaching, as one text file in [tempDir] ready for the
  /// share sheet. Null when the bundle could not be written.
  Future<File?> writeBundle(Directory tempDir) async {
    try {
      final out = StringBuffer()
        ..writeln('Run Supreme diagnostics')
        ..writeln('app=$version build=$buildSha')
        ..writeln('created=${_now().toUtc().toIso8601String()}')
        ..writeln('platform=${Platform.operatingSystem}')
        ..writeln();
      out.writeln('== Dart errors ==');
      out.writeln(redact(await _tail(_previous)));
      out.writeln(redact(await _tail(_current)));
      for (final m in _memory) {
        out.writeln(redact(m));
      }
      out.writeln('== Native crashes ==');
      out.writeln(redact(await _tail(File('${dir.path}/$nativeCrashName'))));
      out.writeln('== Exit verdicts ==');
      out.writeln(redact(await _nativeExitTail()));
      out.writeln('== Strap trail (tail) ==');
      out.writeln(redact(await _tail(_bleTrail, maxBytes: 16 * 1024)));
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
      await tempDir.create(recursive: true);
      final file = File('${tempDir.path}/run-supreme-diagnostics.txt');
      await file.writeAsString(out.toString());
      return file;
    } catch (_) {
      return null;
    }
  }

  /// The strap trail lives one level up, in the files dir.
  File get _bleTrail => File('${dir.parent.path}/$bleTrailName');

  Future<String> _nativeExitTail() async {
    try {
      return await _native.invokeMethod<String>('exitTail') ?? '(none)';
    } catch (_) {
      return '(none)';
    }
  }

  Future<String> _tail(File f, {int maxBytes = 256 * 1024}) async {
    if (!await f.exists()) return '(none)';
    final len = await f.length();
    if (len <= maxBytes) return f.readAsString();
    final raf = await f.open();
    try {
      await raf.setPosition(len - maxBytes);
      return String.fromCharCodes(await raf.read(maxBytes));
    } finally {
      await raf.close();
    }
  }

  /// Route framework, platform-dispatcher and (via the caller's zone) async
  /// errors here. [calmScreen] swaps the grey/red error widget for
  /// [CalmErrorScreen]; release builds only by default.
  void install({bool? calmScreen}) {
    instance = this;
    final previousHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      record(details.exception, details.stack, source: 'flutter');
      if (kDebugMode) previousHandler?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, source: 'platform');
      // false lets the engine print it in debug builds.
      return !kDebugMode;
    };
    if (calmScreen ?? kReleaseMode) {
      ErrorWidget.builder = (details) => const CalmErrorScreen();
    }
  }
}

/// What replaces a widget that threw while building. Built from the theme
/// tokens directly: it may render outside any Theme or Material ancestor.
class CalmErrorScreen extends StatelessWidget {
  const CalmErrorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = RunSoloTokens.light;
    return LayoutBuilder(
      builder: (context, box) =>
          box.maxHeight < 200 || box.maxWidth < 200 ? _compact(t) : _full(t),
    );
  }

  Widget _compact(RunSoloTokens t) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: t.bgBase,
      child: Center(
        child: Text(
          'Something broke. The run is safe.',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: RunSoloType.label13.copyWith(
            color: t.inkSecondary,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    ),
  );

  Widget _full(RunSoloTokens t) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: t.bgBase,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.x24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SOMETHING BROKE',
                  style: RunSoloType.title28.copyWith(
                    color: t.inkPrimary,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: Space.x12),
                Text(
                  'The run is safe. Go back and try again; if it keeps '
                  'happening, Settings → About → Share diagnostics lets you send '
                  'us what happened.',
                  style: RunSoloType.body17.copyWith(
                    color: t.inkSecondary,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
