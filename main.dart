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
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
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
      _showMsg("CSV invalid. Required: Date,Open,High,Low,Close");
      return;
    }

    final candles = <Candle>[];
    final df = DateFormat("MM/dd/yyyy HH:mm");

    for (int i = 1; i < rows.length; i++) {
      final r = rows[i];
      if (r.length < header.length) continue;
      try {
        final dateStr = r[idxDate].toString().trim();
        final time = df.parse(dateStr);
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

  double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.parse(v.toString());
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  List<Candle> get _visibleCandles {
    if (_allCandles.isEmpty) return [];
    final end = _index;
    final start = max(0, end - _window + 1);
    return _allCandles.sublist(start, end + 1);
  }

  Candle? get _currentCandle => _allCandles.isEmpty ? null : _allCandles[_index];

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

  double _priceFromTouch(double relativeY, double minP, double maxP) {
    return maxP - (maxP - minP) * relativeY;
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
                setState(() => _speed = v);
                if (_playing) _play();
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

class _TopInfoBar extends StatelessWidget {
  final String csvName;
  final String symbol;
  final String timeframe;
  final int index;
  final int total;
  final DateTime? currentTime;
  final ValueChanged<String> onSymbolChange;

  const _TopInfoBar({
    required this.csvName,
    required this.symbol,
    required this.timeframe,
    required this.index,
    required this.total,
    required this.currentTime,
    required this.onSymbolChange,
  });

  @override
  Widget build(BuildContext context) {
    final df = DateFormat("yyyy-MM-dd HH:mm");
    return Card(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          runSpacing: 10,
          spacing: 14,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text("CSV: $csvName"),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Symbol: "),
                SizedBox(
                  width: 90,
                  child: TextFormField(
                    initialValue: symbol,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: onSymbolChange,
                  ),
                ),
              ],
            ),
            Text("TF: $timeframe"),
            Text("Candle: ${min(index + 1, total)}/$total"),
            if (currentTime != null) Text("Time: ${df.format(currentTime!)}"),
          ],
        ),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  final List<Candle> candles;
  final double? entry;
  final double? sl;
  final double? tp;
  final ValueChanged<double> onTapSetLevel;

  const _ChartCard({
    required this.candles,
    required this.entry,
    required this.sl,
    required this.tp,
    required this.onTapSetLevel,
  });

  @override
  Widget build(BuildContext context) {
    if (candles.isEmpty) {
      return const Center(child: Text("Import a CSV to start replay ✅"));
    }

    final minP = candles.map((c) => c.low).reduce(min);
    final maxP = candles.map((c) => c.high).reduce(max);

    return Card(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            onTapDown: (d) {
              final y = d.localPosition.dy / constraints.maxHeight;
              onTapSetLevel(y.clamp(0.0, 1.0));
            },
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: LineChart(
                LineChartData(
                  minY: minP,
                  maxY: maxP,
                  gridData: const FlGridData(show: true),
                  titlesData: const FlTitlesData(show: false),
                  borderData: FlBorderData(show: true),
                  lineBarsData: [
                    LineChartBarData(
                      spots: List.generate(
                        candles.length,
                        (i) => FlSpot(i.toDouble(), candles[i].close),
                      ),
                      isCurved: false,
                      dotData: const FlDotData(show: false),
                      barWidth: 2,
                    ),
                  ],
                  extraLinesData: ExtraLinesData(
                    horizontalLines: [
                      if (entry != null)
                        HorizontalLine(
                          y: entry!,
                          strokeWidth: 1.5,
                          dashArray: [8, 4],
                          label: HorizontalLineLabel(
                            show: true,
                            alignment: Alignment.topLeft,
                            labelResolver: (_) => "Entry",
                          ),
                        ),
                      if (sl != null)
                        HorizontalLine(
                          y: sl!,
                          strokeWidth: 1.5,
                          dashArray: [8, 4],
                          label: HorizontalLineLabel(
                            show: true,
                            alignment: Alignment.topLeft,
                            labelResolver: (_) => "SL",
                          ),
                        ),
                      if (tp != null)
                        HorizontalLine(
                          y: tp!,
                          strokeWidth: 1.5,
                          dashArray: [8, 4],
                          label: HorizontalLineLabel(
                            show: true,
                            alignment: Alignment.topLeft,
                            labelResolver: (_) => "TP",
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BottomControls extends StatelessWidget {
  final bool playing;
  final double speed;
  final int window;
  final String side;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final ValueChanged<double> onSpeedChanged;
  final ValueChanged<int> onWindowChanged;
  final ValueChanged<String> onSideChanged;
  final VoidCallback onResetLevels;
  final VoidCallback onSaveTrade;
  final double? entry;
  final double? sl;
  final double? tp;

  const _BottomControls({
    required this.playing,
    required this.speed,
    required this.window,
    required this.side,
    required this.onPlayPause,
    required this.onNext,
    required this.onPrev,
    required this.onSpeedChanged,
    required this.onWindowChanged,
    required this.onSideChanged,
    required this.onResetLevels,
    required this.onSaveTrade,
    required this.entry,
    required this.sl,
    required this.tp,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: onPrev,
                  icon: const Icon(Icons.skip_previous),
                  label: const Text("Prev"),
                ),
                ElevatedButton.icon(
                  onPressed: onPlayPause,
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  label: Text(playing ? "Pause" : "Play"),
                ),
                ElevatedButton.icon(
                  onPressed: onNext,
                  icon: const Icon(Icons.skip_next),
                  label: const Text("Next"),
                ),
                DropdownButton<String>(
                  value: side,
                  items: const [
                    DropdownMenuItem(value: "BUY", child: Text("BUY")),
                    DropdownMenuItem(value: "SELL", child: Text("SELL")),
                  ],
                  onChanged: (v) {
                    if (v != null) onSideChanged(v);
                  },
                ),
                OutlinedButton.icon(
                  onPressed: onResetLevels,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Reset Levels"),
                ),
                FilledButton.icon(
                  onPressed: onSaveTrade,
                  icon: const Icon(Icons.save),
                  label: const Text("Save Trade"),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("Speed: "),
                    Slider(
                      value: speed,
                      min: 1,
                      max: 10,
                      divisions: 9,
                      label: "${speed.toStringAsFixed(0)}x",
                      onChanged: onSpeedChanged,
                    ),
                    Text("${speed.toStringAsFixed(0)}x"),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("Window: "),
                    DropdownButton<int>(
                      value: window,
                      items: const [
                        DropdownMenuItem(value: 60, child: Text("60")),
                        DropdownMenuItem(value: 120, child: Text("120")),
                        DropdownMenuItem(value: 200, child: Text("200")),
                        DropdownMenuItem(value: 400, child: Text("400")),
                      ],
                      onChanged: (v) {
                        if (v != null) onWindowChanged(v);
                      },
                    ),
                  ],
                ),
                Text("Entry: ${entry?.toStringAsFixed(5) ?? "-"}"),
                Text("SL: ${sl?.toStringAsFixed(5) ?? "-"}"),
                Text("TP: ${tp?.toStringAsFixed(5) ?? "-"}"),
                const Text("Tap chart to set Entry → SL → TP"),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TradesPanel extends StatelessWidget {
  final List<Trade> trades;
  final Future<void> Function(String id) onDelete;

  const _TradesPanel({required this.trades, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    if (trades.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: Text("No trades saved yet. Save trades ✅")),
      );
    }

    final df = DateFormat("yyyy-MM-dd HH:mm");

    return Card(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: ListView.separated(
        itemCount: trades.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final t = trades[i];
          return ListTile(
            title: Text("${t.symbol} ${t.timeframe} | ${t.side} | ${t.entry.toStringAsFixed(5)}"),
            subtitle: Text("${df.format(t.time)} | SL: ${t.sl.toStringAsFixed(5)} TP: ${t.tp.toStringAsFixed(5)}"),
            trailing: IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => onDelete(t.id),
            ),
          );
        },
      ),
    );
  }
}
