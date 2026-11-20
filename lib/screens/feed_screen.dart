import 'package:flutter/material.dart';

import '../models/feed_item.dart';
import '../services/feed_service.dart';
import '../services/reading_list.dart';
import '../widgets/feed_article_card.dart';
import 'feed_source_screen.dart';
import 'settings_screen.dart';
import 'webview_screen.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({
    super.key,
    required this.sourceRevision,
    required this.onSourcesChanged,
  });

  final int sourceRevision;
  final VoidCallback onSourcesChanged;

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

enum _ArticleAction { hide, toggleRead }

enum _ReadAction { switchView, settings }

class _FeedScreenState extends State<FeedScreen> {
  final _feedService = FeedService();
  List<FeedItem> _articles = [];
  List<FeedItem> _readingList = [];
  bool _loading = true;
  bool _showAll = false;
  bool _failed = false;
  int _refreshId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant FeedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sourceRevision != oldWidget.sourceRevision) _load();
  }

  Future<void> _load({bool refresh = false}) async {
    if (!mounted) return;
    final refreshId = ++_refreshId;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final sources = await _feedService.loadFeedSources();
      final preferences = await _feedService.getFeedPreferences();
      final followed = sources.where(
        (source) => _feedService.isFeedEnabled(source, preferences),
      );
      final articles = await _feedService.fetchFeeds(
        followed.toList(),
        forceRefresh: refresh,
      );
      // A source change can start a new refresh before the previous one finishes.
      if (!mounted || refreshId != _refreshId) return;
      final seen = <String>{};
      setState(() {
        _articles = articles.where((item) => seen.add(item.link)).toList();
        _readingList = [];
        _readingList = _nextPicks();
        _loading = false;
      });
    } catch (_) {
      if (!mounted || refreshId != _refreshId) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
      if (_articles.isNotEmpty || _readingList.isNotEmpty) {
        _notify('Couldn’t refresh the reading list.');
      }
    }
  }

  List<FeedItem> _nextPicks() {
    final shown = _readingList.map((item) => item.link).toSet();
    return buildReadingList(
      _articles,
      isRead: (link) =>
          shown.contains(link) || _feedService.isArticleRead(link),
      now: DateTime.now(),
    );
  }

  Future<void> _openSources() async {
    var changed = false;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FeedSourceScreen(onChanged: () => changed = true),
      ),
    );
    if (changed && mounted) widget.onSourcesChanged();
  }

  Future<void> _openArticle(FeedItem item) async {
    final reading = Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => WebViewScreen(url: item.link, title: item.title),
        fullscreenDialog: true,
      ),
    );
    if (!_feedService.isArticleRead(item.link)) {
      await _actOnArticle(item, _ArticleAction.toggleRead);
    }
    await reading;
  }

  Future<void> _setRead(FeedItem item, bool read) async {
    if (read) {
      await _feedService.markArticleAsRead(item.link);
    } else {
      await _feedService.markArticleAsUnread(item.link);
    }
    if (mounted) setState(() {});
  }

  Future<void> _actOnArticle(FeedItem item, _ArticleAction action) async {
    try {
      switch (action) {
        case _ArticleAction.toggleRead:
          await _setRead(item, !_feedService.isArticleRead(item.link));
        case _ArticleAction.hide:
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Hide source?'),
              content: Text(
                'Hide articles from ${item.source}? You can follow it again in Sources.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Hide'),
                ),
              ],
            ),
          );
          if (confirmed != true) return;
          await _feedService.disableFeedSource(item.sourceUrl);
          if (!mounted) return;
          setState(() {
            _readingList.removeWhere(
              (entry) => entry.sourceUrl == item.sourceUrl,
            );
            _articles.removeWhere((entry) => entry.sourceUrl == item.sourceUrl);
          });
          _notify('Hidden ${item.source}');
          widget.onSourcesChanged();
      }
    } catch (_) {
      if (mounted) _notify('Couldn’t update the article or source.');
    }
  }

  void _notify(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final items = _showAll ? _articles : _readingList;
    return Scaffold(
      appBar: AppBar(
        title: Text(_showAll ? 'All articles' : 'Reading list'),
        actions: [
          IconButton(
            tooltip: 'Sources',
            icon: const Icon(Icons.rss_feed),
            onPressed: _openSources,
          ),
          PopupMenuButton<_ReadAction>(
            onSelected: (action) {
              switch (action) {
                case _ReadAction.switchView:
                  setState(() => _showAll = !_showAll);
                case _ReadAction.settings:
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: _ReadAction.switchView,
                child: Text(_showAll ? 'Reading list' : 'All articles'),
              ),
              const PopupMenuItem(
                value: _ReadAction.settings,
                child: Text('Settings'),
              ),
            ],
          ),
        ],
      ),
      body: _loading && items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _load(refresh: true),
              child: items.isEmpty ? _emptyList() : _articleList(items),
            ),
    );
  }

  Widget _emptyList() {
    final message = _failed
        ? 'Couldn’t load articles.'
        : !_showAll && _articles.isNotEmpty
        ? 'You’re caught up.'
        : 'No articles found.';
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 16),
      children: [
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Center(
          child: FilledButton.tonal(
            onPressed: () => _load(refresh: true),
            child: const Text('Refresh'),
          ),
        ),
        Center(
          child: TextButton(
            onPressed: _openSources,
            child: const Text('Browse sources'),
          ),
        ),
      ],
    );
  }

  Widget _articleList(List<FeedItem> items) {
    final more = _showAll || _loading ? <FeedItem>[] : _nextPicks();
    return ListView.builder(
      key: PageStorageKey(_showAll),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
      itemCount: items.length + (_showAll ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == items.length) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: _loading
                  ? const LinearProgressIndicator()
                  : more.isNotEmpty
                  ? FilledButton.tonalIcon(
                      onPressed: () =>
                          setState(() => _readingList.addAll(more)),
                      icon: const Icon(Icons.expand_more),
                      label: const Text('More picks'),
                    )
                  : Text(
                      'End of the reading list',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
            ),
          );
        }
        final item = items[index];
        final read = _feedService.isArticleRead(item.link);
        return Dismissible(
          key: ValueKey(item.link),
          confirmDismiss: (_) async {
            await _actOnArticle(item, _ArticleAction.toggleRead);
            return false;
          },
          background: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: Center(
              child: Text(read ? 'Mark as unread' : 'Mark as read'),
            ),
          ),
          child: _articleCard(item, read),
        );
      },
    );
  }

  Widget _articleCard(FeedItem item, bool read) {
    return FeedArticleCard(
      item: item,
      read: read,
      onOpen: () => _openArticle(item),
      actions: PopupMenuButton<_ArticleAction>(
        tooltip: 'Article options',
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (action) => _actOnArticle(item, action),
        itemBuilder: (_) => [
          PopupMenuItem(
            value: _ArticleAction.toggleRead,
            child: Text(read ? 'Mark as unread' : 'Mark as read'),
          ),
          const PopupMenuItem(
            value: _ArticleAction.hide,
            child: Text('Hide source'),
          ),
        ],
      ),
    );
  }
}
