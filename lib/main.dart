import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/services/notification_service.dart';
import 'features/alerts/alerts_screen.dart';
import 'firebase_options.dart';

Future<void> main() async {
  // Required before any plugin work happens ahead of runApp.
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Must be registered here, before runApp: when a push wakes the app from a
  // killed state, Android runs this handler in its own isolate starting from
  // main(), and the handler has to already be attached by then.
  FirebaseMessaging.onBackgroundMessage(handleBackgroundMessage);

  // ProviderScope is Riverpod's root; every provider the detection and alerts
  // features declare is resolved from here.
  runApp(const ProviderScope(child: MainApp()));
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bags',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFB3261E),
        useMaterial3: true,
      ),
      home: const AlertsScreen(),
    );
  }
}
