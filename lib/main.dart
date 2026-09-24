import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'theme/theme.dart';

void main() {
  runApp(const RunSoloApp());
}

class RunSoloApp extends StatelessWidget {
  const RunSoloApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Run Solo',
      debugShowCheckedModeBanner: false,
      theme: runSoloTheme(),
      darkTheme: runSoloTheme(),
      themeMode: ThemeMode.dark,
      home: const HomeScreen(),
    );
  }
}
