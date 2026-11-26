import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'binance.dart';
import 'bot.dart';

// ---------- Background service ----------
@pragma('vm:entry-point')
void startCallback() => FlutterForegroundTask.setTaskHandler(BotHandler());

class BotHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async => Bot.tick();
  @override
  Future<void> onRepeatEvent(DateTime timestamp) async => Bot.tick();
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

// ---------- Theme (Binance-style) ----------
const kBg = Color(0xFF0B0E11), kCard = Color(0xFF181A20), kCard2 = Color(0xFF1E2329);
const kYellow = Color(0xFFFCD535), kGreen = Color(0xFF0ECB81), kRed = Color(0xFFF6465D);
const kGrey = Color(0xFF848E9C);

void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: kBg,
      colorScheme: const ColorScheme.dark(primary: kYellow, onPrimary: Colors.black, surface: kCard),
      appBarTheme: const AppBarTheme(backgroundColor: kBg, elevation: 0, centerTitle: false),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: kCard,
        indicatorColor: kYellow.withOpacity(.15),
        labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: kCard2, isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: kYellow)),
      ),
    ),
    home: const Shell(),
  ));
}

// ---------- State ----------
class Store extends ChangeNotifier {
  List<Map<String, dynamic>> trades = [];
  List<String> log = [];
  bool running = false, paused = false, online = true;
  String symbol = 'BTCUSDT';
  double? price, balance;
  bool hasKeys = false;

  Future<void> refresh() async {
    final p = await P();
    log = (p.getStringList('log') ?? []).reversed.toList();
    trades = (p.getStringList('trades') ?? []).map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
    paused = p.getBool('paused') ?? false;
    symbol = p.getString('symbol') ?? 'BTCUSDT';
    hasKeys = (p.getString('bk') ?? '').isNotEmpty && (p.getString('bs') ?? '').isNotEmpty;
    running = await FlutterForegroundTask.isRunningService;
    notifyListeners();
    try {
      price = await Binance('', '').price(symbol);
      online = true;
      if (hasKeys) balance = await Binance(p.getString('bk')!, p.getString('bs')!).free('USDT');
    } catch (_) {
      online = false;
    }
    notifyListeners();
  }

  Future<void> start() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('paused', false);
    await FlutterForegroundTask.requestNotificationPermission();
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(channelId: 'bot', channelName: 'Trading Bot'),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(15 * 60 * 1000), allowWakeLock: true, allowWifiLock: true),
    );
    await FlutterForegroundTask.startService(
        serviceId: 256, notificationTitle: 'ট্রেডিং বট চালু', notificationText: 'Binance Testnet', callback: startCallback);
    await logm('বট চালু');
    await refresh();
  }

  Future<void> stop() async {
    await FlutterForegroundTask.stopService();
    await logm('বট বন্ধ (খোলা ট্রেডের SL/TP সার্ভারে আছে)');
    await refresh();
  }

  double get totalPnl => trades.fold(0.0, (a, t) => a + ((t['pnl'] ?? 0) as num));
  double get todayPnl {
    final d = DateTime.now().toIso8601String().substring(0, 10);
    return trades.where((t) => t['open'] == false && (t['ts'] as String).startsWith(d)).fold(0.0, (a, t) => a + ((t['pnl'] ?? 0) as num));
  }
  List<Map<String, dynamic>> get closed => trades.where((t) => t['open'] == false).toList();
  double get winRate => closed.isEmpty ? 0 : closed.where((t) => (t['pnl'] ?? 0) > 0).length / closed.length * 100;
  Map<String, dynamic>? get openTrade {
    final o = trades.where((t) => t['open'] == true);
    return o.isEmpty ? null : o.first;
  }
}

String sgn(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}';
Color pc(double v) => v > 0 ? kGreen : (v < 0 ? kRed : kGrey);

