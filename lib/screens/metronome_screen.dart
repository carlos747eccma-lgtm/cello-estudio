import 'dart:typed_data';

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../audio/synth.dart';
import '../store.dart';

class _Tick {
  _Tick(this.ms, this.beat, this.bpm);
  final double ms;
  final int beat; // -1 = subdivisión
  final int bpm;
}

/// Un compás renderizado.
class _Rendered {
  _Rendered(this.samples, this.ticks, this.lengthMs);
  final List<double> samples;
  final List<_Tick> ticks;
  final double lengthMs;
}

class MetronomeScreen extends StatefulWidget {
  const MetronomeScreen({super.key});

  @override
  State<MetronomeScreen> createState() => _MetronomeScreenState();
}

class _MetronomeScreenState extends State<MetronomeScreen> {
  static const int _sr = 22050;
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _completeSub;
  StreamSubscription<Duration>? _posSub;

  int _bpm = 80;
  int _beats = 4;
  int _sub = 1; // 1 negras, 2 corcheas, 3 tresillos, 4 semicorcheas
  bool _playing = false;

  // entrenador de tempo
  bool _trainer = false;
  int _target = 120;
  int _step = 4;
  int _everyBars = 4;

  // temporizador
  int _timerMin = 0; // 0 = sin límite
  DateTime? _startedAt;
  Timer? _stopTimer;

  // sincronía visual
  List<_Tick> _ticks = [];
  double _loopMs = 1;
  double _rampMs = 0; // duración de la rampa (0 si no hay)
  final Stopwatch _sw = Stopwatch();
  double _offsetMs = 0;
  Timer? _ui;
  int _curBeat = -1;
  int _curBpm = 80;
  Timer? _debounce;

  // tap tempo
  final List<DateTime> _taps = [];

  List<Map<String, dynamic>> _presets = [];

  @override
  void initState() {
    super.initState();
    _bpm = Store.I.getInt('mBpm', 80);
    _beats = Store.I.getInt('mBeats', 4);
    _sub = Store.I.getInt('mSub', 1);
    _curBpm = _bpm;
    _presets = Store.I.presets;
    _posSub = _player.onPositionChanged.listen((d) {
      _offsetMs = d.inMilliseconds - _sw.elapsedMilliseconds.toDouble();
    });
  }

  @override
  void dispose() {
    _ui?.cancel();
    _debounce?.cancel();
    _stopTimer?.cancel();
    _completeSub?.cancel();
    _posSub?.cancel();
    _logTime();
    WakelockPlus.disable();
    _player.dispose();
    super.dispose();
  }

  // ---------- generación de audio ----------
  _Rendered _renderBar(int bpm, double startMs) {
    final beatSamples = 60.0 / bpm * _sr;
    final total = (beatSamples * _beats).round();
    final out = List<double>.filled(total, 0);
    final ticks = <_Tick>[];
    final accent = Synth.click(1700, 0.95, _sr);
    final normal = Synth.click(1100, 0.75, _sr);
    final sub = Synth.click(800, 0.38, _sr);
    void put(List<double> c, int at) {
      for (var i = 0; i < c.length && at + i < total; i++) {
        out[at + i] += c[i];
      }
    }

    for (var b = 0; b < _beats; b++) {
      for (var s = 0; s < _sub; s++) {
        final pos = ((b + s / _sub) * beatSamples).round();
        final isMain = s == 0;
        put(isMain ? (b == 0 ? accent : normal) : sub, pos);
        ticks.add(_Tick(startMs + pos * 1000 / _sr, isMain ? b : -1, bpm));
      }
    }
    return _Rendered(out, ticks, total * 1000 / _sr);
  }

  /// Devuelve el WAV a reproducir y prepara los datos de sincronía.
  Uint8List _build() {
    if (!_trainer || _target == _bpm) {
      final bar = _renderBar(_bpm, 0);
      _ticks = bar.ticks;
      _loopMs = bar.lengthMs;
      _rampMs = 0;
      return wavFromSamples(bar.samples, _sr);
    }
    // Rampa: del tempo inicial al objetivo, un escalón cada _everyBars compases.
    final up = _target > _bpm;
    final all = <double>[];
    final ticks = <_Tick>[];
    var bpm = _bpm;
    var t = 0.0;
    while (true) {
      final bar = _renderBar(bpm, t);
      for (var i = 0; i < _everyBars; i++) {
        final r = _renderBar(bpm, t);
        all.addAll(r.samples);
        ticks.addAll(r.ticks);
        t += r.lengthMs;
      }
      if (bar.lengthMs == 0) break;
      if (bpm == _target) break;
      bpm = up ? (bpm + _step).clamp(_bpm, _target) : (bpm - _step).clamp(_target, _bpm);
    }
    _ticks = ticks;
    _rampMs = t;
    final last = _renderBar(_target, 0);
    _loopMs = last.lengthMs;
    return wavFromSamples(all, _sr);
  }

  Uint8List? _lastBytes;

