import 'dart:math' as math;
import 'dart:typed_data';

/// Convierte muestras en coma flotante (-1..1) a un WAV PCM16 mono.
Uint8List wavFromSamples(List<double> samples, int sampleRate) {
  final n = samples.length;
  final data = ByteData(44 + n * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    data.setInt16(44 + i * 2, v, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Timbres con las amplitudes de los armónicos.
enum Timbre {
  cello([1.0, 0.55, 0.38, 0.28, 0.2, 0.14, 0.09, 0.06]),
  suave([1.0, 0.25, 0.08, 0.03]),
  puro([1.0]);

  const Timbre(this.harmonics);
  final List<double> harmonics;
}

class Synth {
  static const int sr = 44100;

  /// Un bucle sin cortes de una nota sostenida.
  ///
  /// El bucle contiene un número entero de periodos, así que al repetirse no
  /// hay clic ni salto de fase, y la frecuencia real queda a menos de 0,01
  /// cents de la pedida.
  static Uint8List loopTone(double freq, {Timbre timbre = Timbre.cello}) {
    const targetSeconds = 2.0;
    final periods = math.max(1, (freq * targetSeconds).round());
    final length = (periods * sr / freq).round();
    final realFreq = periods * sr / length;
    final h = timbre.harmonics;
    final out = List<double>.filled(length, 0);
    var peak = 0.0;
    for (var i = 0; i < length; i++) {
      var v = 0.0;
      for (var k = 0; k < h.length; k++) {
        final f = realFreq * (k + 1);
        if (f > sr / 2 - 500) break;
        v += h[k] * math.sin(2 * math.pi * f * i / sr);
      }
      out[i] = v;
      if (v.abs() > peak) peak = v.abs();
    }
    final gain = peak == 0 ? 1.0 : 0.7 / peak;
    for (var i = 0; i < length; i++) {
      out[i] *= gain;
    }
    return wavFromSamples(out, sr);
  }

  /// Un clic corto con caída exponencial.
  static List<double> click(double freq, double amp, int sampleRate) {
    final len = (sampleRate * 0.035).round();
    final out = List<double>.filled(len, 0);
    for (var i = 0; i < len; i++) {
      final t = i / sampleRate;
      final env = math.exp(-t * 120);
      out[i] = amp * env * math.sin(2 * math.pi * freq * t);
    }
    return out;
  }
}
