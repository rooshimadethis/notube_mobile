import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
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
  Timer? _debounceTimer;
  StreamSubscription? _authSubscription;

  @override
  void initState() {
    super.initState();
    _loadData();
    // Listen to auth changes to reload data automatically
    _authSubscription = context.read<AuthService>().user.listen((_) {
      _loadData();
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      // 1. Get local/default items
      List<Alternative> currentItems = await _getLocalAlternatives();
      
      if (mounted) {
        setState(() => _alternatives = currentItems);
      }

      // 2. If logged in, get cloud items and merge
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null && mounted) {
        try {
          final firestoreService = context.read<FirestoreService>();
          final cloudItems = await firestoreService
              .getUserAlternatives(currentUser.uid)
              .timeout(const Duration(seconds: 5));

          if (mounted) {
            // Use the service's merge logic (Cloud wins)
            final mergedItems = firestoreService.mergeAlternatives(currentItems, cloudItems);
            
            // Update state and save to local, but DON'T save to cloud yet
            // (we just loaded from cloud, no need to save back)
            _setAlternativesFromLoad(mergedItems);
          }
        } catch (e) {
          developer.log("Firestore load failed (or timed out): $e");
          // Don't set _hasLoadedFromCloud = true on error
          // This prevents local data from overwriting cloud data
        }
      }
      
      if (mounted) setState(() => _isLoading = false);

    } catch (e) {
      developer.log("Critical error in _loadData: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Sets alternatives from initial load without triggering cloud save
  void _setAlternativesFromLoad(List<Alternative> newItems) {
    if (!mounted) return;
    
    setState(() {
      _alternatives = newItems;
    });
    
    // Save to local storage only
    _saveToLocal(newItems);
  }

  Future<List<Alternative>> _getLocalAlternatives() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? localData = prefs.getString('localItems');

      if (localData != null) {
        try {
          final decoded = jsonDecode(localData);
          if (decoded is List && decoded.isNotEmpty) {
             final items = decoded.map((e) => Alternative()..mergeFromProto3Json(e)).toList();
             if (items.isNotEmpty) return items;
          }
        } catch (e) {
          developer.log("Error parsing local cached data: $e");
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
      developer.log("Error loading local/assets: $e");
    }

    return [];
  }

  Future<void> _saveToLocal(List<Alternative> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String encoded = jsonEncode(items.map((e) => e.writeToJsonMap()).toList());
      await prefs.setString('localItems', encoded);
    } catch (e) {
      developer.log("Error saving to local: $e");
    }
  }

  Map<String, List<Alternative>> _groupAlternatives(List<Alternative> alternatives) {
    final grouped = <String, List<Alternative>>{};
    for (var alt in alternatives) {
      final category = alt.category.isEmpty ? 'Others' : alt.category;
      if (!grouped.containsKey(category)) {
        grouped[category] = [];
      }
      grouped[category]!.add(alt);
    }
    return grouped;
  }

  Future<void> _confirmDelete(Alternative alt) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Delete Alternative?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Are you sure you want to delete "${alt.title}"?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (!mounted) return;

      // Remove from local state
      setState(() {
        _alternatives.removeWhere((a) => a == alt);
      });

      // Update local storage
      await _saveToLocal(_alternatives);

      // Update cloud if logged in
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && mounted) {
        try {
          await context.read<FirestoreService>().removeAlternative(user.uid, alt);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Removed from cloud')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error removing from cloud: $e')),
            );
          }
        }
      }
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
                // _loadData(); // Handled by auth subscription
              },
            )
          else
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                );
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
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 20),
                    children: _groupAlternatives(_alternatives).entries.map((entry) {
                      final category = entry.key;
                      final items = entry.value;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                            child: Text(
                              category.toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ),
                          ...items.map((alt) => AlternativeCard(
                                alternative: alt,
                                onLongPress: () => _confirmDelete(alt),
                              )),
                        ],
                      );
                    }).toList(),
                  ),
                ),
    );
  }
}