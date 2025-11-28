import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import '../config.dart';

class GroqService {
  static const String _apiKey = Config.groqApiKey;
  static const String _apiUrl = 'https://api.groq.com/openai/v1/chat/completions';
  static const String _model = 'llama-3.1-8b-instant';

  Future<String> generateDescription(String title, String url) async {
    try {
      final prompt = 'Generate a very concise description (maximum 11 words) for this website:\nTitle: $title\nURL: $url';

      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_apiKey',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {
              'role': 'user',
              'content': prompt,
            }
          ],
          'temperature': 0.7,
          'max_tokens': 50,
        }),
      );

      if (response.statusCode != 200) {
        throw Exception('API request failed: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      final description = data['choices'][0]['message']['content']?.trim();

      if (description == null || description.isEmpty) {
        throw Exception('No description generated');
      }

      return description;
    } catch (e) {
      developer.log('Error generating description: $e');
      return 'Added by user';
    }
  }
}
