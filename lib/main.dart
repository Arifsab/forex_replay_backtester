import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const ForexReplayApp());
}

class Candle {
  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;

  Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
  });
}

class Trade {
  final String id;
  final DateTime time;
  final String symbol;
  final String timeframe;
  final String side;
  final double entry;
  final double sl;
  final double tp;
  final String note;
  final String outcome;

  Trade({
    required this.id,
    required this.time,
    required this.symbol,
    required this.timeframe,
    required this.side,
    required this.entry,
    required this.sl,
    required this.tp,
    required this.note,
    required this.outcome,
  });

  Map<String, dynamic> toJson() => {
        "id": id,
        "time": time.toIso8601String(),
        "symbol": symbol,
        "timeframe": timeframe,
        "side": side,
        "entry": entry,
        "sl": sl,
        "tp": tp,
        "note": note,
        "outcome": outcome,
      };

  static Trade fromJson(Map<String, dynamic> json) => Trade(
        id: json["id"],
        time: DateTime.parse(json["time"]),
        symbol: json["symbol"],
        timeframe: json["timeframe"],
        side: json["side"],
        entry: (json["entry"] as num).toDouble(),
        sl: (json["sl"] as num).toDouble(),
        tp: (json["tp"] as num).toDouble(),
        note: json["note"],
        outcome: json["outcome"],
      );
}

class ForexReplayApp extends StatefulWidget {
  const ForexReplayApp({super.key});

  @override
  State<ForexReplayApp> createState() => _ForexReplayAppState();
}

