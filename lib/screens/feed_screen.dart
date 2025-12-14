import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/feed_service.dart';
import '../models/feed_item.dart';
import 'webview_screen.dart';

import 'feed_source_screen.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final FeedService _feedService = FeedService();
  List<FeedItem> _items = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFeeds();
  }

  Future<void> _loadFeeds({bool forceRefresh = false}) async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final sources = await _feedService.getEnabledFeedSources();
      // Pass forceRefresh to service
      final items = await _feedService.fetchFeeds(sources, forceRefresh: forceRefresh);
      
      if (mounted) {
        setState(() {
          _items = items;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading feeds: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Scroller',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) {
              if (value == 'sources') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => const FeedSourceScreen()),
                ).then((_) => _loadFeeds());
              }
            },
            itemBuilder: (BuildContext context) {
              return [
                const PopupMenuItem<String>(
                  value: 'sources',
                  child: Text('Choose sources'),
                ),
              ];
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _loadFeeds(forceRefresh: true),
              child: _items.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              'No articles found.',
                              style: TextStyle(color: Colors.white),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _loadFeeds,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _items.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                            child: Text(
                              '${_items.length} ARTICLES AVAILABLE',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: 13,
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          );
                        }
                        return _buildFeedItem(_items[index - 1]);
                      },
                    ),
            ),
    );
  }

  Widget _buildFeedItem(FeedItem item) {
    if (_feedService.isArticleRead(item.link)) {
      return _buildMiniCard(item);
    }
    return _buildStandardCard(item);
  }

  Widget _buildMiniCard(FeedItem item) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), // Tighter vertical margin
      color: Colors.white.withValues(alpha: 0.05), // Darker/Grayed out
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), // Smaller radius
      child: InkWell(
        onTap: () async {
           // still navigate if they really want to re-read
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => WebViewScreen(
                url: item.link,
                title: item.title,
              ),
              fullscreenDialog: true,
            ),
          );
        },
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline, size: 16, color: Colors.white24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.title,
                  style: const TextStyle(
                    color: Colors.white54, // Dim text
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStandardCard(FeedItem item) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.white.withValues(alpha: 0.1), 
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () async {
          // Mark as read
          await _feedService.markArticleAsRead(item.link);
          
          if (!mounted) return;

          // Navigate to WebView
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => WebViewScreen(
                url: item.link,
                title: item.title,
              ),
              fullscreenDialog: true,
            ),
          );

          // Upon return, just trigger a rebuild so the item turns into a mini card
          if (mounted) {
            setState(() {});
          }
        },
        onLongPress: () {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: const Color(0xFF1E293B), // Matches card/theme color somewhat
              title: const Text('Hide Source', style: TextStyle(color: Colors.white)),
              content: Text(
                'Stop showing articles from "${item.source}"?', 
                style: const TextStyle(color: Colors.white70)
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
                ),
                TextButton(
                  onPressed: () async {
                    // Capture scaffold messenger before async gap
                    final scaffoldMessenger = ScaffoldMessenger.of(context);
                    Navigator.pop(context);
                    
                    await _feedService.disableFeedSource(item.sourceUrl);
                    
                    if (mounted) {
                      setState(() {
                        _items.removeWhere((i) => i.sourceUrl == item.sourceUrl);
                      });
                      
                      scaffoldMessenger.showSnackBar(
                        SnackBar(
                          content: Text('Hidden ${item.source}'),
                          backgroundColor: const Color(0xFF1E293B),
                          action: SnackBarAction(
                            label: 'Undo',
                            onPressed: () {
                              // Re-enable logic would go here
                            },
                          ),
                        ),
                      );
                    }
                  },
                  child: const Text('Hide', style: TextStyle(color: Colors.redAccent)),
                ),
              ],
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${item.source} • ${item.category}',
                      style: TextStyle(
                        color: Colors.indigoAccent[100],
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (item.publishedDate != null)
                      Text(
                        DateFormat.yMMMd().add_jm().format(item.publishedDate!),
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              if (item.imageUrl != null) ...[
                const SizedBox(width: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: item.imageUrl!,
                    width: 80,
                    height: 80,
                    memCacheWidth: 240, // Optimization: Decode only what we need (80 * 3x pixel density)
                    memCacheHeight: 240,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => Container(
                      width: 80,
                      height: 80,
                      color: Colors.white.withValues(alpha: 0.05),
                      child: const Center(child: Icon(Icons.image, color: Colors.grey)),
                    ),
                    errorWidget: (context, url, error) => const SizedBox.shrink(),
                    fadeInDuration: const Duration(milliseconds: 300),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
