import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'services/auth_service.dart';
import 'services/firestore_service.dart';
import 'screens/main_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // This uses the config from google-services.json / GoogleService-Info.plist

  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (e) {
    // Fail silently if setting display mode fails
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AuthService>(
          create: (_) => AuthService(),
        ),
        Provider<FirestoreService>(
          create: (_) => FirestoreService(),
        ),
        StreamProvider<User?>(
          create: (context) => context.read<AuthService>().user,
          initialData: null,
        ),
      ],
      child: MaterialApp(
        title: 'NoTube',
        theme: ThemeData(
          primarySwatch: Colors.indigo,
          scaffoldBackgroundColor: const Color(0xFF0F172A),
          useMaterial3: true,
        ),
        home: const MainScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
