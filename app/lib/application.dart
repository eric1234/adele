import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_desktop/ui/theme/adele_theme.dart';
import 'package:flutter/material.dart';

final class AdeleApplication extends StatelessWidget {
  const AdeleApplication({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const AdeleShell(),
      theme: buildAdeleTheme(),
      title: 'ADELE',
    );
  }
}
