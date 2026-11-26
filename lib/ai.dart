import 'dart:convert';
import 'package:http/http.dart' as http;

class Prov {
  final String name, url, model, key;
  Prov(this.name, this.url, this.model, this.key);
}

/// ফলব্যাক চেইন: একটা ব্যর্থ হলে পরেরটা
Future<String> askAI(List<Prov> chain, String system, String user) async {
  final errs = <String>[];
  for (final p in chain.where((p) => p.key.trim().isNotEmpty)) {
    try {
      final r = await http
          .post(Uri.parse('${p.url}/chat/completions'),
              headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${p.key.trim()}'},
              body: jsonEncode({
                'model': p.model,
                'temperature': 0.2,
                'messages': [
                  {'role': 'system', 'content': system},
                  {'role': 'user', 'content': user},
                ],
              }))
          .timeout(const Duration(seconds: 45));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      return jsonDecode(r.body)['choices'][0]['message']['content'] as String;
    } catch (e) {
      errs.add('${p.name}: $e');
    }
  }
  throw Exception('AI ব্যর্থ: ${errs.join(' | ')}');
}

Map<String, dynamic>? parseJson(String t) {
  final a = t.indexOf('{'), b = t.lastIndexOf('}');
  if (a < 0 || b <= a) return null;
  try {
    return jsonDecode(t.substring(a, b + 1)) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}
