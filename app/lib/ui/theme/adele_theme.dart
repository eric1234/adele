import 'package:flutter/material.dart';

ThemeData buildAdeleTheme() {
  final ColorScheme colors = ColorScheme.fromSeed(
    brightness: Brightness.dark,
    seedColor: const Color(0xFF6CC5A1),
    surface: const Color(0xFF151A1D),
  );

  return ThemeData(
    colorScheme: colors,
    scaffoldBackgroundColor: const Color(0xFF0E1214),
    useMaterial3: true,
  );
}
