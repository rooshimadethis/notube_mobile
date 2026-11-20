import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppThemeController extends ChangeNotifier {
  AppThemeController(this._preferences)
    : _isDark = _preferences.getBool(_key) ?? false;

  static const _key = 'useDarkTheme';
  final SharedPreferences _preferences;
  bool _isDark;

  bool get isDark => _isDark;
  ThemeMode get mode => _isDark ? ThemeMode.dark : ThemeMode.light;

  Future<void> setDark(bool value) async {
    if (value == _isDark) return;
    // Persist before updating the app so a failed write doesn't advertise a
    // preference that will disappear on the next launch.
    if (!await _preferences.setBool(_key, value)) {
      throw StateError('Couldn’t save the theme.');
    }
    _isDark = value;
    notifyListeners();
  }
}

ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF334E73),
        brightness: brightness,
      ).copyWith(
        surface: dark ? const Color(0xFF0F172A) : Colors.white,
        onSurface: dark ? const Color(0xFFF0F4FA) : const Color(0xFF181818),
        onSurfaceVariant: dark
            ? const Color(0xFFBCC8D9)
            : const Color(0xFF464646),
        surfaceContainerLow: dark ? const Color(0xFF1B263B) : Colors.white,
        surfaceContainer: dark
            ? const Color(0xFF1E293B)
            : const Color(0xFFF3F3F3),
        surfaceContainerHigh: dark
            ? const Color(0xFF25324B)
            : const Color(0xFFECECEC),
        outlineVariant: dark
            ? const Color(0xFF374459)
            : const Color(0xFFC1C1C1),
      );
  return ThemeData(
    colorScheme: colors,
    useMaterial3: true,
    scaffoldBackgroundColor: colors.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: colors.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: colors.surfaceContainer,
      selectedItemColor: colors.primary,
      unselectedItemColor: colors.onSurfaceVariant,
    ),
  );
}
