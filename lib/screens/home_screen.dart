import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../models/alternative.dart';
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
    setState(() => _isLoading = true);

    final user = context.read<AuthService>().user;
    // We need to listen to the user stream or check current user
    final currentUser = FirebaseAuth.instance.currentUser;

    if (currentUser != null) {
      // Load from Firestore
      final cloudItems = await context.read<FirestoreService>().getUserAlternatives(currentUser.uid);
      if (cloudItems.isNotEmpty) {
        setState(() {
          _alternatives = cloudItems;
          _isLoading = false;
        });
        // Cache to local storage
        _saveToLocal(cloudItems);
        return;
      }
    }

    // Fallback to local storage or defaults
    _loadLocal();
  }

  Future<void> _loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final String? localData = prefs.getString('localItems');

    if (localData != null) {
      final List<dynamic> decoded = jsonDecode(localData);
      setState(() {
        _alternatives = decoded.map((e) => Alternative.fromJson(e)).toList();
        _isLoading = false;
      });
    } else {
      // Load defaults (hardcoded for now as we can't easily read assets without setup)
      // In a real app, we'd load from assets/alternatives.json
      setState(() {
        _alternatives = [
          Alternative(title: "Kindle Cloud Reader", url: "https://read.amazon.com", description: "Read your kindle books directly in the browser.", category: "books"),
          Alternative(title: "Unsplash", url: "https://unsplash.com", description: "Beautiful, free images and photos that you can download and use for any project.", category: "photography"),
          Alternative(title: "GitHub", url: "https://github.com", description: "Where the world builds software.", category: "software"),
        ];
        _isLoading = false;
      });
    }
  }

  Future<void> _saveToLocal(List<Alternative> items) async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(items.map((e) => e.toJson()).toList());
    await prefs.setString('localItems', encoded);
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<User?>();

    // Reload data if user logs in/out
    // Note: This is a simple way to trigger reload. In a production app, use a more robust state management.
    if (user != null && _alternatives.isEmpty && !_isLoading) {
       _loadData();
    }

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
