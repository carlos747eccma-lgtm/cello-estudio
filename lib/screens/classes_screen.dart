import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../store.dart';

String fmt(int ms) {
  final s = ms ~/ 1000;
  final m = s ~/ 60;
  return '${m.toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

class ClassesScreen extends StatefulWidget {
  const ClassesScreen({super.key});

  @override
  State<ClassesScreen> createState() => _ClassesScreenState();
}

class _ClassesScreenState extends State<ClassesScreen> {
  final _rec = AudioRecorder();
  bool _recording = false;
  String _kind = 'clase';
  final Stopwatch _sw = Stopwatch();
  Timer? _tick;
  String? _currentPath;
  List<Map<String, dynamic>> _sessions = [];

  @override
  void initState() {
    super.initState();
    _sessions = Store.I.sessions.reversed.toList();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _rec.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _start() async {
    if (!await _rec.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Necesito permiso de micrófono para grabar.')));
      }
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/${_kind}_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 96000,
        sampleRate: 44100,
        numChannels: 1,
        echoCancel: false,
        noiseSuppress: false,
        autoGain: false,
      ),
      path: path,
    );
    _currentPath = path;
    _sw
      ..reset()
      ..start();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    await WakelockPlus.enable();
    setState(() => _recording = true);
  }

  Future<void> _stop() async {
    final path = await _rec.stop() ?? _currentPath;
    _sw.stop();
    _tick?.cancel();
    await WakelockPlus.disable();
    final secs = _sw.elapsed.inSeconds;
    setState(() => _recording = false);
    if (path == null) return;
    final now = DateTime.now();
    final title =
        '${_kind == 'clase' ? 'Clase' : 'Práctica'} ${now.day}/${now.month} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final all = Store.I.sessions
      ..add({
        'id': now.millisecondsSinceEpoch,
        'title': title,
        'path': path,
        'kind': _kind,
        'date': now.toIso8601String(),
        'seconds': secs,
        'markers': <Map<String, dynamic>>[],
      });
    await Store.I.saveSessions(all);
    if (_kind == 'practica') await Store.I.addMinutes(secs / 60.0);
    await Store.I.markActivity();
    setState(() => _sessions = all.reversed.toList());
  }

  Future<void> _delete(Map<String, dynamic> s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Borrar grabación'),
        content: Text('¿Borrar "${s['title']}"? No se puede deshacer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await File(s['path'] as String).delete();
    } catch (_) {}
    final all = Store.I.sessions..removeWhere((e) => e['id'] == s['id']);
    await Store.I.saveSessions(all);
    setState(() => _sessions = all.reversed.toList());
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'clase', label: Text('Clase'), icon: Icon(Icons.school)),
                  ButtonSegment(
                      value: 'practica', label: Text('Práctica'), icon: Icon(Icons.music_note)),
                ],
                selected: {_kind},
                onSelectionChanged: _recording ? null : (v) => setState(() => _kind = v.first),
              ),
              const SizedBox(height: 14),
              Text(fmt(_sw.elapsedMilliseconds),
                  style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w200)),
              const SizedBox(height: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: _recording ? Colors.redAccent : null,
                    minimumSize: const Size(200, 52)),
                onPressed: _recording ? _stop : _start,
                icon: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
                label: Text(_recording ? 'Parar y guardar' : 'Grabar'),
              ),
              if (_recording)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('La pantalla se mantiene encendida mientras grabas.',
                      style: TextStyle(fontSize: 12)),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Text('Grabaciones', style: Theme.of(context).textTheme.titleMedium),
        if (_sessions.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('Todavía no has grabado nada.')),
          ),
        for (final s in _sessions)
          Card(
            child: ListTile(
              leading: Icon(s['kind'] == 'clase' ? Icons.school : Icons.music_note),
              title: Text(s['title'] as String),
              subtitle: Text(
                  '${fmt((s['seconds'] as int) * 1000)} · ${(s['markers'] as List).length} marcas'),
              trailing: IconButton(
                  icon: const Icon(Icons.delete_outline), onPressed: () => _delete(s)),
              onTap: () async {
                await Navigator.push(
                    context, MaterialPageRoute(builder: (_) => ReviewPage(session: s)));
                setState(() => _sessions = Store.I.sessions.reversed.toList());
              },
            ),
          ),
      ],
    );
  }
}

