import 'dart:math' as math;
import 'dart:typed_data';

/// Resultado de una detección.
class PitchResult {
  const PitchResult(this.freq, this.clarity);
  final double freq;

  /// 0..1; cuanto más alto, más fiable.
  final double clarity;
}

/// Detector de tono YIN (de Cheveigné y Kawahara, 2002).
class YinDetector {
  YinDetector({
    this.sampleRate = 22050,
    this.window = 1024,
    this.threshold = 0.15,
    this.minFreq = 50,
    this.maxFreq = 2000,
    this.minRms = 0.008,
  })  : _tauMax = math.min(window, (sampleRate / minFreq).floor()),
        _tauMin = math.max(2, (sampleRate / maxFreq).floor()),
        _diff = Float64List(math.min(window, (sampleRate / minFreq).floor()) + 1),
        _cmnd = Float64List(math.min(window, (sampleRate / minFreq).floor()) + 1);

  final int sampleRate;
  final int window;
  final double threshold;
  final double minFreq;
  final double maxFreq;
  final double minRms;
  final int _tauMax;
  final int _tauMin;
  final Float64List _diff;
  final Float64List _cmnd;

  /// Necesita al menos [window] + tauMax muestras.
  int get needed => window + _tauMax;

  PitchResult? detect(Float32List x) {
    if (x.length < needed) return null;
    final start = x.length - needed;

    var energy = 0.0;
    for (var i = 0; i < window; i++) {
      final v = x[start + i];
      energy += v * v;
    }
    if (math.sqrt(energy / window) < minRms) return null;

    // Función de diferencia.
    for (var tau = 1; tau <= _tauMax; tau++) {
      var sum = 0.0;
      for (var i = 0; i < window; i++) {
        final d = x[start + i] - x[start + i + tau];
        sum += d * d;
      }
      _diff[tau] = sum;
    }

    // Diferencia normalizada por la media acumulada.
    _cmnd[0] = 1;
    var running = 0.0;
    for (var tau = 1; tau <= _tauMax; tau++) {
      running += _diff[tau];
      _cmnd[tau] = running == 0 ? 1 : _diff[tau] * tau / running;
    }

    // Primer mínimo por debajo del umbral.
    var tauEst = -1;
    for (var tau = _tauMin; tau < _tauMax; tau++) {
      if (_cmnd[tau] < threshold) {
        while (tau + 1 < _tauMax && _cmnd[tau + 1] < _cmnd[tau]) {
          tau++;
        }
        tauEst = tau;
        break;
      }
    }
    if (tauEst < 0) return null;

    // Interpolación parabólica.
    final s0 = _cmnd[tauEst - 1];
    final s1 = _cmnd[tauEst];
    final s2 = tauEst + 1 <= _tauMax ? _cmnd[tauEst + 1] : _cmnd[tauEst];
    final denom = (s0 + s2 - 2 * s1);
    final shift = denom.abs() < 1e-12 ? 0.0 : 0.5 * (s0 - s2) / denom;
    final tauFine = tauEst + shift.clamp(-1.0, 1.0);

    final freq = sampleRate / tauFine;
    if (freq < minFreq || freq > maxFreq) return null;
    return PitchResult(freq, (1 - _cmnd[tauEst]).clamp(0.0, 1.0));
  }
}

const List<String> noteNamesEs = [
  'Do', 'Do♯', 'Re', 'Re♯', 'Mi', 'Fa', 'Fa♯', 'Sol', 'Sol♯', 'La', 'La♯', 'Si',
];

/// Nota más cercana y desviación en cents.
class NoteInfo {
  const NoteInfo(this.midi, this.cents);
  final int midi;
  final double cents;

  String get name => noteNamesEs[midi % 12];
  int get octave => midi ~/ 12 - 1;
}

double midiFromFreq(double freq, double a4) =>
    69 + 12 * math.log(freq / a4) / math.ln2;

double freqFromMidi(num midi, double a4) =>
    a4 * math.pow(2, (midi - 69) / 12).toDouble();

NoteInfo noteFromFreq(double freq, double a4) {
  final m = midiFromFreq(freq, a4);
  final near = m.round();
  return NoteInfo(near, (m - near) * 100);
}
