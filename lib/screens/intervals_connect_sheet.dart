import 'package:flutter/material.dart';

import '../app/services.dart';
import '../state/intervals_icu.dart';
import '../theme/theme.dart';

/// Connect Intervals.icu: paste the API key and athlete id, test them, save.
/// Resolves true when a key was saved (or is saved) and false when the
/// runner disconnected or left without one.
Future<bool?> showIntervalsConnectSheet(
  BuildContext context, {
  required IntervalsIcuTarget target,
}) {
  final t = Theme.of(context).extension<RunSoloTokens>()!;
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: t.bgBase,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    ),
    builder: (_) => IntervalsConnectSheet(target: target),
  );
}

class IntervalsConnectSheet extends StatefulWidget {
  const IntervalsConnectSheet({super.key, required this.target});
  final IntervalsIcuTarget target;

  @override
  State<IntervalsConnectSheet> createState() => _IntervalsConnectSheetState();
}

class _IntervalsConnectSheetState extends State<IntervalsConnectSheet> {
  final _key = TextEditingController();
  final _athlete = TextEditingController();
  bool _busy = false;
  bool _showKey = false;
  String? _line;
  bool _lineOk = false;

  @override
  void dispose() {
    _key.dispose();
    _athlete.dispose();
    super.dispose();
  }

  void _say(String line, {required bool ok}) => setState(() {
    _line = line;
    _lineOk = ok;
  });

  /// What the fields hold, or the saved key when the key field is empty.
  Future<IntervalsCredentials?> _creds() async {
    if (_key.text.trim().isEmpty && widget.target.connected) {
      final saved = await widget.target.credentials();
      if (saved != null) return saved;
    }
    final p = parseCredentials(_key.text, _athlete.text);
    if (p.creds == null) _say(p.error!, ok: false);
    return p.creds;
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    try {
      final c = await _creds();
      if (c == null) return;
      _say('Testing...', ok: true);
      final r = await widget.target.client.test(c);
      if (mounted) _say(r.line, ok: r.ok);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final p = parseCredentials(_key.text, _athlete.text);
      if (p.creds == null) {
        _say(p.error!, ok: false);
        return;
      }
      if (!await widget.target.connect(p.creds!)) {
        if (mounted) _say('Could not save the key on this phone', ok: false);
        return;
      }
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    await widget.target.disconnect();
    if (!mounted) return;
    final services = AppServices.of(context);
    await services.settings.update(
      (x) => x.withAutoSend(IntervalsIcuTarget.targetId, false, services.now()),
    );
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final connected = widget.target.connected;
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Space.screenGutter,
          Space.x4,
          Space.screenGutter,
          Space.x24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'CONNECT INTERVALS.ICU',
              style: RunSoloType.title28.copyWith(color: t.inkPrimary),
            ),
            const SizedBox(height: Space.x8),
            Text(
              kIntervalsKeyHelp,
              key: const ValueKey('intervals-help'),
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x8),
            Text(
              'The key stays on this phone, in its secure storage. It is only '
              'ever sent to Intervals.icu, and only to upload your runs.',
              style: RunSoloType.label13.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x16),
            TextField(
              key: const ValueKey('intervals-key'),
              controller: _key,
              obscureText: !_showKey,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              style: RunSoloType.body17.copyWith(color: t.inkPrimary),
              decoration: InputDecoration(
                labelText: connected ? 'API key (saved)' : 'API key',
                helperText: connected
                    ? 'Leave empty to keep the saved key'
                    : null,
                suffixIcon: IconButton(
                  tooltip: _showKey ? 'Hide key' : 'Show key',
                  icon: Icon(
                    _showKey ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
            ),
            const SizedBox(height: Space.x12),
            TextField(
              key: const ValueKey('intervals-athlete'),
              controller: _athlete,
              autocorrect: false,
              enableSuggestions: false,
              style: RunSoloType.body17.copyWith(color: t.inkPrimary),
              decoration: const InputDecoration(
                labelText: 'Athlete id',
                hintText: 'i12345',
              ),
            ),
            if (_line != null) ...[
              const SizedBox(height: Space.x12),
              Text(
                _line!,
                key: const ValueKey('intervals-line'),
                style: RunSoloType.body15.copyWith(
                  color: _lineOk ? t.inkSecondary : t.semWarn,
                ),
              ),
            ],
            const SizedBox(height: Space.x16),
            Wrap(
              spacing: Space.x12,
              runSpacing: Space.x8,
              children: [
                _Btn(
                  key: const ValueKey('intervals-test'),
                  label: 'Test connection',
                  onTap: _busy ? null : _test,
                ),
                _Btn(
                  key: const ValueKey('intervals-save'),
                  label: 'Save',
                  onTap: _busy ? null : _save,
                ),
                if (connected)
                  _Btn(
                    key: const ValueKey('intervals-disconnect'),
                    label: 'Disconnect',
                    onTap: _busy ? null : _disconnect,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({super.key, required this.label, required this.onTap});
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
