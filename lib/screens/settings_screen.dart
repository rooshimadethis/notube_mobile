import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _gratitudeJournalEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      // Default to true as per the requirement to "Add a screen..."
      _gratitudeJournalEnabled = prefs.getBool('showGratitudeJournal') ?? true;
    });
  }

  Future<void> _toggleGratitudeJournal(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showGratitudeJournal', value);
    setState(() {
      _gratitudeJournalEnabled = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Settings',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text(
              'Gratitude Journal',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              'Show gratitude journal on app launch',
              style: TextStyle(color: Colors.white70),
            ),
            value: _gratitudeJournalEnabled,
            onChanged: _toggleGratitudeJournal,
            activeTrackColor: Colors.indigoAccent,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
        ],
      ),
    );
  }
}
