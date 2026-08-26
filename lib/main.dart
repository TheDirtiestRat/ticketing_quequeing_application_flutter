import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/menu_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MenuScreen(),
    ),
  );
}
