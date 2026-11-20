import 'package:flutter/material.dart';

import '../models/feed_source.dart';
import '../services/feed_service.dart';

class FeedSourceScreen extends StatefulWidget {
  const FeedSourceScreen({super.key, required this.onChanged});

  final VoidCallback onChanged;

  @override
  State<FeedSourceScreen> createState() => _FeedSourceScreenState();
}

class _FeedSourceScreenState extends State<FeedSourceScreen> {
  final _feedService = FeedService();
  List<FeedSource> _sources = [];
  Map<String, bool> _preferences = {};
  bool _loading = true;
  bool _saving = false;
  bool _failed = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final sources = await _feedService.loadFeedSources();
      final preferences = await _feedService.getFeedPreferences();
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _preferences = preferences;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _save(Future<void> Function() change) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await change();
      widget.onChanged();
      if (mounted) await _reload();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t save your source. Try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addSource() async {
    final source = await showDialog<FeedSource>(
      context: context,
      builder: (_) => _FindFeedDialog(service: _feedService),
    );
    if (source == null || !mounted) return;
    await _save(() => _feedService.followSource(source));
  }

  @override
  Widget build(BuildContext context) {
    // The reading screen reloads on return, so let the source write finish first.
    return PopScope(
      canPop: !_saving,
      child: Theme(
        data: ThemeData.dark(useMaterial3: true),
        child: Scaffold(
          backgroundColor: const Color(0xFF0F172A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0F172A),
            title: const Text('Sources'),
            actions: [
              TextButton.icon(
                onPressed: _saving ? null : _addSource,
                icon: const Icon(Icons.add),
                label: const Text('Add source'),
              ),
            ],
          ),
          body: _buildSources(),
        ),
      ),
    );
  }

  Widget _buildSources() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed) {
      return Center(
        child: TextButton(
          onPressed: _reload,
          child: const Text('Couldn’t load sources. Retry'),
        ),
      );
    }
    final suggested = <FeedSource>[];
    final followed = <FeedSource>[];
    final other = <FeedSource>[];
    for (final source in _sources) {
      final searchable = '${source.title} ${source.category} ${source.url}'
          .toLowerCase();
      if (!searchable.contains(_query)) continue;
      if (_feedService.isFeedEnabled(source, _preferences)) {
        followed.add(source);
      } else if (_feedService.isSuggestedSource(source, _preferences)) {
        suggested.add(source);
      } else {
        other.add(source);
      }
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            onChanged: (query) =>
                setState(() => _query = query.trim().toLowerCase()),
            decoration: const InputDecoration(
              hintText: 'Search sources',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (suggested.isEmpty && followed.isEmpty && other.isEmpty)
                const ListTile(title: Text('No matching sources')),
              ..._section('Suggested for discovery', suggested, false),
              ..._section('Following', followed, true),
              ..._section('More sources', other, false),
            ],
          ),
        ),
      ],
    );
  }

  Iterable<Widget> _section(
    String title,
    List<FeedSource> sources,
    bool followed,
  ) sync* {
    if (sources.isEmpty) return;
    yield Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFFAFC8F5),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    for (final source in sources) {
      yield SwitchListTile(
        key: ValueKey(source.url),
        title: Text(source.title),
        subtitle: Text(source.category),
        value: followed,
        onChanged: _saving
            ? null
            : (follow) => _save(
                () => _feedService.updateFeedEnabledState(source.url, follow),
              ),
      );
    }
  }
}

class _FindFeedDialog extends StatefulWidget {
  const _FindFeedDialog({required this.service});

  final FeedService service;

  @override
  State<_FindFeedDialog> createState() => _FindFeedDialogState();
}

class _FindFeedDialogState extends State<_FindFeedDialog> {
  final _address = TextEditingController();
  List<FeedSource> _results = [];
  bool _searching = false;
  String? _message;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    if (_searching) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _message = null;
      _results = [];
    });
    try {
      final results = await widget.service.discoverFeeds(_address.text);
      if (!mounted) return;
      setState(() {
        _results = results;
        if (results.isEmpty) {
          _message = 'No feed found. Try a direct RSS or Atom URL.';
        }
        _searching = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error is FormatException
            ? error.message
            : 'Couldn’t look up feeds. Try again.';
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Add a source'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _address,
              enabled: !_searching,
              autofocus: true,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _find(),
              decoration: const InputDecoration(
                labelText: 'Website or feed URL',
              ),
            ),
            if (_searching) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!),
            ],
            for (final source in _results)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(source.title),
                subtitle: Text(
                  source.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.add),
                onTap: () => Navigator.pop(context, source),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _searching ? null : _find,
          child: const Text('Find feeds'),
        ),
      ],
    );
  }
}
