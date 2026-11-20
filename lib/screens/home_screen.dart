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
import 'gratitude_journal_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.isActive = true});

  final bool isActive;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<Alternative> _alternatives = [];
  bool _isLoading = true;
  int _loadRevision = 0;
  Timer? _debounceTimer;
  StreamSubscription? _authSubscription;
  StreamSubscription? _intentDataStreamSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The auth stream emits the initial state as well as subsequent changes.
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkGratitudeJournal();
    });
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _checkGratitudeJournal();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkGratitudeJournal();
    }
  }

  Future<void> _checkGratitudeJournal() async {
    // Only show if HomeScreen is the current top route (don't stack if Settings or Journal already open)
    // The indexed stack keeps Home mounted while Read owns the visible tab.
    if (!mounted || !widget.isActive || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final show = prefs.getBool('showGratitudeJournal') ?? true;
    
    if (!show) return;

    final lastShownMillis = prefs.getInt('lastGratitudeShownTime');
    final now = DateTime.now();
    
    bool shouldShow = false;
    if (lastShownMillis == null) {
      shouldShow = true;
    } else {
      final lastShown = DateTime.fromMillisecondsSinceEpoch(lastShownMillis);
      if (now.difference(lastShown).inHours >= 1) {
        shouldShow = true;
      }
    }

    if (shouldShow && mounted && widget.isActive &&
        ModalRoute.of(context)?.isCurrent == true) {
      await prefs.setInt('lastGratitudeShownTime', now.millisecondsSinceEpoch);
      
      if (!mounted || !widget.isActive || ModalRoute.of(context)?.isCurrent != true) {
        return;
      }

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const GratitudeJournalScreen(),
          fullscreenDialog: true,
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.cancel();
    _intentDataStreamSubscription?.cancel();
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    final revision = ++_loadRevision;
    final auth = context.read<AuthService>();
    final userId = auth.currentUser?.uid;
    // An older account's response must not update this screen or its local copy.
    bool isCurrentLoad() =>
        mounted &&
        revision == _loadRevision &&
        auth.currentUser?.uid == userId;

    setState(() => _isLoading = true);
    try {
      final local = await _getLocalAlternatives();
      if (!mounted || !isCurrentLoad()) return;
      setState(() => _alternatives = local);
      if (userId == null) return;

      final firestore = context.read<FirestoreService>();
      final prefs = await SharedPreferences.getInstance();
      var cloud = await firestore
          .getUserAlternatives(userId)
          .timeout(const Duration(seconds: 5));
      if (!isCurrentLoad()) return;

      // An explicitly empty cloud list represents a real deletion.
      cloud ??= await firestore.initializeUserAlternatives(userId, local);
      if (!isCurrentLoad()) return;
      if (prefs.getString('lastSyncedUserId') != userId &&
          !_areAlternativesEqual(local, cloud)) {
        final merge = await _showSyncDialog();
        if (!isCurrentLoad() || merge == null) return;
        if (merge) {
          cloud = await firestore.mergeUserAlternatives(userId, local);
        }
      }
      if (!isCurrentLoad()) return;

      final synced = cloud;
      await _saveToLocal(synced, failOnError: true, preferences: prefs);
      if (!isCurrentLoad()) return;
      setState(() => _alternatives = synced);
      await prefs.setString('lastSyncedUserId', userId);
    } catch (error) {
      developer.log('Saved-site load failed: $error');
      if (mounted && isCurrentLoad()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to sync with cloud. Using local data.')),
        );
      }
    } finally {
      if (isCurrentLoad()) setState(() => _isLoading = false);
    }
  }

  Future<bool?> _showSyncDialog() => showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Sync Conflict'),
      content: const Text(
        'Cloud data found. How would you like to proceed?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(
            'Use cloud data',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Merge cloud and local data'),
        ),
      ],
    ),
  );

  Future<List<Alternative>> _getLocalAlternatives() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? localData = prefs.getString('localItems');

      if (localData != null) {
        try {
          final decoded = jsonDecode(localData);
          if (decoded is List) {
            return decoded
                .map((e) => Alternative()..mergeFromProto3Json(e))
                .toList();
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

  Future<void> _saveToLocal(
    List<Alternative> items, {
    bool failOnError = false,
    SharedPreferences? preferences,
  }) async {
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      // Use custom map conversion to ensure field names (not proto tags)
      final String encoded = jsonEncode(items.map(_alternativeToMap).toList());
      if (!await prefs.setString('localItems', encoded)) {
        throw StateError('Couldn’t save local sites.');
      }
      developer.log("Saved ${items.length} items to local storage");
    } catch (e) {
      developer.log("Error saving to local: $e");
      if (failOnError) rethrow;
    }
  }

  /// Convert Alternative to Map with explicit field names
  Map<String, dynamic> _alternativeToMap(Alternative a) {
    return {
      'title': a.title,
      'url': a.url,
      'description': a.description,
      'category': a.category,
      'bypassPaywall': a.bypassPaywall,
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
        title: const Text('Delete Alternative?'),
        content: Text(
          'Are you sure you want to delete "${alt.title}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
              const SnackBar(content: Text('Saved')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error saving to cloud: $e')),
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
      appBar: AppBar(
        title: const Text(
          'NoTube',
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
          if (user != null)
            IconButton(
              icon: const Icon(Icons.logout),
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
              child: const Text('Sign In'),
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
        child: const Icon(Icons.add),
      ),
    );
  }
}
