import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notube_mobile/app_theme.dart';
import 'package:notube_mobile/screens/settings_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('defaults to light and saves either choice from Settings', (
    tester,
  ) async {
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;
    addTearDown(
      tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
    );
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final theme = AppThemeController(preferences);
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: theme,
        child: Consumer<AppThemeController>(
          builder: (context, controller, child) => MaterialApp(
            theme: buildAppTheme(Brightness.light),
            darkTheme: buildAppTheme(Brightness.dark),
            themeMode: controller.mode,
            themeAnimationDuration: Duration.zero,
            home: child,
          ),
          child: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.widgetWithText(SwitchListTile, 'Dark mode');
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(Theme.of(tester.element(toggle)).brightness, Brightness.light);
    expect(
      Theme.of(tester.element(toggle)).scaffoldBackgroundColor,
      Colors.white,
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(Theme.of(tester.element(toggle)).brightness, Brightness.dark);
    await preferences.reload();
    final restoredDark = AppThemeController(preferences);
    expect(restoredDark.mode, ThemeMode.dark);
    restoredDark.dispose();

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await preferences.reload();
    final restoredLight = AppThemeController(preferences);
    expect(restoredLight.mode, ThemeMode.light);
    restoredLight.dispose();
  });
}
