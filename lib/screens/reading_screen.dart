import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../store.dart';

enum Clef { fa, doCuarta }

/// Una nota natural: índice diatónico (0 = Do0, 7 = Do1, 14 = Do2 …).
class StaffNote {
  const StaffNote(this.clef, this.d);
  final Clef clef;
  final int d;
  int get letter => d % 7; // 0 Do … 6 Si
  int get octave => d ~/ 7;
  String get key => '${clef.name}:$d';

  /// Posición sobre la pauta: 0 = línea inferior, 1 = primer espacio …
  int get pos => d - (clef == Clef.fa ? 18 : 22);
}

const _solfege = ['Do', 'Re', 'Mi', 'Fa', 'Sol', 'La', 'Si'];

class ReadingScreen extends StatefulWidget {
  const ReadingScreen({super.key});

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen> {
  final _rnd = math.Random();
  String _mode = 'fa'; // fa | do | mix
  int _level = 2;
  late StaffNote _note;
  int? _picked;
  int _streak = 0;
  int _best = 0;
  int _ok = 0;
  int _total = 0;

  // Rangos por nivel (índices diatónicos).
  static const _faRange = {1: [14, 20], 2: [14, 24], 3: [14, 27], 4: [14, 31], 5: [14, 33]};
  static const _doRange = {1: [26, 30], 2: [24, 31], 3: [24, 33], 4: [24, 36], 5: [22, 38]};

  @override
  void initState() {
    super.initState();
    _mode = Store.I.getString('readMode', 'fa');
    _level = Store.I.getInt('readLevel', 2);
    _note = _next();
  }

  StaffNote _next() {
    final clef = _mode == 'mix'
        ? (_rnd.nextBool() ? Clef.fa : Clef.doCuarta)
        : (_mode == 'do' ? Clef.doCuarta : Clef.fa);
    final r = (clef == Clef.fa ? _faRange : _doRange)[_level]!;
    final stats = Store.I.noteStats;
    // Repaso espaciado: peso mayor a las notas con caja baja.
    final candidates = <int>[];
    final weights = <double>[];
    for (var d = r[0]; d <= r[1]; d++) {
      final s = stats['${clef.name}:$d'];
      final box = s?['box'] ?? 0;
      candidates.add(d);
      weights.add(math.pow(2, 4 - box).toDouble());
    }
    final totalW = weights.fold<double>(0, (a, b) => a + b);
    var x = _rnd.nextDouble() * totalW;
    var chosen = candidates.last;
    for (var i = 0; i < candidates.length; i++) {
      x -= weights[i];
      if (x <= 0) {
        chosen = candidates[i];
        break;
      }
    }
    // Evita repetir la misma nota seguida.
    if (candidates.length > 1 && chosen == (_noteOrNull?.d) && clef == _noteOrNull?.clef) {
      chosen = candidates[(candidates.indexOf(chosen) + 1) % candidates.length];
    }
    return StaffNote(clef, chosen);
  }

  StaffNote? get _noteOrNull {
    try {
      return _note;
    } catch (_) {
      return null;
    }
  }

  Future<void> _answer(int letter) async {
    if (_picked != null) return;
    final correct = letter == _note.letter;
    setState(() {
      _picked = letter;
      _total++;
      if (correct) {
        _ok++;
        _streak++;
        _best = math.max(_best, _streak);
      } else {
        _streak = 0;
      }
    });
    await Store.I.recordAnswer(_note.key, correct);
    await Future.delayed(Duration(milliseconds: correct ? 450 : 1100));
    if (!mounted) return;
    setState(() {
      _note = _next();
      _picked = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(spacing: 8, children: [
          for (final e in {'fa': 'Clave de Fa', 'do': 'Do en cuarta', 'mix': 'Mezcla'}.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: _mode == e.key,
              onSelected: (_) {
                setState(() {
                  _mode = e.key;
                  _note = _next();
                  _picked = null;
                });
                Store.I.setString('readMode', e.key);
              },
            ),
        ]),
        Row(children: [
          const Text('Nivel'),
          Expanded(
            child: Slider(
              min: 1,
              max: 5,
              divisions: 4,
              label: '$_level',
              value: _level.toDouble(),
              onChanged: (v) {
                setState(() {
                  _level = v.round();
                  _note = _next();
                  _picked = null;
                });
                Store.I.setInt('readLevel', _level);
              },
            ),
          ),
          Text('$_level'),
        ]),
        Container(
          height: 230,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withOpacity(.4),
            borderRadius: BorderRadius.circular(16),
          ),
          child: CustomPaint(
            painter: _StaffPainter(_note, cs.onSurface,
                _picked == null ? null : (_picked == _note.letter ? Colors.green : Colors.redAccent)),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            _picked == null
                ? '¿Qué nota es?'
                : (_picked == _note.letter
                    ? '¡Correcto!'
                    : 'Era ${_solfege[_note.letter]} (octava ${_note.octave})'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < 7; i++)
              SizedBox(
                width: 72,
                height: 56,
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    backgroundColor: _picked == null
                        ? null
                        : (i == _note.letter
                            ? Colors.green.withOpacity(.6)
                            : (i == _picked ? Colors.redAccent.withOpacity(.6) : null)),
                  ),
                  onPressed: () => _answer(i),
                  child: Text(_solfege[i], style: const TextStyle(fontSize: 17)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
              'Racha: $_streak · Mejor: $_best · Aciertos: $_ok/$_total',
              style: Theme.of(context).textTheme.bodyMedium),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
              'Las notas que fallas salen más a menudo; las que dominas, cada vez menos.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _StaffPainter extends CustomPainter {
  _StaffPainter(this.note, this.ink, this.noteColor);
  final StaffNote note;
  final Color ink;
  final Color? noteColor;

  @override
  void paint(Canvas canvas, Size size) {
    final sp = math.min(size.height / 10, 20.0); // separación entre líneas
    final half = sp / 2;
    final cy = size.height / 2;
    final bottom = cy + 2 * sp; // línea inferior
    final left = 24.0;
    final right = size.width - 24;
    double yOfPos(int p) => bottom - p * half;

    final line = Paint()
      ..color = ink
      ..strokeWidth = 1.6;
    for (var i = 0; i < 5; i++) {
      final y = bottom - i * sp;
      canvas.drawLine(Offset(left, y), Offset(right, y), line);
    }

    // Clave
    if (note.clef == Clef.fa) {
      _drawBassClef(canvas, Offset(left + 8, yOfPos(6)), sp);
    } else {
      _drawCClef(canvas, Offset(left + 8, yOfPos(6)), sp);
    }

    // Nota
    final x = size.width / 2 + 20;
    final y = yOfPos(note.pos);
    final p = note.pos;
    // Líneas adicionales
    final ledger = Paint()
      ..color = ink
      ..strokeWidth = 1.6;
    if (p < 0) {
      for (var q = -2; q >= p - (p.isOdd ? 0 : 0); q -= 2) {
        if (q >= p - 1) {
          canvas.drawLine(Offset(x - 20, yOfPos(q)), Offset(x + 20, yOfPos(q)), ledger);
        }
      }
    } else if (p > 8) {
      for (var q = 10; q <= p; q += 2) {
        canvas.drawLine(Offset(x - 20, yOfPos(q)), Offset(x + 20, yOfPos(q)), ledger);
      }
    }
    final headW = sp * 0.62;
    final headH = sp * 0.46;
    final col = noteColor ?? ink;
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(-0.35);
    canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: headW * 2, height: headH * 2),
        Paint()..color = col);
    canvas.restore();
    final stemUp = p < 4;
    final stem = Paint()
      ..color = col
      ..strokeWidth = 2;
    if (stemUp) {
      canvas.drawLine(Offset(x + headW - 1, y), Offset(x + headW - 1, y - 3.3 * sp), stem);
    } else {
      canvas.drawLine(Offset(x - headW + 1, y), Offset(x - headW + 1, y + 3.3 * sp), stem);
    }
  }

  void _drawBassClef(Canvas canvas, Offset at, double sp) {
    // at = línea 4 (la de Fa). Versión simplificada de la clave de Fa.
    final paint = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = sp * 0.34
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = ink;
    canvas.drawCircle(Offset(at.dx + sp * 0.3, at.dy), sp * 0.34, fill);
    final path = Path()
      ..moveTo(at.dx + sp * 0.3, at.dy - sp * 0.3)
      ..cubicTo(at.dx + sp * 1.7, at.dy - sp * 0.5, at.dx + sp * 1.9, at.dy + sp * 1.6,
          at.dx + sp * 0.1, at.dy + sp * 3.0);
    canvas.drawPath(path, paint);
    canvas.drawCircle(Offset(at.dx + sp * 2.35, at.dy - sp * 0.5), sp * 0.18, fill);
    canvas.drawCircle(Offset(at.dx + sp * 2.35, at.dy + sp * 0.5), sp * 0.18, fill);
  }

  void _drawCClef(Canvas canvas, Offset at, double sp) {
    // at = línea 4 (Do central). Versión simplificada de la clave de Do.
    final thick = Paint()
      ..color = ink
      ..strokeWidth = sp * 0.38;
    final thin = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = sp * 0.2
      ..strokeCap = StrokeCap.round;
    final x = at.dx + sp * 0.2;
    canvas.drawLine(Offset(x, at.dy - sp * 2), Offset(x, at.dy + sp * 2), thick);
    canvas.drawLine(Offset(x + sp * 0.5, at.dy - sp * 2), Offset(x + sp * 0.5, at.dy + sp * 2),
        thin..strokeWidth = sp * 0.12);
    thin.strokeWidth = sp * 0.2;
    final top = Path()
      ..moveTo(x + sp * 0.6, at.dy)
      ..cubicTo(x + sp * 1.8, at.dy - sp * 0.2, x + sp * 1.8, at.dy - sp * 1.9,
          x + sp * 0.9, at.dy - sp * 1.9);
    final bot = Path()
      ..moveTo(x + sp * 0.6, at.dy)
      ..cubicTo(x + sp * 1.8, at.dy + sp * 0.2, x + sp * 1.8, at.dy + sp * 1.9,
          x + sp * 0.9, at.dy + sp * 1.9);
    canvas.drawPath(top, thin);
    canvas.drawPath(bot, thin);
  }

  @override
  bool shouldRepaint(covariant _StaffPainter old) =>
      old.note.d != note.d || old.note.clef != note.clef || old.noteColor != noteColor;
}
