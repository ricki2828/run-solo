import 'package:flutter/material.dart';

import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/settings.dart';
import '../theme/theme.dart';

enum _Scan { idle, scanning, found, failed }

/// HR strap pairing (design brief §4.11): one scan for Heart Rate Profile
/// devices, Whoop listed plainly with the broadcast hint, saved device with
/// Forget. The pulsing ring is the one loop allowed off the record screen.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen>
    with SingleTickerProviderStateMixin {
  _Scan _scan = _Scan.idle;
  List<BleDevice> _devices = const [];
  String? _error;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    final services = AppServices.of(context);
    setState(() {
      _scan = _Scan.scanning;
      _error = null;
    });
    if (!MediaQuery.disableAnimationsOf(context)) _pulse.repeat();
    try {
      final found = await services.ble.scan();
      if (!mounted) return;
      setState(() {
        _devices = found;
        _scan = found.isEmpty ? _Scan.failed : _Scan.found;
        if (found.isEmpty) _error = 'No strap found.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scan = _Scan.failed;
        _error = 'Scan failed. Is Bluetooth on?';
      });
    } finally {
      _pulse.stop();
      _pulse.reset();
    }
  }

  Future<void> _pair(BleDevice d) async {
    final services = AppServices.of(context);
    try {
      await services.ble.pair(d);
      await services.settings.update(
        (s) => s.copyWith(
          strap: SavedStrap(address: d.address, name: d.name),
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scan = _Scan.failed;
        _error = _isWhoop(d)
            ? 'Turn on broadcast in the Whoop app, then retry.'
            : 'Could not connect. Move the strap closer and retry.';
      });
    }
  }

  Future<void> _forget() async {
    final services = AppServices.of(context);
    await services.ble.forget();
    await services.settings.update((s) => s.copyWith(clearStrap: true));
    if (mounted) setState(() {});
  }

  static bool _isWhoop(BleDevice d) =>
      (d.name ?? '').toUpperCase().startsWith('WHOOP');

  String _label(BleDevice d) =>
      _isWhoop(d) ? 'Whoop (broadcast on in Whoop app)' : (d.name ?? 'Strap');

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final saved = AppServices.of(context).settings.settings.strap;

    return Scaffold(
      appBar: AppBar(title: const Text('HEART RATE STRAP')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
          children: [
            const SizedBox(height: Space.x8),
            Text(
              'Any Bluetooth heart-rate strap. Whoop works with broadcast on.',
              style: text.bodyLarge?.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x24),
            if (saved != null) ...[
              Text(
                'SAVED',
                style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x8),
              _DeviceRow(
                title: saved.label,
                subtitle: saved.address,
                trailing: TextButton(
                  onPressed: _forget,
                  child: Text(
                    'Forget',
                    style: RunSoloType.label13.copyWith(color: t.semSlower),
                  ),
                ),
              ),
              const SizedBox(height: Space.x24),
            ],
            Center(
              child: SizedBox(
                width: 120,
                height: 120,
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) => CustomPaint(
                    painter: _ScanRingPainter(
                      progress: _scan == _Scan.scanning ? _pulse.value : 0,
                      color: t.inkPrimary,
                      hair: t.lineHair,
                    ),
                    child: Center(
                      child: Icon(
                        Icons.favorite_border,
                        size: 32,
                        color: t.hrZone,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.x24),
            if (_scan == _Scan.scanning)
              Center(
                child: Text(
                  'Scanning. Put the strap on so it wakes up.',
                  style: text.bodyMedium?.copyWith(color: t.inkSecondary),
                ),
              ),
            if (_scan == _Scan.found) ...[
              Text(
                'FOUND',
                style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x8),
              for (final d in _devices)
                _DeviceRow(
                  title: _label(d),
                  subtitle: d.address,
                  onTap: () => _pair(d),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: Space.x12),
              Text(_error!, style: text.bodyMedium?.copyWith(color: t.semWarn)),
            ],
            const SizedBox(height: Space.x32),
            FilledButton(
              onPressed: _scan == _Scan.scanning ? null : _startScan,
              child: Text(_scan == _Scan.idle ? 'SCAN' : 'SCAN AGAIN'),
            ),
            const SizedBox(height: Space.x12),
            Text(
              'Whoop: open the Whoop app, Settings, Broadcast heart rate, '
              'then scan here.',
              style: RunSoloType.label13.copyWith(
                color: t.inkMuted,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: Space.x24),
          ],
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
  });
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(vertical: Space.x12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.lineHair)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                  ),
                  Text(
                    subtitle,
                    style: RunSoloType.label13.copyWith(color: t.inkMuted),
                  ),
                ],
              ),
            ),
            trailing ??
                Icon(Icons.chevron_right, size: 24, color: t.inkSecondary),
          ],
        ),
      ),
    );
  }
}

class _ScanRingPainter extends CustomPainter {
  _ScanRingPainter({
    required this.progress,
    required this.color,
    required this.hair,
  });
  final double progress;
  final Color color;
  final Color hair;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(
      c,
      r * 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = hair,
    );
    if (progress <= 0) return;
    canvas.drawCircle(
      c,
      r * (0.5 + 0.5 * progress),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 1 - progress),
    );
  }

  @override
  bool shouldRepaint(_ScanRingPainter old) => old.progress != progress;
}