// ---------- Shell ----------
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final s = Store();
  int i = 0;
  Timer? t;

  @override
  void initState() {
    super.initState();
    s.refresh();
    t = Timer.periodic(const Duration(seconds: 10), (_) => s.refresh());
  }

  @override
  void dispose() {
    t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final pages = [Dashboard(s), TradesPage(s), LogPage(s), SettingsPage(s)];
    return Scaffold(
      body: SafeArea(child: ListenableBuilder(listenable: s, builder: (_, __) => pages[i])),
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => i = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard, color: kYellow), label: 'ড্যাশবোর্ড'),
          NavigationDestination(icon: Icon(Icons.swap_vert), selectedIcon: Icon(Icons.swap_vert, color: kYellow), label: 'ট্রেড'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long, color: kYellow), label: 'লগ'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings, color: kYellow), label: 'সেটিংস'),
        ],
      ),
    );
  }
}

// ---------- Widgets ----------
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets pad;
  const Panel({super.key, required this.child, this.pad = const EdgeInsets.all(16)});
  @override
  Widget build(BuildContext c) => Container(
        width: double.infinity, padding: pad, margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12)),
        child: child,
      );
}

class Stat extends StatelessWidget {
  final String label, value;
  final Color? color;
  const Stat(this.label, this.value, {super.key, this.color});
  @override
  Widget build(BuildContext c) => Expanded(
        child: Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: kGrey, fontSize: 11)),
            const SizedBox(height: 6),
            Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: color)),
          ]),
        ),
      );
}

// ---------- Dashboard ----------
class Dashboard extends StatelessWidget {
  final Store s;
  const Dashboard(this.s, {super.key});

  @override
  Widget build(BuildContext c) {
    final aiNote = s.log.firstWhere((l) => l.contains('AI:'), orElse: () => '');
    final ot = s.openTrade;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        const Text('Trade Bot', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(border: Border.all(color: kYellow), borderRadius: BorderRadius.circular(4)),
          child: const Text('TESTNET', style: TextStyle(color: kYellow, fontSize: 10, fontWeight: FontWeight.bold)),
        ),
        const Spacer(),
        Icon(Icons.circle, size: 10, color: s.online ? kGreen : kRed),
        const SizedBox(width: 6),
        Text(s.online ? 'অনলাইন' : 'অফলাইন', style: const TextStyle(color: kGrey, fontSize: 12)),
      ]),
      const SizedBox(height: 16),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('ব্যালেন্স (USDT)', style: TextStyle(color: kGrey, fontSize: 12)),
          const SizedBox(height: 6),
          Text(s.balance == null ? '--' : s.balance!.toStringAsFixed(2),
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Row(children: [
            const Text('আজকের PnL  ', style: TextStyle(color: kGrey, fontSize: 12)),
            Text('${sgn(s.todayPnl)} USDT', style: TextStyle(color: pc(s.todayPnl), fontWeight: FontWeight.w600)),
          ]),
        ]),
      ),
      Panel(
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: kCard2, borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.currency_bitcoin, color: kYellow),
          ),
          const SizedBox(width: 12),
          Text(s.symbol, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(s.price == null ? '--' : s.price!.toStringAsFixed(2),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ]),
      ),
      SizedBox(
        height: 52,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
              backgroundColor: s.running ? kRed : kYellow,
              foregroundColor: s.running ? Colors.white : Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          icon: Icon(s.running ? Icons.stop_circle_outlined : Icons.play_circle_outline),
          label: Text(s.running ? 'বট বন্ধ করুন' : 'বট চালু করুন', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          onPressed: () async {
            if (s.running) {
              await s.stop();
            } else if (!s.hasKeys) {
              ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('আগে সেটিংসে Binance Key দিন')));
            } else {
              await s.start();
            }
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          s.paused ? 'বট বিরতিতে (জরুরি বন্ধ/লস সীমা)। "চালু" চাপলে আবার শুরু হবে।'
              : s.running ? 'বট চলছে • প্রতি ১৫ মিনিটে বাজার বিশ্লেষণ' : 'বট বন্ধ আছে',
          textAlign: TextAlign.center, style: const TextStyle(color: kGrey, fontSize: 12),
        ),
      ),
      const SizedBox(height: 4),
      Row(children: [
        Stat('মোট ট্রেড', '${s.closed.length}'),
        Stat('জয়ের হার', '${s.winRate.toStringAsFixed(0)}%'),
        Stat('মোট PnL', sgn(s.totalPnl), color: pc(s.totalPnl)),
      ]),
      const SizedBox(height: 12),
      if (ot != null)
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('খোলা পজিশন', style: TextStyle(color: kYellow, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('এন্ট্রি ${(ot['entry'] as num).toStringAsFixed(2)}  •  পরিমাণ ${ot['qty']}'),
            const SizedBox(height: 4),
            Text('${ot['reason'] ?? ''}', style: const TextStyle(color: kGrey, fontSize: 12)),
            const SizedBox(height: 4),
            const Text('SL/TP Binance সার্ভারে সুরক্ষিত', style: TextStyle(color: kGreen, fontSize: 12)),
          ]),
        ),
      if (aiNote.isNotEmpty)
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.auto_awesome, size: 16, color: kYellow),
              SizedBox(width: 6),
              Text('সর্বশেষ AI সিদ্ধান্ত', style: TextStyle(color: kGrey, fontSize: 12)),
            ]),
            const SizedBox(height: 8),
            Text(aiNote, style: const TextStyle(fontSize: 13)),
          ]),
        ),
    ]);
  }
}

