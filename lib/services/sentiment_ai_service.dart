import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:developer' as developer;


class SentimentAiService {
  Interpreter? _interpreter;
  Map<String, int>? _vocab;
  bool _isReady = false;

  // Constants for the standard text classification model
  static const int _sentenceLen = 256;
  static const String _startToken = '<START>';
  static const String _padToken = '<PAD>';
  static const String _unkToken = '<UNKNOWN>';

  Future<void> initialize() async {
    try {
      // Load the model
      final options = InterpreterOptions();
      // On Android/iOS we might want to use delegates (NNAPI, GPU, Metal)
      // options.addDelegate(XNNPackDelegate()); 
      
      _interpreter = await Interpreter.fromAsset('assets/text_classification.tflite', options: options);
      
      // Load vocab
      await _loadVocab();
      
      _isReady = true;
      developer.log("✅ Sentiment AI Model Loaded");
    } catch (e) {
      developer.log("❌ Error loading Sentiment AI Model: $e");
    }
  }

  Future<void> _loadVocab() async {
    try {
      final vocabString = await rootBundle.loadString('assets/vocab.txt');
      final lines = vocabString.split('\n');
      _vocab = {};
      for (var i = 0; i < lines.length; i++) {
        _vocab![lines[i].trim()] = i;
      }
    } catch (e) {
      developer.log("❌ Error loading vocab: $e");
    }
  }

  Future<double> analyzeSentiment(String text) async {
    if (!_isReady || _interpreter == null || _vocab == null) {
      return 0.0; // Default or fallback
    }

    try {
      // Preprocess
      final input = _tokenizeInput(text);
      
      // Output buffer
      // Shape depends on model. Usually [1, 2] for binary classification (Negative, Positive)
      var output = List.filled(1 * 2, 0.0).reshape([1, 2]); 
      
      _interpreter!.run(input, output);
      
      // Parse output
      final prediction = output[0] as List<double>;
      final negativeScore = prediction[0];
      final positiveScore = prediction[1];
      
      // Return a score. 
      // If simple binary: 1.0 (pos), 0.0 (neg)
      // We can return confidence of positive - confidence of negative?
      
      developer.log("AI Score for '${text.substring(0, 20)}...': Neg=$negativeScore, Pos=$positiveScore");
      
      // Normalize to -1 to 1 range approx? 
      // Or just return positive probability (0 to 1)
      return positiveScore; 
      
    } catch (e) {
      developer.log("Inference failed: $e");
      return 0.5; // Neutral
    }
  }

  List<List<double>> _tokenizeInput(String text) {
    // Basic whitespace tokenization
    // A real tokenizer should handle punctuation better
    final tokens = text.toLowerCase().split(RegExp(r'\s+'));
    
    // Map to indices
    final indices = <double>[];
    
    // Start token
    if (_vocab!.containsKey(_startToken)) {
      indices.add(_vocab![_startToken]!.toDouble());
    } else {
       indices.add(0); // Usually 0 is something reserved or padding
    }

    for (var token in tokens) {
      if (indices.length >= _sentenceLen) break;
      
      if (_vocab!.containsKey(token)) {
        indices.add(_vocab![token]!.toDouble());
      } else {
        indices.add(_vocab![_unkToken]?.toDouble() ?? 2.0); // Assume 2 is unknown
      }
    }
    
    // Padding
    while (indices.length < _sentenceLen) {
      indices.add(_vocab![_padToken]?.toDouble() ?? 0.0);
    }
    
    // Reshape for TFLite [1, 256]
    return [indices];
  }
  
  void dispose() {
    _interpreter?.close();
  }
}
