import 'package:flutter/material.dart';

ThemeData buildAdeleTheme() {
  final ColorScheme colors = ColorScheme.fromSeed(
    brightness: Brightness.light,
    seedColor: const Color(0xFF6CC5A1),
  );

  return ThemeData(colorScheme: colors, useMaterial3: true);
}
