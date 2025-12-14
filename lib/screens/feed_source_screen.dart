import 'package:flutter/material.dart';
import '../services/feed_service.dart';

class FeedSourceScreen extends StatefulWidget {
  const FeedSourceScreen({super.key});

  @override
  State<FeedSourceScreen> createState() => _FeedSourceScreenState();
}

class _FeedSourceScreenState extends State<FeedSourceScreen> {
  final FeedService _feedService = FeedService();
  
  List<FeedSource> _allSources = [];
  Set<String> _disabledUrls = {};
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
      final disabled = await _feedService.getDisabledUrls();
      
      if (mounted) {
        setState(() {
          _allSources = sources;
          _disabledUrls = disabled;
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

  Future<void> _toggleSource(String url, bool? enabled) async {
    if (enabled == null) return;
    
    setState(() {
      if (enabled) {
        _disabledUrls.remove(url);
      } else {
        _disabledUrls.add(url);
      }
    });
    
    // Save immediately or wait? Saving immediately is safer.
    await _feedService.setDisabledUrls(_disabledUrls);
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
                final isEnabled = !_disabledUrls.contains(source.url);

                return CheckboxListTile(
                  title: Text(
                    source.title,
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    source.url,
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
