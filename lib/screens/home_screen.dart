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
      // 1. Get local/default items
      List<Alternative> currentItems = await _getLocalAlternatives();

      if (!mounted) return;

      // 2. If logged in, get cloud items and merge
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        try {
          final cloudItems = await context
              .read<FirestoreService>()
              .getUserAlternatives(currentUser.uid)
              .timeout(const Duration(seconds: 5));

          if (cloudItems.isNotEmpty) {
            // Merge: Cloud items override local items with same URL, others are added.
            // Using a Map to deduplicate by URL.
            final Map<String, Alternative> mergedMap = {};
            
            // Add local first
            for (var item in currentItems) {
              if (item.url.isNotEmpty) {
                mergedMap[item.url] = item;
              }
            }

            // Add/Overwrite with cloud
            for (var item in cloudItems) {
              if (item.url.isNotEmpty) {
                mergedMap[item.url] = item;
              }
            }
            
            currentItems = mergedMap.values.toList();
            
            // Update local cache with the merged result so it persists offline
            await _saveToLocal(currentItems);
          }
        } catch (e) {
          print("Firestore load failed (or timed out): $e");
          // Continue with just local items
        }
      }

      if (mounted) {
        setState(() {
          _alternatives = currentItems;
          _isLoading = false;
        });
      }
    } catch (e) {
      print("Critical error in _loadData: $e");
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<List<Alternative>> _getLocalAlternatives() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? localData = prefs.getString('localItems');

      if (localData != null) {
        try {
          final decoded = jsonDecode(localData);
          if (decoded is List && decoded.isNotEmpty) {
             final items = decoded.map((e) => Alternative()..mergeFromJsonMap(e)).toList();
             if (items.isNotEmpty) return items;
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
        final items = decoded.map((e) {
          return Alternative()..mergeFromProto3Json(e);
        }).toList();
        if (items.isNotEmpty) return items;
      }
    } catch (e) {
      print("Error loading local/assets: $e");
    }

    return [];
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
                _loadData();
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