  Future<void> _start() async {
    await _completeSub?.cancel();
    final bytes = _build();
    _lastBytes = bytes;
    _curBpm = _bpm;
    _startedAt ??= DateTime.now();
    await _player.stop();
    if (_rampMs > 0) {
      await _player.setReleaseMode(ReleaseMode.release);
      _completeSub = _player.onPlayerComplete.listen((_) => _startFinalLoop());
    } else {
      await _player.setReleaseMode(ReleaseMode.loop);
    }
    await _player.play(BytesSource(bytes, mimeType: 'audio/wav'));
    _sw
      ..reset()
      ..start();
    _offsetMs = 0;
    _ui?.cancel();
    _ui = Timer.periodic(const Duration(milliseconds: 20), (_) => _tickUi());
    await WakelockPlus.enable();
    if (_timerMin > 0) {
      _stopTimer?.cancel();
      _stopTimer = Timer(Duration(minutes: _timerMin), _stop);
    }
    if (mounted) setState(() => _playing = true);
  }

  Future<void> _startFinalLoop() async {
    final bar = _renderBar(_target, 0);
    _ticks = bar.ticks;
    _loopMs = bar.lengthMs;
    _rampMs = 0;
    _curBpm = _target;
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.play(BytesSource(wavFromSamples(bar.samples, _sr), mimeType: 'audio/wav'));
    _sw
      ..reset()
      ..start();
    _offsetMs = 0;
  }

  void _tickUi() {
    if (!_playing || _ticks.isEmpty) return;
    var t = _sw.elapsedMilliseconds + _offsetMs;
    if (_rampMs == 0) t = t % _loopMs;
    var cur = -1;
    var bpm = _curBpm;
    for (final k in _ticks) {
      if (k.ms <= t + 8) {
        if (k.beat >= 0) cur = k.beat;
        bpm = k.bpm;
      } else {
        break;
      }
    }
    if (cur != _curBeat || bpm != _curBpm) {
      setState(() {
        _curBeat = cur;
        _curBpm = bpm;
      });
    }
  }

  void _logTime() {
    final s = _startedAt;
    if (s != null) {
      final mins = DateTime.now().difference(s).inSeconds / 60.0;
      if (mins >= 0.25) Store.I.addMinutes(mins);
    }
    _startedAt = null;
  }

  Future<void> _stop() async {
    _stopTimer?.cancel();
    _ui?.cancel();
    await _completeSub?.cancel();
    await _player.stop();
    await WakelockPlus.disable();
    _logTime();
    if (mounted) {
      setState(() {
        _playing = false;
        _curBeat = -1;
      });
    }
  }

  /// Cambios mientras suena: se reinicia el audio con un pequeño retraso.
  void _changed() {
    Store.I.setInt('mBpm', _bpm);
    Store.I.setInt('mBeats', _beats);
    Store.I.setInt('mSub', _sub);
    if (!_playing) {
      setState(() => _curBpm = _bpm);
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _start);
  }

  void _setBpm(int v) {
    setState(() => _bpm = v.clamp(30, 240));
    _changed();
  }

  void _tap() {
    final now = DateTime.now();
    if (_taps.isNotEmpty && now.difference(_taps.last).inMilliseconds > 2000) _taps.clear();
    _taps.add(now);
    if (_taps.length > 6) _taps.removeAt(0);
    if (_taps.length >= 2) {
      final span = _taps.last.difference(_taps.first).inMilliseconds / (_taps.length - 1);
      _setBpm((60000 / span).round());
    }
  }

  String get _tempoWord {
    final b = _curBpm;
    if (b < 60) return 'Largo';
    if (b < 76) return 'Adagio';
    if (b < 108) return 'Andante';
    if (b < 120) return 'Moderato';
    if (b < 156) return 'Allegro';
    return 'Presto';
  }

  // ---------- presets ----------
  Future<void> _savePreset() async {
    final ctrl = TextEditingController(text: 'Pieza $_bpm');
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Guardar preset'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('Guardar')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    _presets.add({'name': name, 'bpm': _bpm, 'beats': _beats, 'sub': _sub});
    await Store.I.savePresets(_presets);
    setState(() {});
  }

  void _applyPreset(Map<String, dynamic> p) {
    setState(() {
      _bpm = p['bpm'] as int;
      _beats = p['beats'] as int;
      _sub = p['sub'] as int;
    });
    _changed();
  }

