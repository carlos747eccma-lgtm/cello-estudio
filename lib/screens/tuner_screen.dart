import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../audio/pitch.dart';
import '../audio/synth.dart';
import '../store.dart';

class Instrument {
  const Instrument(this.name, this.offset);
  final String name;

  /// Semitonos que se suman a la nota real para obtener la nota escrita.
  final int offset;
}

const instruments = [
  Instrument('Chelo (Do)', 0),
  Instrument('Clarinete (Si♭)', 2),
  Instrument('Sax alto (Mi♭)', 9),
  Instrument('Sax tenor (Si♭)', 14),
];

class TunerScreen extends StatefulWidget {
  const TunerScreen({super.key, required this.active});
  final bool active;

  @override
  State<TunerScreen> createState() => _TunerScreenState();
}

class _TunerScreenState extends State<TunerScreen> {
  // ---------- afinador ----------
  final _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  bool _listening = false;
  final _detector = YinDetector(sampleRate: 22050);
  final _buf = Float32List(8192);
  int _bufLen = 0;
  int _sinceDetect = 0;
  double? _carry; // muestra impar al diezmar

  double _a4 = 440;
  int _inst = 0;
  NoteInfo? _note; // nota real (de concierto)
  double? _freq;
  double _clarity = 0;
  final List<double> _recent = [];
  DateTime _lastVoiced = DateTime.fromMillisecondsSinceEpoch(0);
  final List<double?> _trace = []; // cents recientes, null = silencio
  Timer? _decay;

  // ---------- drones ----------
  final List<AudioPlayer> _dronePlayers = [AudioPlayer(), AudioPlayer(), AudioPlayer()];
  bool _droneOn = false;
  int _droneNote = 0; // 0..11 sobre el Do, en la notación del instrumento
  int _droneOctave = 2;
  bool _withFifth = false;
  bool _withOctave = false;
  bool _justFifth = false;
  double _droneVol = 0.8;
  Timer? _droneDebounce;

  @override
  void initState() {
    super.initState();
    _a4 = Store.I.getDouble('a4', 440);
    _inst = Store.I.getInt('inst', 0).clamp(0, instruments.length - 1);
    _droneNote = Store.I.getInt('droneNote', 0);
    _droneOctave = Store.I.getInt('droneOct', 2);
    for (final p in _dronePlayers) {
      p.setReleaseMode(ReleaseMode.loop);
    }
    _decay = Timer.periodic(const Duration(milliseconds: 90), (_) {
      if (!mounted) return;
      if (_listening) {
        final silent = DateTime.now().difference(_lastVoiced).inMilliseconds > 350;
        if (silent) {
          _trace.add(null);
          if (_trace.length > 120) _trace.removeAt(0);
          if (_note != null) setState(() => _note = null);
          _recent.clear();
        }
      }
    });
  }

  @override
  void didUpdateWidget(TunerScreen old) {
    super.didUpdateWidget(old);
    if (old.active && !widget.active) _stopListening();
  }

  @override
  void dispose() {
    _decay?.cancel();
    _droneDebounce?.cancel();
    _sub?.cancel();
    _rec.dispose();
    for (final p in _dronePlayers) {
      p.dispose();
    }
    super.dispose();
  }

