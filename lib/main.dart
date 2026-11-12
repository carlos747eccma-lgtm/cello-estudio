import 'package:flutter/material.dart';

import 'screens/cello_screen.dart';
import 'screens/classes_screen.dart';
import 'screens/metronome_screen.dart';
import 'screens/progress_screen.dart';
import 'screens/reading_screen.dart';
import 'screens/tuner_screen.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.init();
  runApp(const CelloEstudioApp());
}

class CelloEstudioApp extends StatelessWidget {
  const CelloEstudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cello Estudio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF8B4A2B),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF8B4A2B),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  static const _titles = ['Afinador', 'Metrónomo', 'Chelo', 'Lectura', 'Clases'];
  static const _icons = [
    Icons.speed,
    Icons.timer,
    Icons.piano,
    Icons.menu_book,
    Icons.mic,
  ];

  @override
  Widget build(BuildContext context) {
    final pages = [
      TunerScreen(active: _index == 0),
      const MetronomeScreen(),
      const CelloScreen(),
      const ReadingScreen(),
      const ClassesScreen(),
    ];
    final wide = MediaQuery.of(context).size.width >= 700;

    final body = IndexedStack(
      index: _index,
      children: [
        for (final p in pages)
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: p),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: [
          IconButton(
            tooltip: 'Progreso',
            icon: const Icon(Icons.insights),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const ProgressScreen())),
          ),
        ],
      ),
      body: SafeArea(
        child: wide
            ? Row(children: [
                NavigationRail(
                  selectedIndex: _index,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  destinations: [
                    for (var i = 0; i < _titles.length; i++)
                      NavigationRailDestination(icon: Icon(_icons[i]), label: Text(_titles[i])),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ])
            : body,
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (var i = 0; i < _titles.length; i++)
                  NavigationDestination(icon: Icon(_icons[i]), label: _titles[i]),
              ],
            ),
    );
  }
}
