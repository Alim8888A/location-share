import 'package:flutter/material.dart';

import 'screens/login_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LocationShareApp());
}

class LocationShareApp extends StatelessWidget {
  const LocationShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    final seed = const Color(0xFF2952E3);
    return MaterialApp(
      title: '位置共享',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
      ),
      home: const LoginScreen(),
    );
  }
}
