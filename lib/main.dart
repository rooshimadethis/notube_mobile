import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_theme.dart';
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

  final preferences = await SharedPreferences.getInstance();
  runApp(MyApp(themeController: AppThemeController(preferences)));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.themeController});

  final AppThemeController themeController;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeController),
        Provider<AuthService>(create: (_) => AuthService()),
        Provider<FirestoreService>(create: (_) => FirestoreService()),
        StreamProvider<User?>(
          create: (context) => context.read<AuthService>().user,
          initialData: null,
        ),
      ],
      child: Consumer<AppThemeController>(
        builder: (context, theme, child) => MaterialApp(
          title: 'NoTube',
          theme: buildAppTheme(Brightness.light),
          darkTheme: buildAppTheme(Brightness.dark),
          themeMode: theme.mode,
          themeAnimationDuration: Duration.zero,
          home: child,
          debugShowCheckedModeBanner: false,
        ),
        child: const MainScreen(),
      ),
    );
  }
}
