import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:notube_shared/alternative.pb.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../widgets/alternative_card.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Alternative> _alternatives = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      // Check current user
      final currentUser = FirebaseAuth.instance.currentUser;

      if (currentUser != null) {
        // Load from Firestore with timeout
        try {
          final cloudItems = await context
              .read<FirestoreService>()
              .getUserAlternatives(currentUser.uid)
              .timeout(const Duration(seconds: 5));
              
          if (cloudItems.isNotEmpty) {
            if (mounted) {
              setState(() {
                _alternatives = cloudItems;
                _isLoading = false;
              });
            }
            // Cache to local storage
            _saveToLocal(cloudItems);
            return;
          }
        } catch (e) {
          print("Firestore load failed (or timed out): $e");
          // Continue to local load
        }
      }

      // Fallback to local storage or defaults
      await _loadLocal();
    } catch (e) {
      print("Critical error in _loadData: $e");
      // Even if everything fails, stop loading
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? localData = prefs.getString('localItems');

      if (localData != null) {
        try {
          final decoded = jsonDecode(localData);
          if (decoded is List && decoded.isNotEmpty) {
             final items = decoded.map((e) => Alternative()..mergeFromJsonMap(e)).toList();
             if (items.isNotEmpty) {
               if (mounted) {
                 setState(() {
                   _alternatives = items;
                   _isLoading = false;
                 });
               }
               return;
             }
          }
        } catch (e) {
          print("Error parsing local cached data: $e");
        }
      }

      // Load defaults from package assets
      final String jsonString = await rootBundle.loadString(
          'packages/notube_shared/assets/default_alternatives.json');
      final decoded = jsonDecode(jsonString);
      if (decoded is List && decoded.isNotEmpty) {
          final items = decoded.map((e) => Alternative()..mergeFromJsonMap(e)).toList();
          if (items.isNotEmpty) {
            if (mounted) {
              setState(() {
                _alternatives = items;
                _isLoading = false;
              });
            }
            return;
          }
      }
    } catch (e) {
      print("Error loading local/assets: $e");
      // Fall through to hardcoded defaults
    }

    // Fallback to hardcoded defaults if asset load fails
    try {
      final List<Alternative> hardcodedDefaults = [
        Alternative()
          ..title = 'Unsplash'
          ..description = 'Beautiful, free images and photos.'
          ..url = 'https://unsplash.com'
          ..category = 'photography',
        Alternative()
          ..title = 'Audible'
          ..description = 'Listen to audiobooks and podcasts.'
          ..url = 'https://www.audible.com'
          ..category = 'books',
        Alternative()
          ..title = 'GitHub'
          ..description = 'Where the world builds software.'
          ..url = 'https://github.com'
          ..category = 'software',
      ];

      if (mounted) {
        setState(() {
          _alternatives = hardcodedDefaults;
          _isLoading = false;
        });
      }
    } catch (e) {
      print("Critical error setting hardcoded defaults: $e");
      if (mounted) {
        setState(() {
          _isLoading = false;
          // _alternatives remains empty, triggering the empty state UI
        });
      }
    }
  }

  Future<void> _saveToLocal(List<Alternative> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String encoded = jsonEncode(items.map((e) => e.writeToJsonMap()).toList());
      await prefs.setString('localItems', encoded);
    } catch (e) {
      print("Error saving to local: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<User?>();

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Slate 900
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'NoTube',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        actions: [
          if (user != null)
            IconButton(
              icon: const Icon(Icons.logout, color: Colors.white),
              onPressed: () {
                context.read<AuthService>().signOut();
                setState(() {
                  _alternatives = []; // Clear data to force reload defaults
                });
                _loadLocal();
              },
            )
          else
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                ).then((_) => _loadData());
              },
              child: const Text('Sign In', style: TextStyle(color: Colors.indigoAccent)),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _alternatives.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'No alternatives found.',
                        style: TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadData,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadData,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 20),
                    itemCount: _alternatives.length,
                    itemBuilder: (context, index) {
                      return AlternativeCard(alternative: _alternatives[index]);
                    },
                  ),
                ),
    );
  }
}
