import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../audio/pitch.dart';
import '../audio/synth.dart';
import '../store.dart';

/// Chelo virtual: cuatro cuerdas con las notas del mástil, de Do2 a La3.
class CelloScreen extends StatefulWidget {
  const CelloScreen({super.key});

  @override
  State<CelloScreen> createState() => _CelloScreenState();
}

class _CelloScreenState extends State<CelloScreen> {
  // De grave a aguda: Do2, Sol2, Re3, La3 (midi).
  static const _openMidi = [36, 43, 50, 57];
  static const _stringNames = ['Do', 'Sol', 'Re', 'La'];
  static const int _zones = 13; // 0 = cuerda al aire … 12 = octava

  final List<AudioPlayer> _players = List.generate(4, (_) => AudioPlayer());
  final Map<int, Uint8List> _cache = {};
  final List<int?> _pressed = [null, null, null, null];
  double _a4 = 440;
  bool _showNames = true;
  bool _sustain = true;

  @override
  void initState() {
    super.initState();
    _a4 = Store.I.getDouble('a4', 440);
    for (final p in _players) {
      p.setReleaseMode(ReleaseMode.loop);
    }
  }

  @override
  void dispose() {
    for (final p in _players) {
      p.dispose();
    }
    super.dispose();
  }

  Future<void> _down(int string, int zone) async {
    final midi = _openMidi[string] + zone;
    setState(() => _pressed[string] = zone);
    final bytes = _cache.putIfAbsent(
        midi, () => Synth.loopTone(freqFromMidi(midi, _a4), timbre: Timbre.cello));
    final p = _players[string];
    await p.stop();
    await p.setVolume(0.9);
    await p.play(BytesSource(bytes, mimeType: 'audio/wav'));
  }

  Future<void> _up(int string) async {
    setState(() => _pressed[string] = null);
    if (_sustain) {
      await _players[string].stop();
    } else {
      Future.delayed(const Duration(milliseconds: 700), () => _players[string].stop());
    }
  }

  int _zoneAt(double dy, double h) => ((dy / h) * _zones).floor().clamp(0, _zones - 1);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                  label: const Text('Nombres de notas'),
                  selected: _showNames,
                  onSelected: (v) => setState(() => _showNames = v)),
              FilterChip(
                  label: const Text('Suena mientras pulsas'),
                  selected: _sustain,
                  onSelected: (v) => setState(() => _sustain = v)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            'Cada franja es un semitono. La cuerda al aire está arriba; la octava, abajo. '
            'Sirve para ubicar notas y entrenar el oído; no sustituye al arco ni a la presión de los dedos.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: LayoutBuilder(builder: (context, c) {
              final h = c.maxHeight;
              return Row(
                children: [
                  for (var s = 0; s < 4; s++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Column(children: [
                          Text(_stringNames[s],
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Expanded(
                            child: LayoutBuilder(builder: (context, cc) {
                              final bh = cc.maxHeight;
                              return Listener(
                                onPointerDown: (e) => _down(s, _zoneAt(e.localPosition.dy, bh)),
                                onPointerMove: (e) {
                                  final z = _zoneAt(e.localPosition.dy, bh);
                                  if (_pressed[s] != null && _pressed[s] != z) _down(s, z);
                                },
                                onPointerUp: (_) => _up(s),
                                onPointerCancel: (_) => _up(s),
                                child: CustomPaint(
                                  size: Size(double.infinity, bh),
                                  painter: _StringPainter(
                                    open: _openMidi[s],
                                    pressed: _pressed[s],
                                    zones: _zones,
                                    showNames: _showNames,
                                    cs: cs,
                                  ),
                                ),
                              );
                            }),
                          ),
                        ]),
                      ),
                    ),
                ],
              );
            }),
          ),
        ),
      ],
    );
  }
}

class _StringPainter extends CustomPainter {
  _StringPainter({
    required this.open,
    required this.pressed,
    required this.zones,
    required this.showNames,
    required this.cs,
  });
  final int open;
  final int? pressed;
  final int zones;
  final bool showNames;
  final ColorScheme cs;

  static const _natural = {0, 2, 4, 5, 7, 9, 11};

  @override
  void paint(Canvas canvas, Size size) {
    final zh = size.height / zones;
    final board = Paint()..color = const Color(0xFF2A1D14);
    canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)), board);
    for (var z = 0; z < zones; z++) {
      final y = z * zh;
      final midi = open + z;
      final isNat = _natural.contains(midi % 12);
      if (pressed == z) {
        canvas.drawRect(Rect.fromLTWH(0, y, size.width, zh),
            Paint()..color = cs.primary.withOpacity(.85));
      } else if (!isNat) {
        canvas.drawRect(
            Rect.fromLTWH(0, y, size.width, zh), Paint()..color = Colors.black.withOpacity(.25));
      }
      canvas.drawLine(Offset(0, y), Offset(size.width, y),
          Paint()..color = Colors.white24..strokeWidth = 1);
      if (showNames) {
        final tp = TextPainter(
          text: TextSpan(
              text: noteNamesEs[midi % 12],
              style: TextStyle(
                  color: pressed == z ? cs.onPrimary : Colors.white70,
                  fontSize: 12,
                  fontWeight: isNat ? FontWeight.w600 : FontWeight.w300)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(6, y + (zh - tp.height) / 2));
      }
    }
    // Cuerda
    canvas.drawLine(
        Offset(size.width / 2, 0),
        Offset(size.width / 2, size.height),
        Paint()
          ..color = const Color(0xFFD9C7A3)
          ..strokeWidth = 2.5);
  }

  @override
  bool shouldRepaint(covariant _StringPainter old) =>
      old.pressed != pressed || old.showNames != showNames;
}
