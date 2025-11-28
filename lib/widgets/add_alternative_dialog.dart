import 'package:flutter/material.dart';
import 'package:notube_shared/alternative.pb.dart';
import 'package:http/http.dart' as http;
import '../services/groq_service.dart';

class AddAlternativeDialog extends StatefulWidget {
  final String? initialUrl;
  final String? initialTitle;

  const AddAlternativeDialog({
    super.key,
    this.initialUrl,
    this.initialTitle,
  });

  @override
  State<AddAlternativeDialog> createState() => _AddAlternativeDialogState();
}

class _AddAlternativeDialogState extends State<AddAlternativeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _titleController = TextEditingController();
  String _category = 'custom';
  bool _isGenerating = false;
  final _groqService = GroqService();
  bool _isFetchingTitle = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialUrl != null) {
      _urlController.text = widget.initialUrl!;
    }
    if (widget.initialTitle != null && widget.initialTitle!.isNotEmpty) {
      _titleController.text = widget.initialTitle!;
    } else if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      _fetchTitle();
    }
  }

  Future<void> _fetchTitle() async {
    if (!mounted) return;
    setState(() => _isFetchingTitle = true);
    
    try {
      // Basic header to look like a browser (helps with some sites)
      final response = await http.get(
        Uri.parse(widget.initialUrl!),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        // Simple regex to find <title> tag
        final match = RegExp(r'<title>(.*?)</title>', caseSensitive: false, dotAll: true)
            .firstMatch(response.body);
        
        if (match != null && match.group(1) != null) {
          final title = match.group(1)!.trim()
              .replaceAll(RegExp(r'&amp;'), '&')
              .replaceAll(RegExp(r'&lt;'), '<')
              .replaceAll(RegExp(r'&gt;'), '>')
              .replaceAll(RegExp(r'&quot;'), '"')
              .replaceAll(RegExp(r'&#39;'), "'");

          if (mounted && _titleController.text.isEmpty) {
            setState(() {
              _titleController.text = title;
            });
          }
        }
      }
    } catch (e) {
      // Silently fail if title fetch fails
    } finally {
      if (mounted) setState(() => _isFetchingTitle = false);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isGenerating = true);

      try {
        final title = _titleController.text.trim();
        final url = _urlController.text.trim();
        
        // Ensure URL has scheme
        final processedUrl = url.startsWith('http') ? url : 'https://$url';

        final description = await _groqService.generateDescription(title, processedUrl);

        final alternative = Alternative()
          ..title = title
          ..url = processedUrl
          ..description = description
          ..category = _category;

        if (mounted) {
          Navigator.pop(context, alternative);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')),
          );
        }
      } finally {
        if (mounted) {
          setState(() => _isGenerating = false);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      title: const Text('Add Alternative', style: TextStyle(color: Colors.white)),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _titleController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Site Name',
                  labelStyle: const TextStyle(color: Colors.grey),
                  enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.indigoAccent)),
                  suffixIcon: _isFetchingTitle 
                      ? const SizedBox(
                          width: 16, 
                          height: 16, 
                          child: Padding(
                            padding: EdgeInsets.all(12.0),
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.indigoAccent),
                          ),
                        )
                      : null,
                ),
                validator: (value) => value == null || value.isEmpty ? 'Please enter a name' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _urlController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'URL',
                  labelStyle: TextStyle(color: Colors.grey),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.indigoAccent)),
                ),
                validator: (value) => value == null || value.isEmpty ? 'Please enter a URL' : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _category,
                dropdownColor: const Color(0xFF1E293B),
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Category',
                  labelStyle: TextStyle(color: Colors.grey),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.indigoAccent)),
                ),
                items: const [
                  DropdownMenuItem(value: 'custom', child: Text('Custom')),
                  DropdownMenuItem(value: 'photography', child: Text('Photography')),
                  DropdownMenuItem(value: 'books', child: Text('Books')),
                  DropdownMenuItem(value: 'software', child: Text('Software')),
                  DropdownMenuItem(value: 'news', child: Text('News')),
                  DropdownMenuItem(value: 'education', child: Text('Education')),
                ],
                onChanged: (value) => setState(() => _category = value!),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isGenerating ? null : () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: _isGenerating ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.indigoAccent,
            foregroundColor: Colors.white,
          ),
          child: _isGenerating
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}