  // ---------- interfaz ----------
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: Text('${_playing ? _curBpm : _bpm}',
              style: const TextStyle(fontSize: 96, fontWeight: FontWeight.w200)),
        ),
        Center(child: Text(_tempoWord, style: Theme.of(context).textTheme.titleMedium)),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (final d in [-5, -1])
            IconButton.filledTonal(
                onPressed: () => _setBpm(_bpm + d), icon: Text('$d')),
          const SizedBox(width: 8),
          for (final d in [1, 5])
            IconButton.filledTonal(
                onPressed: () => _setBpm(_bpm + d), icon: Text('+$d')),
        ]),
        Slider(
          min: 30,
          max: 240,
          value: _bpm.toDouble(),
          onChanged: (v) => setState(() => _bpm = v.round()),
          onChangeEnd: (_) => _changed(),
        ),
        const SizedBox(height: 8),
        _beatDots(cs),
        const SizedBox(height: 16),
        Center(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
                minimumSize: const Size(200, 56), textStyle: const TextStyle(fontSize: 18)),
            onPressed: _playing ? _stop : _start,
            icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
            label: Text(_playing ? 'Parar' : 'Empezar'),
          ),
        ),
        const SizedBox(height: 8),
        Center(child: OutlinedButton.icon(onPressed: _tap, icon: const Icon(Icons.touch_app), label: const Text('Tap tempo'))),
        const Divider(height: 36),
        Text('Compás', style: Theme.of(context).textTheme.titleSmall),
        Wrap(spacing: 6, children: [
          for (final b in [2, 3, 4, 5, 6, 7, 9, 12])
            ChoiceChip(
              label: Text('$b'),
              selected: _beats == b,
              onSelected: (_) {
                setState(() => _beats = b);
                _changed();
              },
            ),
        ]),
        const SizedBox(height: 10),
        Text('Subdivisión', style: Theme.of(context).textTheme.titleSmall),
        Wrap(spacing: 6, children: [
          for (final e in {1: 'Negras', 2: 'Corcheas', 3: 'Tresillos', 4: 'Semicorcheas'}.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: _sub == e.key,
              onSelected: (_) {
                setState(() => _sub = e.key);
                _changed();
              },
            ),
        ]),
        const Divider(height: 36),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Entrenador de tempo'),
          subtitle: const Text('Sube (o baja) el tempo solo, poco a poco'),
          value: _trainer,
          onChanged: (v) {
            setState(() => _trainer = v);
            if (_playing) _changed();
          },
        ),
        if (_trainer) ...[
          _stepper('Tempo final', _target, 30, 240, 5, (v) {
            setState(() => _target = v);
            if (_playing) _changed();
          }),
          _stepper('Escalón (bpm)', _step, 1, 20, 1, (v) {
            setState(() => _step = v);
            if (_playing) _changed();
          }),
          _stepper('Cada (compases)', _everyBars, 1, 16, 1, (v) {
            setState(() => _everyBars = v);
            if (_playing) _changed();
          }),
        ],
        const Divider(height: 36),
        Row(children: [
          Text('Temporizador', style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          DropdownButton<int>(
            value: _timerMin,
            items: [
              const DropdownMenuItem(value: 0, child: Text('Sin límite')),
              for (final m in [5, 10, 15, 20, 30, 45, 60])
                DropdownMenuItem(value: m, child: Text('$m min')),
            ],
            onChanged: (v) => setState(() => _timerMin = v ?? 0),
          ),
        ]),
        const Divider(height: 36),
        Row(children: [
          Text('Presets', style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          TextButton.icon(onPressed: _savePreset, icon: const Icon(Icons.save_outlined), label: const Text('Guardar actual')),
        ]),
        Wrap(spacing: 6, children: [
          for (final p in [
            {'name': 'Lento', 'bpm': 60, 'beats': 4, 'sub': 1},
            {'name': 'Andante', 'bpm': 80, 'beats': 4, 'sub': 1},
            {'name': 'Moderato', 'bpm': 100, 'beats': 4, 'sub': 1},
            {'name': 'Allegro', 'bpm': 120, 'beats': 4, 'sub': 1},
          ])
            ActionChip(label: Text('${p['name']} ${p['bpm']}'), onPressed: () => _applyPreset(p)),
          for (var i = 0; i < _presets.length; i++)
            InputChip(
              label: Text('${_presets[i]['name']} · ${_presets[i]['bpm']}'),
              onPressed: () => _applyPreset(_presets[i]),
              onDeleted: () async {
                _presets.removeAt(i);
                await Store.I.savePresets(_presets);
                setState(() {});
              },
            ),
        ]),
      ],
    );
  }

  Widget _beatDots(ColorScheme cs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < _beats; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _curBeat == i
                  ? (i == 0 ? cs.primary : cs.secondary)
                  : cs.surfaceContainerHighest,
              border: Border.all(color: i == 0 ? cs.primary : cs.outline, width: i == 0 ? 2 : 1),
            ),
          ),
      ],
    );
  }

  Widget _stepper(String label, int v, int min, int max, int stepBy, ValueChanged<int> on) {
    return Row(children: [
      Expanded(child: Text(label)),
      IconButton(
          onPressed: v - stepBy >= min ? () => on(v - stepBy) : null,
          icon: const Icon(Icons.remove_circle_outline)),
      SizedBox(width: 40, child: Center(child: Text('$v'))),
      IconButton(
          onPressed: v + stepBy <= max ? () => on(v + stepBy) : null,
          icon: const Icon(Icons.add_circle_outline)),
    ]);
  }
}