// ---------- Trades ----------
class TradesPage extends StatelessWidget {
  final Store s;
  const TradesPage(this.s, {super.key});
  @override
  Widget build(BuildContext c) {
    final l = s.trades.reversed.toList();
    if (l.isEmpty) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.inbox_outlined, size: 48, color: kGrey),
        SizedBox(height: 8),
        Text('এখনো কোনো ট্রেড নেই', style: TextStyle(color: kGrey)),
      ]));
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('ট্রেড ইতিহাস', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      for (final t in l)
        Panel(
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('BUY @ ${(t['entry'] as num).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('পরিমাণ ${t['qty']}  •  ${(t['ts'] as String).substring(5, 16).replaceFirst('T', ' ')}',
                    style: const TextStyle(color: kGrey, fontSize: 12)),
                if (t['reason'] != null) Text('${t['reason']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kGrey, fontSize: 11)),
              ]),
            ),
            t['open'] == true
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: kYellow.withOpacity(.15), borderRadius: BorderRadius.circular(6)),
                    child: const Text('খোলা', style: TextStyle(color: kYellow, fontSize: 12)))
                : Text(sgn(((t['pnl'] ?? 0) as num).toDouble()),
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: pc(((t['pnl'] ?? 0) as num).toDouble()))),
          ]),
        ),
    ]);
  }
}

// ---------- Log ----------
class LogPage extends StatelessWidget {
  final Store s;
  const LogPage(this.s, {super.key});
  @override
  Widget build(BuildContext c) => ListView(padding: const EdgeInsets.all(16), children: [
        const Text('কার্যকলাপ লগ', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        if (s.log.isEmpty) const Text('এখনো কিছু নেই', style: TextStyle(color: kGrey)),
        for (final l in s.log.take(100))
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(8)),
            child: Text(l, style: TextStyle(fontSize: 12, color: l.contains('ত্রুটি') || l.contains('ব্যর্থ') ? kRed : null)),
          ),
      ]);
}

