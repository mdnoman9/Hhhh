import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai.dart';
import 'binance.dart';

Future<SharedPreferences> P() async {
  final p = await SharedPreferences.getInstance();
  await p.reload(); // UI ও ব্যাকগ্রাউন্ড আলাদা isolate
  return p;
}

Future<void> logm(String m) async {
  final p = await P();
  final l = p.getStringList('log') ?? [];
  l.add('${DateTime.now().toIso8601String().substring(5, 19)}  $m');
  if (l.length > 300) l.removeRange(0, l.length - 300);
  await p.setStringList('log', l);
}

double ema(List<double> v, int n) {
  final k = 2 / (n + 1);
  var e = v.first;
  for (final x in v) {
    e = x * k + e * (1 - k);
  }
  return e;
}

double rsi(List<double> v, int n) {
  double g = 0, l = 0;
  for (var i = v.length - n; i < v.length; i++) {
    final d = v[i] - v[i - 1];
    if (d > 0) g += d; else l -= d;
  }
  if (l == 0) return 100;
  return 100 - 100 / (1 + g / l);
}

class Bot {
  static bool _busy = false;

  static Future<List<Map<String, dynamic>>> _trades() async {
    final p = await P();
    return (p.getStringList('trades') ?? []).map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
  }

  static Future<void> _save(List<Map<String, dynamic>> t) async {
    final p = await P();
    if (t.length > 200) t.removeRange(0, t.length - 200);
    await p.setStringList('trades', t.map(jsonEncode).toList());
  }

  static List<Prov> _chain(SharedPreferences p) => [
        Prov('Zen', 'https://opencode.ai/zen/v1', 'deepseek-v4-flash-free', p.getString('k_zen') ?? ''),
        Prov('Groq', 'https://api.groq.com/openai/v1', 'llama-3.3-70b-versatile', p.getString('k_groq') ?? ''),
        Prov('Gemini', 'https://generativelanguage.googleapis.com/v1beta/openai', 'gemini-2.5-flash', p.getString('k_gem') ?? ''),
      ];

  static Future<void> tick() async {
    if (_busy) return;
    _busy = true;
    try {
      await _run();
    } catch (e) {
      await logm('ত্রুটি/অফলাইন: $e → নতুন ট্রেড নয়');
    } finally {
      _busy = false;
    }
  }

