import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/menu_screen.dart';

import 'package:window_manager/window_manager.dart';

void main() async {

  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MenuScreen(),
    ),
  );
}