// ---------- Settings ----------
class SettingsPage extends StatefulWidget {
  final Store s;
  const SettingsPage(this.s, {super.key});
  @override
  State<SettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsPage> {
  static const keys = ['bk', 'bs', 'usdt', 'sl', 'tp', 'loss', 'k_zen', 'k_groq', 'k_gem'];
  final c = {for (final k in keys) k: TextEditingController()};
  final hide = {'bs': true, 'k_zen': true, 'k_groq': true, 'k_gem': true};
  String symbol = 'BTCUSDT';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await P();
    for (final k in keys) {
      c[k]!.text = p.getString(k) ?? '';
    }
    setState(() => symbol = p.getString('symbol') ?? 'BTCUSDT');
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    for (final k in keys) {
      await p.setString(k, c[k]!.text.trim());
    }
    await p.setString('symbol', symbol);
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Widget _f(String k, String label, {String? hint, bool num = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c[k],
          obscureText: hide[k] ?? false,
          keyboardType: num ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          decoration: InputDecoration(
            labelText: label, hintText: hint,
            suffixIcon: hide.containsKey(k)
                ? IconButton(icon: Icon(hide[k]! ? Icons.visibility_off : Icons.visibility, size: 18), onPressed: () => setState(() => hide[k] = !hide[k]!))
                : null,
          ),
        ),
      );

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(t, style: const TextStyle(color: kYellow, fontWeight: FontWeight.w600)),
      );

  @override
  Widget build(BuildContext ctx) => ListView(padding: const EdgeInsets.all(16), children: [
        const Text('সেটিংস', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _h('Binance Testnet'),
          _f('bk', 'API Key'),
          _f('bs', 'Secret Key'),
          DropdownButtonFormField<String>(
            value: symbol,
            decoration: const InputDecoration(labelText: 'কয়েন জোড়া'),
            items: ['BTCUSDT', 'ETHUSDT', 'BNBUSDT', 'SOLUSDT'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
            onChanged: (v) => setState(() => symbol = v!),
          ),
        ])),
        Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _h('ট্রেড নিয়ম ও সুরক্ষা'),
          _f('usdt', 'প্রতি ট্রেডে USDT', hint: '20', num: true),
          _f('sl', 'Stop-loss %', hint: '0.8', num: true),
          _f('tp', 'Take-profit %', hint: '1.2', num: true),
          _f('loss', 'দৈনিক সর্বোচ্চ লস (USDT)', hint: '5', num: true),
        ])),
        Panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _h('AI Key (এক বা একাধিক, ফলব্যাক ক্রমে)'),
          _f('k_zen', 'OpenCode Zen (DeepSeek ফ্রি)'),
          _f('k_groq', 'Groq'),
          _f('k_gem', 'Gemini'),
        ])),
        SizedBox(
          height: 48,
          child: FilledButton(
            style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () async {
              await _save();
              await widget.s.refresh();
              _snack('সেভ হয়েছে');
            },
            child: const Text('সেভ করুন', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 48,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.wifi_tethering),
            label: const Text('Binance সংযোগ টেস্ট'),
            onPressed: () async {
              await _save();
              try {
                final b = await Binance(c['bk']!.text.trim(), c['bs']!.text.trim()).free('USDT');
                _snack('সংযোগ সফল • USDT: ${b.toStringAsFixed(2)}');
              } catch (e) {
                _snack('সংযোগ ব্যর্থ: Key/নেট দেখুন');
              }
            },
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 48,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: kRed, side: const BorderSide(color: kRed)),
            icon: const Icon(Icons.warning_amber_rounded),
            label: const Text('জরুরি বন্ধ'),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (d) => AlertDialog(
                  backgroundColor: kCard,
                  title: const Text('জরুরি বন্ধ?'),
                  content: const Text('সব খোলা অর্ডার বাতিল হবে, পজিশন বিক্রি হবে এবং বট বিরতিতে যাবে।'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('না')),
                    TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('হ্যাঁ, বন্ধ করুন', style: TextStyle(color: kRed))),
                  ],
                ),
              );
              if (ok == true) {
                await _save();
                await widget.s.stop();
                await Bot.emergency();
                await widget.s.refresh();
                _snack('জরুরি বন্ধ সম্পন্ন');
              }
            },
          ),
        ),
        const SizedBox(height: 24),
      ]);
}