class _ForexReplayAppState extends State<ForexReplayApp> {
  ThemeMode mode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Forex Replay Backtester",
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        brightness: Brightness.dark,
      ),
      home: HomeScreen(
        onToggleTheme: () {
          setState(() {
            mode = (mode == ThemeMode.dark) ? ThemeMode.light : ThemeMode.dark;
          });
        },
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;

  const HomeScreen({super.key, required this.onToggleTheme});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Candle> _allCandles = [];
  int _index = 0;

  Timer? _timer;
  bool _playing = false;
  double _speed = 1.0;
  int _window = 120;

  double? _entry;
  double? _sl;
  double? _tp;
  String _side = "BUY";

  String _symbol = "EURUSD";
  String _timeframe = "Unknown";
  String _csvName = "No file";

  List<Trade> _trades = [];

  @override
  void initState() {
    super.initState();
    _loadTrades();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadTrades() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString("trades_v1");
    if (raw == null) return;
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    setState(() => _trades = list.map(Trade.fromJson).toList());
  }

  Future<void> _saveTrades() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_trades.map((t) => t.toJson()).toList());
    await prefs.setString("trades_v1", raw);
  }

  void _play() {
    if (_allCandles.isEmpty) return;
    _timer?.cancel();
    setState(() => _playing = true);
    final ms = max(60, (500 / _speed).round());
    _timer = Timer.periodic(Duration(milliseconds: ms), (_) {
      if (_index >= _allCandles.length - 1) {
        _pause();
        return;
      }
      setState(() => _index++);
    });
  }

  void _pause() {
    _timer?.cancel();
    setState(() => _playing = false);
  }

  void _stepNext() {
    if (_allCandles.isEmpty) return;
    if (_index < _allCandles.length - 1) setState(() => _index++);
  }

  void _stepPrev() {
    if (_allCandles.isEmpty) return;
    if (_index > 0) setState(() => _index--);
  }

  DateTime? _tryParseDate(String s) {
    final t = s.trim();
    final fmts = <DateFormat>[
      DateFormat("MM/dd/yyyy HH:mm"),
      DateFormat("MM/dd/yyyy H:mm"),
      DateFormat("yyyy-MM-dd HH:mm"),
      DateFormat("yyyy-MM-dd H:mm"),
      DateFormat("yyyy.MM.dd HH:mm"),
      DateFormat("dd/MM/yyyy HH:mm"),
    ];

    for (final f in fmts) {
      try {
        return f.parseStrict(t);
      } catch (_) {}
    }

    // Try unix timestamp seconds/millis
    final n = int.tryParse(t);
    if (n != null) {
      if (n > 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(n);
      } else if (n > 1000000000) {
        return DateTime.fromMillisecondsSinceEpoch(n * 1000);
      }
    }

    return null;
  }

  double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.parse(v.toString());
  }

  String _detectTimeframe(List<Candle> c) {
    if (c.length < 3) return "Unknown";
    final d1 = c[1].time.difference(c[0].time).inMinutes;
    final map = <int, String>{
      1: "M1",
      5: "M5",
      15: "M15",
      30: "M30",
      60: "H1",
      240: "H4",
      1440: "D1",
    };
    return map[d1] ?? "${d1}m";
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pickCsv() async {
    _pause();

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ["csv"],
      withData: true,
    );
    if (result == null) return;

    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) return;

    final content = utf8.decode(bytes);
    final rows = const CsvToListConverter(eol: "\n").convert(content);
    if (rows.isEmpty) return;

    final header = rows.first.map((e) => e.toString().trim()).toList();

    int idxDate = header.indexWhere((h) => h.toLowerCase() == "date");
    int idxOpen = header.indexWhere((h) => h.toLowerCase() == "open");
    int idxHigh = header.indexWhere((h) => h.toLowerCase() == "high");
    int idxLow = header.indexWhere((h) => h.toLowerCase() == "low");
    int idxClose = header.indexWhere((h) => h.toLowerCase() == "close");

    if ([idxDate, idxOpen, idxHigh, idxLow, idxClose].any((i) => i < 0)) {
      _showMsg("CSV invalid. Need: Date,Open,High,Low,Close");
      return;
    }

    final candles = <Candle>[];

    for (int i = 1; i < rows.length; i++) {
      final r = rows[i];
      if (r.length < header.length) continue;
      try {
        final dateStr = r[idxDate].toString();
        final time = _tryParseDate(dateStr);
        if (time == null) continue;

        final o = _toDouble(r[idxOpen]);
        final h = _toDouble(r[idxHigh]);
        final l = _toDouble(r[idxLow]);
        final c = _toDouble(r[idxClose]);

        candles.add(Candle(time: time, open: o, high: h, low: l, close: c));
      } catch (_) {}
    }

    candles.sort((a, b) => a.time.compareTo(b.time));
    final tf = _detectTimeframe(candles);

    setState(() {
      _csvName = file.name;
      _allCandles = candles;
      _timeframe = tf;
      _index = min(120, max(0, candles.length - 1));
      _entry = null;
      _sl = null;
      _tp = null;
      _side = "BUY";
    });

    _showMsg("Loaded ${candles.length} candles ✅ | TF: $_timeframe");
  }

  List<Candle> get _visibleCandles {
    if (_allCandles.isEmpty) return [];
    final end = _index;
    final start = max(0, end - _window + 1);
    return _allCandles.sublist(start, end + 1);
  }

  Candle? get _currentCandle => _allCandles.isEmpty ? null : _allCandles[_index];

  double _priceFromTouch(double relativeY, double minP, double maxP) {
    return maxP - (maxP - minP) * relativeY;
  }

  Future<void> _addTrade() async {
    if (_entry == null || _sl == null || _tp == null) {
      _showMsg("Set Entry, SL, TP first.");
      return;
    }
    final c = _currentCandle;
    if (c == null) return;

    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final trade = Trade(
      id: id,
      time: c.time,
      symbol: _symbol,
      timeframe: _timeframe,
      side: _side,
      entry: _entry!,
      sl: _sl!,
      tp: _tp!,
      note: "Replay trade",
      outcome: "Unknown",
    );

    setState(() => _trades.insert(0, trade));
    await _saveTrades();
    _showMsg("Trade saved ✅");
  }

  Future<void> _deleteTrade(String id) async {
    setState(() => _trades.removeWhere((t) => t.id == id));
    await _saveTrades();
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentCandle;
    final visible = _visibleCandles;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Forex Replay Backtester"),
        actions: [
          IconButton(
            tooltip: "Toggle Theme",
            onPressed: widget.onToggleTheme,
            icon: const Icon(Icons.brightness_6),
          ),
          IconButton(
            tooltip: "Import CSV",
            onPressed: _pickCsv,
            icon: const Icon(Icons.upload_file),
          ),
        ],
      ),
      body: Column(
        children: [
          _TopInfoBar(
            csvName: _csvName,
            symbol: _symbol,
            timeframe: _timeframe,
            index: _index,
            total: _allCandles.length,
            currentTime: current?.time,
            onSymbolChange: (v) => setState(() => _symbol = v),
          ),
          Expanded(
            flex: 7,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: _ChartCard(
                candles: visible,
                entry: _entry,
                sl: _sl,
                tp: _tp,
                onTapSetLevel: (relativeY) {
                  if (visible.isEmpty) return;
                  final minP = visible.map((c) => c.low).reduce(min);
                  final maxP = visible.map((c) => c.high).reduce(max);
                  final price = _priceFromTouch(relativeY, minP, maxP);

                  setState(() {
                    if (_entry == null) {
                      _entry = price;
                    } else if (_sl == null) {
                      _sl = price;
                    } else if (_tp == null) {
                      _tp = price;
                    } else {
                      _entry = price;
                      _sl = null;
                      _tp = null;
                    }
                  });
                },
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: _BottomControls(
              playing: _playing,
              speed: _speed,
              window: _window,
              side: _side,
              onPlayPause: () => _playing ? _pause() : _play(),
              onNext: _stepNext,
              onPrev: _stepPrev,
              onSpeedChanged: (v) {
                // Slider requires onChanged
              },
              onWindowChanged: (w) => setState(() => _window = w),
              onSideChanged: (s) => setState(() => _side = s),
              onResetLevels: () => setState(() {
                _entry = null;
                _sl = null;
                _tp = null;
              }),
              onSaveTrade: _addTrade,
              entry: _entry,
              sl: _sl,
              tp: _tp,
            ),
          ),
          Expanded(
            flex: 5,
            child: _TradesPanel(trades: _trades, onDelete: _deleteTrade),
          ),
        ],
      ),
    );
  }
}
