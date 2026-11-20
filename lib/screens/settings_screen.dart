import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _gratitudeJournalEnabled = true;
  bool _savingTheme = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _gratitudeJournalEnabled = prefs.getBool('showGratitudeJournal') ?? true;
    });
  }

  Future<void> _toggleGratitudeJournal(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showGratitudeJournal', value);
    if (!mounted) return;
    setState(() {
      _gratitudeJournalEnabled = value;
    });
  }

  Future<void> _toggleTheme(bool dark) async {
    if (_savingTheme) return;
    final theme = context.read<AppThemeController>();
    setState(() => _savingTheme = true);
    try {
      await theme.setDark(dark);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t save the theme. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingTheme = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = context.watch<AppThemeController>().isDark;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Dark mode'),
            subtitle: Text(dark ? 'Dark theme' : 'Light theme'),
            value: dark,
            onChanged: _savingTheme ? null : _toggleTheme,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
          ),
          SwitchListTile(
            title: const Text('Gratitude Journal'),
            subtitle: const Text('Show the gratitude journal on Saved sites'),
            value: _gratitudeJournalEnabled,
            onChanged: _toggleGratitudeJournal,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
          ),
        ],
      ),
    );
  }
}
