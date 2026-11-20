import 'package:flutter/material.dart';

import 'discover_screen.dart';
import 'feed_screen.dart';
import 'home_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  int _sourceRevision = 0;

  void _sourcesChanged() => setState(() => _sourceRevision++);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          FeedScreen(
            sourceRevision: _sourceRevision,
            onSourcesChanged: _sourcesChanged,
          ),
          DiscoverScreen(
            isActive: _selectedIndex == 1,
            sourceRevision: _sourceRevision,
            onSourcesChanged: _sourcesChanged,
          ),
          HomeScreen(isActive: _selectedIndex == 2),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: const Color(0xFF1E293B),
        selectedItemColor: Colors.indigoAccent,
        unselectedItemColor: Colors.grey,
        currentIndex: _selectedIndex,
        onTap: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.menu_book_outlined),
            label: 'Read',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.explore_outlined),
            label: 'Discover',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bookmarks_outlined),
            label: 'Saved sites',
          ),
        ],
      ),
    );
  }
}