/// Reproductor de repaso: velocidad, bucle A-B y marcas con nombre.
class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key, required this.session});
  final Map<String, dynamic> session;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  final AudioPlayer _p = AudioPlayer();
  int _pos = 0;
  int _dur = 1;
  bool _playing = false;
  double _speed = 1.0;
  int? _a;
  int? _b;
  bool _loop = false;
  late List<Map<String, dynamic>> _markers;
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _markers = (widget.session['markers'] as List).cast<Map<String, dynamic>>().toList();
    _dur = ((widget.session['seconds'] as int) * 1000).clamp(1, 1 << 30);
    _p.setSource(DeviceFileSource(widget.session['path'] as String));
    _subs.add(_p.onDurationChanged.listen((d) {
      if (d.inMilliseconds > 0) setState(() => _dur = d.inMilliseconds);
    }));
    _subs.add(_p.onPositionChanged.listen((d) {
      _pos = d.inMilliseconds;
      if (_loop && _a != null && _b != null && _pos >= _b!) {
        _p.seek(Duration(milliseconds: _a!));
        _pos = _a!;
      }
      if (mounted) setState(() {});
    }));
    _subs.add(_p.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    }));
    _subs.add(_p.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _p.dispose();
    super.dispose();
  }

  Future<void> _saveMarkers() async {
    final all = Store.I.sessions;
    final i = all.indexWhere((e) => e['id'] == widget.session['id']);
    if (i >= 0) {
      all[i]['markers'] = _markers;
      await Store.I.saveSessions(all);
    }
  }

  Future<void> _seek(int ms) async {
    await _p.seek(Duration(milliseconds: ms.clamp(0, _dur)));
    setState(() => _pos = ms.clamp(0, _dur));
  }

  Future<void> _addMarker() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Marca en ${fmt(_pos)}'),
        content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Ej.: compás 12, afinación, arco')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('Añadir')),
        ],
      ),
    );
    if (name == null) return;
    setState(() {
      _markers.add({'ms': _pos, 'label': name.isEmpty ? 'Marca' : name});
      _markers.sort((x, y) => (x['ms'] as int).compareTo(y['ms'] as int));
    });
    await _saveMarkers();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.session['title'] as String)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Slider(
            min: 0,
            max: _dur.toDouble(),
            value: _pos.clamp(0, _dur).toDouble(),
            onChanged: (v) => setState(() => _pos = v.round()),
            onChangeEnd: (v) => _seek(v.round()),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(fmt(_pos)),
            Text(fmt(_dur)),
          ]),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(iconSize: 34, onPressed: () => _seek(_pos - 10000), icon: const Icon(Icons.replay_10)),
            const SizedBox(width: 8),
            IconButton.filled(
              iconSize: 40,
              onPressed: () => _playing ? _p.pause() : _p.resume(),
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
            ),
            const SizedBox(width: 8),
            IconButton(iconSize: 34, onPressed: () => _seek(_pos + 10000), icon: const Icon(Icons.forward_10)),
          ]),
          const SizedBox(height: 12),
          Text('Velocidad (el tono no cambia)', style: Theme.of(context).textTheme.titleSmall),
          Wrap(spacing: 6, children: [
            for (final s in [0.5, 0.75, 0.9, 1.0, 1.25])
              ChoiceChip(
                label: Text('${s}x'),
                selected: _speed == s,
                onSelected: (_) async {
                  setState(() => _speed = s);
                  await _p.setPlaybackRate(s);
                },
              ),
          ]),
          const Divider(height: 28),
          Text('Bucle A-B', style: Theme.of(context).textTheme.titleSmall),
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton(
                onPressed: () => setState(() => _a = _pos),
                child: Text(_a == null ? 'Marcar A' : 'A ${fmt(_a!)}')),
            OutlinedButton(
                onPressed: () => setState(() => _b = _pos),
                child: Text(_b == null ? 'Marcar B' : 'B ${fmt(_b!)}')),
            FilterChip(
              label: const Text('Repetir'),
              selected: _loop,
              onSelected: (_a != null && _b != null && _b! > _a!)
                  ? (v) {
                      setState(() => _loop = v);
                      if (v) _seek(_a!);
                    }
                  : null,
            ),
            TextButton(
                onPressed: () => setState(() {
                      _a = null;
                      _b = null;
                      _loop = false;
                    }),
                child: const Text('Quitar')),
          ]),
          const Divider(height: 28),
          Row(children: [
            Text('Marcas', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            FilledButton.tonalIcon(
                onPressed: _addMarker, icon: const Icon(Icons.bookmark_add_outlined), label: const Text('Añadir aquí')),
          ]),
          for (var i = 0; i < _markers.length; i++)
            ListTile(
              dense: true,
              leading: const Icon(Icons.bookmark_outline),
              title: Text(_markers[i]['label'] as String),
              subtitle: Text(fmt(_markers[i]['ms'] as int)),
              onTap: () => _seek(_markers[i]['ms'] as int),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () async {
                  setState(() => _markers.removeAt(i));
                  await _saveMarkers();
                },
              ),
            ),
        ],
      ),
    );
  }
}
