import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class Filters {
  final double step, tick;
  Filters(this.step, this.tick);
}

class Binance {
  final String key, secret;
  static const base = 'https://testnet.binance.vision'; // শুধু Testnet
  Binance(this.key, this.secret);

  Future<dynamic> _pub(String path, Map<String, String> q) async {
    final r = await http
        .get(Uri.parse('$base$path').replace(queryParameters: q))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('${r.statusCode} ${r.body}');
    return jsonDecode(r.body);
  }

  Future<dynamic> _signed(String method, String path, Map<String, String> p) async {
    p['timestamp'] = DateTime.now().millisecondsSinceEpoch.toString();
    p['recvWindow'] = '10000';
    final qs = Uri(queryParameters: p).query;
    final sig = Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(qs)).toString();
    final uri = Uri.parse('$base$path?$qs&signature=$sig');
    final h = {'X-MBX-APIKEY': key};
    final f = method == 'GET'
        ? http.get(uri, headers: h)
        : method == 'POST'
            ? http.post(uri, headers: h)
            : http.delete(uri, headers: h);
    final r = await f.timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('${r.statusCode} ${r.body}');
    return jsonDecode(r.body);
  }

  Future<double> price(String s) async {
    final d = await _pub('/api/v3/ticker/price', {'symbol': s});
    return double.parse(d['price']);
  }

  Future<List<double>> closes(String s, String interval, int n) async {
    final d = await _pub('/api/v3/klines', {'symbol': s, 'interval': interval, 'limit': '$n'});
    return (d as List).map<double>((k) => double.parse(k[4])).toList();
  }

  Future<Filters> filters(String s) async {
    final d = await _pub('/api/v3/exchangeInfo', {'symbol': s});
    double step = 0.0001, tick = 0.01;
    for (final f in d['symbols'][0]['filters']) {
      if (f['filterType'] == 'LOT_SIZE') step = double.parse(f['stepSize']);
      if (f['filterType'] == 'PRICE_FILTER') tick = double.parse(f['tickSize']);
    }
    return Filters(step, tick);
  }

  static String fmt(double v, double step) {
    var d = 0;
    var s = step;
    while ((s - s.round()).abs() > 1e-12 && d < 8) {
      s *= 10;
      d++;
    }
    final fl = (v / step + 1e-9).floorToDouble() * step;
    return fl.toStringAsFixed(d);
  }

  Future<List<dynamic>> openOrders(String s) async =>
      await _signed('GET', '/api/v3/openOrders', {'symbol': s});

  Future<Map> marketBuy(String s, double usdt) async => await _signed('POST', '/api/v3/order', {
        'symbol': s, 'side': 'BUY', 'type': 'MARKET',
        'quoteOrderQty': usdt.toString(), 'newOrderRespType': 'FULL',
      });

  Future<void> marketSell(String s, String qty) async => await _signed('POST', '/api/v3/order', {
        'symbol': s, 'side': 'SELL', 'type': 'MARKET', 'quantity': qty,
      });

  // সার্ভার-সাইড সুরক্ষা: ফোন বন্ধ হলেও কাজ করবে
  Future<void> oco(String s, String qty, String tp, String slStop, String slLimit) async =>
      await _signed('POST', '/api/v3/orderList/oco', {
        'symbol': s, 'side': 'SELL', 'quantity': qty,
        'aboveType': 'LIMIT_MAKER', 'abovePrice': tp,
        'belowType': 'STOP_LOSS_LIMIT', 'belowStopPrice': slStop,
        'belowPrice': slLimit, 'belowTimeInForce': 'GTC',
      });

  Future<void> cancelAll(String s) async =>
      await _signed('DELETE', '/api/v3/openOrders', {'symbol': s});

  Future<double> free(String asset) async {
    final d = await _signed('GET', '/api/v3/account', {});
    for (final b in d['balances']) {
      if (b['asset'] == asset) return double.parse(b['free']);
    }
    return 0;
  }

  Future<double?> lastSellPrice(String s) async {
    final d = await _signed('GET', '/api/v3/myTrades', {'symbol': s, 'limit': '10'});
    for (final t in (d as List).reversed) {
      if (t['isBuyer'] == false) return double.parse(t['price']);
    }
    return null;
  }
}