  // ---------- micrófono ----------
  Future<void> _startListening() async {
    if (!await _rec.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Necesito permiso de micrófono para afinar.')));
      }
      return;
    }
    final stream = await _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 44100,
      numChannels: 1,
      echoCancel: false,
      noiseSuppress: false,
      autoGain: false,
    ));
    _bufLen = 0;
    _carry = null;
    _sub = stream.listen(_onAudio);
    setState(() => _listening = true);
  }

  Future<void> _stopListening() async {
    await _sub?.cancel();
    _sub = null;
    if (await _rec.isRecording()) await _rec.stop();
    if (mounted) {
      setState(() {
        _listening = false;
        _note = null;
        _freq = null;
        _trace.clear();
        _recent.clear();
      });
    }
  }

  void _onAudio(Uint8List bytes) {
    // PCM16 little endian a 44100 Hz -> media de pares -> 22050 Hz.
    final bd = ByteData.sublistView(bytes);
    final n = bytes.length ~/ 2;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little) / 32768.0;
      if (_carry == null) {
        _carry = s;
      } else {
        final d = (_carry! + s) * 0.5;
        _carry = null;
        if (_bufLen == _buf.length) {
          _buf.setRange(0, _buf.length - 1024, _buf, 1024);
          _bufLen = _buf.length - 1024;
        }
        _buf[_bufLen++] = d;
        _sinceDetect++;
      }
    }
    if (_sinceDetect >= 512 && _bufLen >= _detector.needed) {
      _sinceDetect = 0;
      final window = Float32List.sublistView(_buf, 0, _bufLen);
      final r = _detector.detect(window);
      _onPitch(r);
    }
  }

  void _onPitch(PitchResult? r) {
    if (!mounted) return;
    if (r == null || r.clarity < 0.80) return;
    _lastVoiced = DateTime.now();
    // Mediana de las últimas 3 lecturas para evitar saltos.
    _recent.add(r.freq);
    if (_recent.length > 3) _recent.removeAt(0);
    final sorted = [..._recent]..sort();
    final f = sorted[sorted.length ~/ 2];
    final info = noteFromFreq(f, _a4);
    _trace.add(info.cents + 0.0 + (info.midi - info.midi));
    if (_trace.length > 120) _trace.removeAt(0);
    setState(() {
      _freq = f;
      _note = info;
      _clarity = r.clarity;
    });
  }

  // ---------- drones ----------
  double _droneFreq(int semis) {
    // La nota está en la notación del instrumento: el sonido real es offset semitonos más grave.
    final writtenMidi = (_droneOctave + 1) * 12 + _droneNote;
    final soundMidi = writtenMidi - instruments[_inst].offset;
    return freqFromMidi(soundMidi + semis, _a4);
  }

  Future<void> _startDrone() async {
    final voices = <double>[_droneFreq(0)];
    if (_withFifth) {
      voices.add(_justFifth ? _droneFreq(0) * 1.5 : _droneFreq(7));
    }
    if (_withOctave) voices.add(_droneFreq(12));
    for (var i = 0; i < _dronePlayers.length; i++) {
      final p = _dronePlayers[i];
      if (i < voices.length) {
        final bytes = Synth.loopTone(voices[i]);
        await p.setVolume(_droneVol * (i == 0 ? 1.0 : 0.7));
        await p.play(BytesSource(bytes, mimeType: 'audio/wav'));
      } else {
        await p.stop();
      }
    }
    if (mounted) setState(() => _droneOn = true);
  }

  Future<void> _stopDrone() async {
    for (final p in _dronePlayers) {
      await p.stop();
    }
    if (mounted) setState(() => _droneOn = false);
  }

  void _refreshDrone() {
    Store.I.setInt('droneNote', _droneNote);
    Store.I.setInt('droneOct', _droneOctave);
    if (!_droneOn) return;
    _droneDebounce?.cancel();
    _droneDebounce = Timer(const Duration(milliseconds: 250), _startDrone);
  }

  // ---------- interfaz ----------
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final inst = instruments[_inst];
    final note = _note;
    String bigName = '—';
    String sub = _listening ? 'Toca una nota…' : 'Pulsa el micrófono';
    Color col = cs.onSurfaceVariant;
    if (note != null) {
      final written = NoteInfo(note.midi + inst.offset, note.cents);
      bigName = '${written.name}${written.octave}';
      final c = note.cents;
      sub = '${c >= 0 ? '+' : ''}${c.toStringAsFixed(0)} cents · ${_freq!.toStringAsFixed(1)} Hz';
      col = c.abs() <= 5
          ? Colors.green
          : c.abs() <= 15
              ? Colors.amber.shade700
              : Colors.redAccent;
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (var i = 0; i < instruments.length; i++)
              ChoiceChip(
                label: Text(instruments[i].name),
                selected: _inst == i,
                onSelected: (_) {
                  setState(() => _inst = i);
                  Store.I.setInt('inst', i);
                  _refreshDrone();
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('La4 ='),
            IconButton(
                onPressed: () => _setA4(_a4 - 1), icon: const Icon(Icons.remove_circle_outline)),
            Text('${_a4.toStringAsFixed(0)} Hz', style: Theme.of(context).textTheme.titleMedium),
            IconButton(
                onPressed: () => _setA4(_a4 + 1), icon: const Icon(Icons.add_circle_outline)),
            TextButton(onPressed: () => _setA4(440), child: const Text('440')),
            TextButton(onPressed: () => _setA4(442), child: const Text('442')),
          ],
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(bigName,
              style: TextStyle(fontSize: 84, fontWeight: FontWeight.w300, color: col)),
        ),
        Center(child: Text(sub, style: TextStyle(color: col, fontSize: 18))),
        const SizedBox(height: 12),
        SizedBox(
          height: 70,
          child: CustomPaint(
              painter: _GaugePainter(note?.cents, cs.onSurface.withOpacity(.6), col),
              size: Size.infinite),
        ),
        const SizedBox(height: 8),
        Text('Entonación en los últimos segundos',
            style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        SizedBox(
          height: 110,
          child: CustomPaint(
              painter: _TracePainter(List.of(_trace), cs.primary, cs.outlineVariant),
              size: Size.infinite),
        ),
        const SizedBox(height: 12),
        Center(
          child: FilledButton.icon(
            onPressed: _listening ? _stopListening : _startListening,
            icon: Icon(_listening ? Icons.mic_off : Icons.mic),
            label: Text(_listening ? 'Parar afinador' : 'Activar afinador'),
          ),
        ),
        const Divider(height: 40),
        _droneCard(context, inst),
      ],
    );
  }

  void _setA4(double v) {
    setState(() => _a4 = v.clamp(415, 466));
    Store.I.setDouble('a4', _a4);
    _refreshDrone();
  }

  Widget _droneCard(BuildContext context, Instrument inst) {
    final names = noteNamesEs;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('Dron', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              FilledButton.tonalIcon(
                onPressed: _droneOn ? _stopDrone : _startDrone,
                icon: Icon(_droneOn ? Icons.stop : Icons.play_arrow),
                label: Text(_droneOn ? 'Parar' : 'Sonar'),
              ),
            ]),
            const SizedBox(height: 4),
            Text('Nota sostenida para entrenar la entonación. Notas en la escritura de: ${inst.name}.',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 0, children: [
              for (var i = 0; i < 12; i++)
                ChoiceChip(
                  label: Text(names[i]),
                  selected: _droneNote == i,
                  onSelected: (_) {
                    setState(() => _droneNote = i);
                    _refreshDrone();
                  },
                ),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              const Text('Octava'),
              IconButton(
                  onPressed: () {
                    setState(() => _droneOctave = math.max(1, _droneOctave - 1));
                    _refreshDrone();
                  },
                  icon: const Icon(Icons.remove_circle_outline)),
              Text('$_droneOctave'),
              IconButton(
                  onPressed: () {
                    setState(() => _droneOctave = math.min(6, _droneOctave + 1));
                    _refreshDrone();
                  },
                  icon: const Icon(Icons.add_circle_outline)),
            ]),
            Wrap(spacing: 8, children: [
              FilterChip(
                label: const Text('+ Quinta'),
                selected: _withFifth,
                onSelected: (v) {
                  setState(() => _withFifth = v);
                  _refreshDrone();
                },
              ),
              FilterChip(
                label: const Text('+ Octava'),
                selected: _withOctave,
                onSelected: (v) {
                  setState(() => _withOctave = v);
                  _refreshDrone();
                },
              ),
              if (_withFifth)
                FilterChip(
                  label: const Text('Quinta justa 3:2'),
                  selected: _justFifth,
                  onSelected: (v) {
                    setState(() => _justFifth = v);
                    _refreshDrone();
                  },
                ),
            ]),
            Row(children: [
              const Icon(Icons.volume_down),
              Expanded(
                child: Slider(
                  value: _droneVol,
                  onChanged: (v) {
                    setState(() => _droneVol = v);
                    for (var i = 0; i < _dronePlayers.length; i++) {
                      _dronePlayers[i].setVolume(v * (i == 0 ? 1.0 : 0.7));
                    }
                  },
                ),
              ),
              const Icon(Icons.volume_up),
            ]),
            Text(
                'Suena: ${_droneFreq(0).toStringAsFixed(2)} Hz'
                '${_withFifth ? ' + quinta' : ''}${_withOctave ? ' + octava' : ''}',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.cents, this.tick, this.needle);
  final double? cents;
  final Color tick;
  final Color needle;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final base = size.height - 10;
    final p = Paint()
      ..color = tick
      ..strokeWidth = 1.5;
    // Zona verde (±5 cents)
    final zone = Paint()..color = Colors.green.withOpacity(.25);
    final x0 = w * (0.5 - 5 / 100);
    final x1 = w * (0.5 + 5 / 100);
    canvas.drawRect(Rect.fromLTRB(x0, 0, x1, base), zone);
    for (var c = -50; c <= 50; c += 10) {
      final x = w * (0.5 + c / 100);
      final h = c % 50 == 0 || c == 0 ? 26.0 : 14.0;
      canvas.drawLine(Offset(x, base), Offset(x, base - h), p);
    }
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final c in [-50, 0, 50]) {
      tp.text = TextSpan(text: '$c', style: TextStyle(color: tick, fontSize: 11));
      tp.layout();
      tp.paint(canvas, Offset(w * (0.5 + c / 100) - tp.width / 2, base - 44));
    }
    if (cents != null) {
      final x = w * (0.5 + cents!.clamp(-50, 50) / 100);
      final np = Paint()
        ..color = needle
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(x, base + 4), Offset(x, 4), np);
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.cents != cents || old.needle != needle;
}

class _TracePainter extends CustomPainter {
  _TracePainter(this.trace, this.line, this.grid);
  final List<double?> trace;
  final Color line;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    double yOf(double c) => size.height * (0.5 - c.clamp(-50, 50) / 100);
    canvas.drawLine(Offset(0, yOf(0)), Offset(size.width, yOf(0)), gp..strokeWidth = 2);
    for (final c in [-25.0, 25.0]) {
      canvas.drawLine(Offset(0, yOf(c)), Offset(size.width, yOf(c)), gp..strokeWidth = 1);
    }
    const maxPts = 120;
    final dx = size.width / maxPts;
    final lp = Paint()
      ..color = line
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    var path = Path();
    var open = false;
    final start = maxPts - trace.length;
    for (var i = 0; i < trace.length; i++) {
      final v = trace[i];
      final x = (start + i) * dx;
      if (v == null) {
        if (open) {
          canvas.drawPath(path, lp);
          path = Path();
          open = false;
        }
      } else if (!open) {
        path.moveTo(x, yOf(v));
        open = true;
      } else {
        path.lineTo(x, yOf(v));
      }
    }
    if (open) canvas.drawPath(path, lp);
  }

  @override
  bool shouldRepaint(covariant _TracePainter old) => true;
}