  static Future<void> _run() async {
    final p = await P();
    if (p.getBool('paused') ?? false) return;
    final sym = p.getString('symbol') ?? 'BTCUSDT';
    final usdt = double.tryParse(p.getString('usdt') ?? '') ?? 20;
    final slPct = double.tryParse(p.getString('sl') ?? '') ?? 0.8;
    final tpPct = double.tryParse(p.getString('tp') ?? '') ?? 1.2;
    final lossLim = double.tryParse(p.getString('loss') ?? '') ?? 5;
    final bn = Binance(p.getString('bk') ?? '', p.getString('bs') ?? '');

    // ১) ডেটা আনা (ব্যর্থ হলে অফলাইন ধরে থামবে)
    final c15 = await bn.closes(sym, '15m', 100);
    final c1h = await bn.closes(sym, '1h', 60);

    // ২) খোলা পজিশন মিলিয়ে নেওয়া
    final trades = await _trades();
    for (final t in trades.where((t) => t['open'] == true)) {
      final oo = await bn.openOrders(sym);
      if (oo.isEmpty) {
        final sp = await bn.lastSellPrice(sym);
        if (sp != null) {
          t['pnl'] = (sp - t['entry']) * t['qty'];
          t['open'] = false;
          await logm('ট্রেড বন্ধ: PnL ${(t['pnl'] as double).toStringAsFixed(3)} USDT');
        }
      }
    }
    await _save(trades);
    if (trades.any((t) => t['open'] == true)) {
      await logm('পজিশন খোলা, অপেক্ষা');
      return;
    }

    // ৩) দৈনিক লস সীমা
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final todayLoss = trades
        .where((t) => t['open'] == false && (t['ts'] as String).startsWith(today))
        .fold<double>(0, (a, t) => a + (t['pnl'] ?? 0));
    if (todayLoss <= -lossLim) {
      await logm('দৈনিক লস সীমা ছুঁয়েছে (${todayLoss.toStringAsFixed(2)}), আজ আর ট্রেড নয়');
      return;
    }

    // ৪) দিনে একবার AI রিভিউ → শিক্ষা (lessons)
    final chain = _chain(p);
    if (p.getString('reviewDay') != today) {
      final closed = trades.where((t) => t['open'] == false).toList();
      if (closed.isNotEmpty) {
        try {
          final txt = await askAI(
              chain,
              'You review a crypto spot bot trade log. Give max 5 short concrete lessons to improve entries. Plain text.',
              jsonEncode(closed.sublist(max(0, closed.length - 20))));
          await p.setString('lessons', txt.length > 700 ? txt.substring(0, 700) : txt);
          await p.setString('reviewDay', today);
          await logm('AI রিভিউ সম্পন্ন');
        } catch (e) {
          await logm('রিভিউ ব্যর্থ: $e');
        }
      } else {
        await p.setString('reviewDay', today);
      }
    }

    // ৫) AI সিদ্ধান্ত
    final price = c15.last;
    final data = {
      'symbol': sym,
      'price': price,
      'rsi14_15m': rsi(c15, 14).toStringAsFixed(1),
      'ema9_15m': ema(c15, 9).toStringAsFixed(2),
      'ema21_15m': ema(c15, 21).toStringAsFixed(2),
      'ema20_1h': ema(c1h, 20).toStringAsFixed(2),
      'change_1h_pct': ((c15.last / c15[c15.length - 5] - 1) * 100).toStringAsFixed(2),
      'recent_results': trades.reversed.take(5).map((t) => t['pnl'] ?? 'open').toList(),
      'lessons': p.getString('lessons') ?? '',
    };
    final ans = await askAI(
        chain,
        'You are a cautious spot crypto trading assistant (Binance Testnet). Hold time is hours. '
        'Reply ONLY JSON: {"action":"BUY" or "HOLD","reason":"short"}. Default HOLD; BUY only on strong setups.',
        jsonEncode(data));
    final j = parseJson(ans);
    if (j == null || (j['action'] != 'BUY' && j['action'] != 'HOLD')) {
      await logm('AI উত্তর অবৈধ → HOLD');
      return;
    }
    await logm('AI: ${j['action']} — ${j['reason']}');
    if (j['action'] != 'BUY') return;

    // ৬) কেনা + সার্ভারে OCO
    final f = await bn.filters(sym);
    final o = await bn.marketBuy(sym, usdt);
    final base = sym.replaceAll('USDT', '');
    double qtyRaw = double.parse(o['executedQty']);
    for (final fl in (o['fills'] as List)) {
      if (fl['commissionAsset'] == base) qtyRaw -= double.parse(fl['commission']);
    }
    final entry = double.parse(o['cummulativeQuoteQty']) / double.parse(o['executedQty']);
    final qty = Binance.fmt(qtyRaw, f.step);
    final slStop = entry * (1 - slPct / 100), tpP = entry * (1 + tpPct / 100);
    try {
      await bn.oco(sym, qty, Binance.fmt(tpP, f.tick), Binance.fmt(slStop, f.tick),
          Binance.fmt(slStop * 0.999, f.tick));
      trades.add({
        'ts': DateTime.now().toIso8601String(), 'entry': entry, 'qty': double.parse(qty),
        'open': true, 'reason': j['reason'],
      });
      await _save(trades);
      await logm('কেনা $qty @ ${entry.toStringAsFixed(2)} | SL/TP সার্ভারে বসানো');
    } catch (e) {
      await logm('OCO ব্যর্থ ($e) → সুরক্ষার জন্য সঙ্গে সঙ্গে বিক্রি');
      await bn.marketSell(sym, qty);
    }
  }

  /// জরুরি বন্ধ: সব অর্ডার বাতিল, বিক্রি, বট বিরতিতে
  static Future<void> emergency() async {
    final p = await P();
    await p.setBool('paused', true);
    final sym = p.getString('symbol') ?? 'BTCUSDT';
    final bn = Binance(p.getString('bk') ?? '', p.getString('bs') ?? '');
    try {
      await bn.cancelAll(sym);
      final trades = await _trades();
      for (final t in trades.where((t) => t['open'] == true)) {
        final f = await bn.filters(sym);
        await bn.marketSell(sym, Binance.fmt(t['qty'], f.step));
        t['open'] = false;
        t['pnl'] = 0.0;
      }
      await _save(trades);
      await logm('জরুরি বন্ধ সম্পন্ন');
    } catch (e) {
      await logm('জরুরি বন্ধ ত্রুটি: $e');
    }
  }
}
