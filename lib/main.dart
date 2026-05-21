import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'screens/main_navigation_screen.dart';
import 'services/memory_guard.dart';
import 'services/notification_service.dart';
import 'services/objectbox_manager.dart';
import 'services/usage_tracking_service.dart';

late ObjectBox objectBox;
late UsageTrackingService usageTracker;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  objectBox = await ObjectBox.create();
  usageTracker = UsageTrackingService(objectBox.store);

  // Load Lean Memory Mode preference. On mobile this defaults ON so the
  // first run on a 6 GB device (iPhone 13 Pro Max, mid-range Android)
  // already runs with tighter token budgets.
  await MemoryGuard.instance.initialize();

  await FlutterGemma.initialize(webStorageMode: WebStorageMode.cacheApi);

  runApp(const ChatApp());
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GenUI Study Hub',
      debugShowCheckedModeBanner: false,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.white),
          bodyMedium: TextStyle(color: Colors.white),
        ),
      ),
      themeMode: ThemeMode.dark,
      home: const MainNavigationScreen(),
    );
  }
}
