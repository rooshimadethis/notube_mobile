import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:notube_shared/alternative.pb.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../widgets/alternative_card.dart';
import '../widgets/add_alternative_dialog.dart';
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
  StreamSubscription? _intentDataStreamSubscription;

  @override
  void initState() {
    super.initState();
    _loadData();
    // Listen to auth changes. If user logs in, this triggers _loadData which handles the sync flow.
    _authSubscription = context.read<AuthService>().user.listen((_) {
      _loadData();
    });
    
    // Listen for shared text (URLs)
    _intentDataStreamSubscription = ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> value) {
      if (mounted && value.isNotEmpty) {
        // For text/url shares, the content is often in the path
        final item = value.first;
        _handleSharedText(item.path, item.message);
      }
    }, onError: (err) {
      developer.log("getLinkStream error: $err");
    });

    // Handle initial shared text
    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> value) {
      if (value.isNotEmpty && mounted) {
        final item = value.first;
        _handleSharedText(item.path, item.message);
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _intentDataStreamSubscription?.cancel();
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

      // 2. If logged in, initiate sync flow (Push local if cloud empty, or prompt user)
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null && mounted) {
        try {
          final firestoreService = context.read<FirestoreService>();
          final cloudItems = await firestoreService
              .getUserAlternatives(currentUser.uid)
              .timeout(const Duration(seconds: 5));

          final prefs = await SharedPreferences.getInstance();
          final lastSyncedUserId = prefs.getString('lastSyncedUserId');
          final isFirstSync = lastSyncedUserId != currentUser.uid;

          if (mounted) {
            if (cloudItems.isEmpty) {
              // Case 1: Cloud is empty -> Push local items to cloud automatically
              await firestoreService.saveUserAlternatives(currentUser.uid, currentItems);
              await prefs.setString('lastSyncedUserId', currentUser.uid);
              developer.log("Pushed local items to empty cloud");
            } else if (isFirstSync && !_areAlternativesEqual(currentItems, cloudItems)) {
              // Case 2: First time sync with conflict -> Show Dialog
              await _showSyncDialog(currentItems, cloudItems, firestoreService, currentUser.uid);
            } else {
              // Case 3: Subsequent sync or identical -> Use cloud
              developer.log("Auto-syncing from cloud (isFirstSync: $isFirstSync)");
              _setAlternativesFromLoad(cloudItems);
              await prefs.setString('lastSyncedUserId', currentUser.uid);
            }
          }
        } catch (e) {
          developer.log("Firestore load failed (or timed out): $e");
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Failed to sync with cloud. Using local data.')),
            );
          }
        }
      }
      
      if (mounted) setState(() => _isLoading = false);

    } catch (e) {
      developer.log("Critical error in _loadData: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }



  Future<void> _showSyncDialog(
    List<Alternative> local,
    List<Alternative> cloud,
    FirestoreService firestoreService,
    String userId,
  ) async {
    // If lists are identical, no need to ask - just ensure local is synced
    if (_areAlternativesEqual(local, cloud)) {
      developer.log("Local and cloud are already in sync, no dialog needed");
      _setAlternativesFromLoad(cloud); // Ensure local storage is updated
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lastSyncedUserId', userId);
      return;
    }
    
    await showDialog(
      context: context,
      barrierDismissible: false, // Force choice
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Sync Conflict', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Cloud data found. How would you like to proceed?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              // Overwrite Local: Use cloud items
              _setAlternativesFromLoad(cloud);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('lastSyncedUserId', userId);
            },
            child: const Text('Use cloud data', style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              // Merge: Cloud wins conflicts, new local items added
              final merged = firestoreService.mergeAlternatives(local, cloud);
              _setAlternativesFromLoad(merged);
              // Save merged back to cloud
              await firestoreService.saveUserAlternatives(userId, merged);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('lastSyncedUserId', userId);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.indigoAccent),
            child: const Text('Merge cloud and local data', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  /// Sets alternatives from initial load without triggering cloud save
  void _setAlternativesFromLoad(List<Alternative> newItems) {
    if (!mounted) return;
    
    setState(() {
      _alternatives = newItems;
    });
    
    // Save to local storage (Source of truth for offline/not logged in)
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
             if (items.isNotEmpty) {
               developer.log("Loaded ${items.length} items from local storage");
               return items;
             }
          }
        } catch (e) {
          developer.log("Error parsing local cached data: $e");
          // Clear corrupted local storage
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove('localItems');
            developer.log("Cleared corrupted local storage");
          } catch (clearError) {
            developer.log("Error clearing local storage: $clearError");
          }
        }
      } else {
        developer.log("No local data found, will load defaults");
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
      // Use custom map conversion to ensure field names (not proto tags)
      final String encoded = jsonEncode(items.map(_alternativeToMap).toList());
      await prefs.setString('localItems', encoded);
      developer.log("Saved ${items.length} items to local storage");
    } catch (e) {
      developer.log("Error saving to local: $e");
    }
  }

  /// Convert Alternative to Map with explicit field names
  Map<String, dynamic> _alternativeToMap(Alternative a) {
    return {
      'title': a.title,
      'url': a.url,
      'description': a.description,
      'category': a.category,
    };
  }

  /// Compares two lists of alternatives to check if they're identical
  bool _areAlternativesEqual(List<Alternative> list1, List<Alternative> list2) {
    if (list1.length != list2.length) return false;
    
    // Create sets of identifiers (URL or title) for comparison
    final set1 = list1.map((a) => a.url.isNotEmpty ? a.url : a.title).toSet();
    final set2 = list2.map((a) => a.url.isNotEmpty ? a.url : a.title).toSet();
    
    return set1.length == set2.length && set1.containsAll(set2);
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

      // Remove from local state - compare by URL/title, not object equality
      final beforeCount = _alternatives.length;
      setState(() {
        _alternatives.removeWhere((a) {
          // Compare by URL if both have it, otherwise by title
          if (alt.url.isNotEmpty && a.url.isNotEmpty) {
            return a.url == alt.url;
          }
          return a.title == alt.title;
        });
      });
      final afterCount = _alternatives.length;
      developer.log("Deleted item: before=$beforeCount, after=$afterCount, removed=${beforeCount - afterCount}");

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

  void _handleSharedText(String text, [String? subject]) {
    developer.log("Shared text received: $text, subject: $subject");
    String url = text;
    String title = subject ?? '';
    
    // Attempt to extract URL if mixed with text
    final urlRegExp = RegExp(r'https?://\S+');
    final match = urlRegExp.firstMatch(text);
    if (match != null) {
      url = match.group(0)!;
      
      // If we didn't get a specific subject, try to parse one from the text
      if (title.isEmpty) {
        // Use remaining text as title, cleaning up common separators
        title = text.replaceAll(url, '').trim();
        if (title.endsWith('-')) title = title.substring(0, title.length - 1).trim();
        if (title.endsWith('|')) title = title.substring(0, title.length - 1).trim();
      }
    }
    
    _showAddDialog(initialUrl: url, initialTitle: title.isNotEmpty ? title : null);
  }

  Future<void> _showAddDialog({String? initialUrl, String? initialTitle}) async {
    final result = await showDialog<Alternative>(
      context: context,
      builder: (context) => AddAlternativeDialog(
        initialUrl: initialUrl,
        initialTitle: initialTitle,
      ),
    );

    if (result != null && mounted) {
      // Add to local state
      setState(() {
        _alternatives.insert(0, result);
      });

      // Update local storage
      await _saveToLocal(_alternatives);

      // Update cloud if logged in
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && mounted) {
        try {
          await context.read<FirestoreService>().addAlternative(user.uid, result);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Added to cloud')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error adding to cloud: $e')),
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
                    padding: const EdgeInsets.only(bottom: 20, top: 16),
                    children: (List<Alternative>.from(_alternatives)..shuffle())
                        .map((alt) => AlternativeCard(
                              alternative: alt,
                              onLongPress: () => _confirmDelete(alt),
                            ))
                        .toList(),
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDialog,
        backgroundColor: Colors.indigoAccent,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}