import 'dart:math' as math;
import 'dart:typed_data';
import 'package:cello_estudio/audio/pitch.dart';
import 'package:cello_estudio/audio/synth.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List tone(double f, {int sr = 22050, double secs = 0.2, double noise = 0}) {
  final r = math.Random(1);
  final n = (sr * secs).round();
  final o = Float32List(n);
  const h = [1.0, 0.55, 0.38, 0.28, 0.2];
  for (var i = 0; i < n; i++) {
    var v = 0.0;
    for (var k = 0; k < h.length; k++) {
      v += h[k] * math.sin(2 * math.pi * f * (k + 1) * i / sr);
    }
    o[i] = (0.25 * v + noise * (r.nextDouble() - 0.5)).toDouble();
  }
  return o;
}

void main() {
  final det = YinDetector();
  test('detecta notas del chelo y del saxo con error < 3 cents', () {
    final cases = <double>[65.41, 98.0, 146.83, 220.0, 329.63, 440.0, 659.25, 880.0, 1174.66];
    for (final f in cases) {
      final r = det.detect(tone(f));
      expect(r, isNotNull, reason: '$f Hz no detectada');
      final cents = 1200 * math.log(r!.freq / f) / math.ln2;
      expect(cents.abs(), lessThan(3), reason: '$f Hz -> ${r.freq} ($cents cents)');
    }
  });
  test('detecta con ruido', () {
    final r = det.detect(tone(196.0, noise: 0.05));
    expect(r, isNotNull);
    expect((1200 * math.log(r!.freq / 196.0) / math.ln2).abs(), lessThan(5));
  });
  test('silencio no da tono', () {
    expect(det.detect(Float32List(4000)), isNull);
  });
  test('nota y cents', () {
    final n = noteFromFreq(442, 440);
    expect(n.name, 'La');
    expect(n.octave, 4);
    expect(n.cents, closeTo(7.85, 0.1));
  });
  test('bucle del dron: frecuencia exacta y tamaño', () {
    final w = Synth.loopTone(65.41);
    expect(w.length, greaterThan(100000));
    expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
  });
}
