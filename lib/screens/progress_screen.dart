import 'package:flutter/material.dart';

import '../store.dart';
import 'reading_screen.dart';

class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  static const _solfege = ['Do', 'Re', 'Mi', 'Fa', 'Sol', 'La', 'Si'];

  Future<void> _addManual() async {
    final ctrl = TextEditingController(text: '20');
    final v = await showDialog<double>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Añadir práctica'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(suffixText: 'minutos'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, double.tryParse(ctrl.text.replaceAll(',', '.'))),
              child: const Text('Añadir')),
        ],
      ),
    );
    if (v != null && v > 0) {
      await Store.I.addMinutes(v);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mins = Store.I.minutes;
    final now = DateTime.now();
    final days = [for (var i = 6; i >= 0; i--) now.subtract(Duration(days: i))];
    final vals = [for (final d in days) mins[dayKey(d)] ?? 0.0];
    final weekTotal = vals.fold<double>(0, (a, b) => a + b);
    final maxV = vals.fold<double>(1, (a, b) => a > b ? a : b);
    final stats = Store.I.noteStats;
    var ok = 0, total = 0;
    stats.forEach((_, s) {
      ok += s['ok'] ?? 0;
      total += s['total'] ?? 0;
    });

    // Resumen por nota (suma de todas las claves y octavas).
    final perLetter = List.generate(7, (_) => [0, 0]);
    stats.forEach((k, s) {
      final d = int.parse(k.split(':')[1]);
      perLetter[d % 7][0] += s['ok'] ?? 0;
      perLetter[d % 7][1] += s['total'] ?? 0;
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Progreso')),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _addManual, icon: const Icon(Icons.add), label: const Text('Añadir práctica')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            _tile(context, '${Store.I.streak}', 'días seguidos', Icons.local_fire_department),
            _tile(context, weekTotal.round().toString(), 'min esta semana', Icons.timer_outlined),
            _tile(context, total == 0 ? '—' : '${(100 * ok / total).round()}%', 'aciertos lectura',
                Icons.check_circle_outline),
          ]),
          const SizedBox(height: 20),
          Text('Últimos 7 días (minutos)', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(vals[i] > 0 ? vals[i].round().toString() : '',
                            style: Theme.of(context).textTheme.labelSmall),
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          height: 100 * (vals[i] / maxV),
                          decoration: BoxDecoration(
                            color: vals[i] > 0 ? cs.primary : cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(['L', 'M', 'X', 'J', 'V', 'S', 'D'][days[i].weekday - 1],
                            style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text('Lectura de notas', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (total == 0)
            const Text('Aún no has practicado lectura.')
          else
            for (var i = 0; i < 7; i++)
              if (perLetter[i][1] > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    SizedBox(width: 44, child: Text(_solfege[i])),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: perLetter[i][0] / perLetter[i][1],
                        minHeight: 10,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    SizedBox(
                        width: 70,
                        child: Text('  ${perLetter[i][0]}/${perLetter[i][1]}',
                            textAlign: TextAlign.end)),
                  ]),
                ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, String big, String small, IconData icon) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Column(children: [
            Icon(icon),
            const SizedBox(height: 4),
            Text(big, style: Theme.of(context).textTheme.headlineMedium),
            Text(small, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }
}

// Evita aviso de importación sin usar si el tipo no se necesita directamente.
typedef _Unused = StaffNote;
