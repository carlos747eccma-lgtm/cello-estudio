import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Guarda los ajustes y el progreso en el móvil.
class Store {
  Store._(this._p);
  static late Store I;

  static Future<void> init() async {
    I = Store._(await SharedPreferences.getInstance());
  }

  final SharedPreferences _p;

  // ---------- minutos de práctica por día ----------
  Map<String, double> get minutes {
    final raw = _p.getString('minutes');
    if (raw == null) return {};
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, (v as num).toDouble()));
  }

  Future<void> addMinutes(double mins, {DateTime? when}) async {
    if (mins <= 0) return;
    final m = minutes;
    final k = dayKey(when ?? DateTime.now());
    m[k] = (m[k] ?? 0) + mins;
    await _p.setString('minutes', jsonEncode(m));
  }

  // ---------- lectura de notas ----------
  /// clave "clave:diatónica" -> {box, ok, total}
  Map<String, Map<String, int>> get noteStats {
    final raw = _p.getString('noteStats');
    if (raw == null) return {};
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(
        k, (v as Map<String, dynamic>).map((a, b) => MapEntry(a, (b as num).toInt()))));
  }

  Future<void> recordAnswer(String key, bool correct) async {
    final all = noteStats;
    final s = all[key] ?? {'box': 0, 'ok': 0, 'total': 0};
    s['total'] = (s['total'] ?? 0) + 1;
    if (correct) {
      s['ok'] = (s['ok'] ?? 0) + 1;
      s['box'] = ((s['box'] ?? 0) + 1).clamp(0, 4);
    } else {
      s['box'] = 0;
    }
    all[key] = s;
    await _p.setString('noteStats', jsonEncode(all));
    final days = activityDays..add(dayKey(DateTime.now()));
    await _p.setStringList('activity', days.toList());
  }

  Set<String> get activityDays => (_p.getStringList('activity') ?? []).toSet();

  Future<void> markActivity() async {
    final days = activityDays..add(dayKey(DateTime.now()));
    await _p.setStringList('activity', days.toList());
  }

  int get streak {
    final days = {...activityDays, ...minutes.entries.where((e) => e.value > 0).map((e) => e.key)};
    var d = DateTime.now();
    if (!days.contains(dayKey(d))) d = d.subtract(const Duration(days: 1));
    var n = 0;
    while (days.contains(dayKey(d))) {
      n++;
      d = d.subtract(const Duration(days: 1));
    }
    return n;
  }

  // ---------- ajustes sencillos ----------
  double getDouble(String k, double def) => _p.getDouble(k) ?? def;
  Future<void> setDouble(String k, double v) => _p.setDouble(k, v);
  int getInt(String k, int def) => _p.getInt(k) ?? def;
  Future<void> setInt(String k, int v) => _p.setInt(k, v);
  String getString(String k, String def) => _p.getString(k) ?? def;
  Future<void> setString(String k, String v) => _p.setString(k, v);
  bool getBool(String k, bool def) => _p.getBool(k) ?? def;
  Future<void> setBool(String k, bool v) => _p.setBool(k, v);

  // ---------- presets del metrónomo ----------
  List<Map<String, dynamic>> get presets {
    final raw = _p.getString('presets');
    if (raw == null) return [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  Future<void> savePresets(List<Map<String, dynamic>> l) =>
      _p.setString('presets', jsonEncode(l));

  // ---------- clases grabadas ----------
  List<Map<String, dynamic>> get sessions {
    final raw = _p.getString('sessions');
    if (raw == null) return [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  Future<void> saveSessions(List<Map<String, dynamic>> l) =>
      _p.setString('sessions', jsonEncode(l));
}
