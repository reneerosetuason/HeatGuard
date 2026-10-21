import 'package:flutter/material.dart';

import 'screens/auth_gate.dart';
import 'theme/heatguard_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HeatGuardApp());
}

class HeatGuardApp extends StatelessWidget {
  const HeatGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HeatGuard',
      debugShowCheckedModeBanner: false,
      theme: buildHeatGuardTheme(),
      home: const AuthGate(),
    );
  }
}
