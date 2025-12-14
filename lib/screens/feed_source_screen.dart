import 'package:flutter/material.dart';
import '../services/feed_service.dart';
import '../models/feed_source.dart';

class FeedSourceScreen extends StatefulWidget {
  const FeedSourceScreen({super.key});

  @override
  State<FeedSourceScreen> createState() => _FeedSourceScreenState();
}

class _FeedSourceScreenState extends State<FeedSourceScreen> {
  final FeedService _feedService = FeedService();
  
  List<FeedSource> _allSources = [];

  Map<String, bool> _preferences = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final sources = await _feedService.loadFeedSources();
      final prefs = await _feedService.getFeedPreferences();
      
      if (mounted) {
        setState(() {
          _allSources = sources;
          _preferences = prefs;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading sources: $e')),
        );
      }
    }
  }

  Future<void> _toggleSource(String url, bool? isChecked) async {
    if (isChecked == null) return;
    
    // Optimistic Update
    // Single Source of Truth: Update service first, then refresh state
    await _feedService.updateFeedEnabledState(url, isChecked);
    
    // Refresh lists from service to reflect changes
    final prefs = await _feedService.getFeedPreferences();

    if (mounted) {
      setState(() {
        _preferences = prefs;
      });
    }
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
          'Choose Sources',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _allSources.length,
              itemBuilder: (context, index) {
                final source = _allSources[index];

                final isEnabled = _feedService.isFeedEnabled(source, _preferences);

                return CheckboxListTile(
                  title: Text(
                    source.title,
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    "${source.category} • ${source.url}",
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  value: isEnabled,
                  activeColor: Colors.indigoAccent,
                  checkColor: Colors.white,
                  onChanged: (bool? value) {
                    _toggleSource(source.url, value);
                  },
                );
              },
            ),
    );
  }
}
