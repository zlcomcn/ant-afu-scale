import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import '../ble/ble_service.dart';
import '../models/scale_data.dart';
import 'history_storage.dart';

/// 首页：历史记录 + 自动连接蓝牙 + 测量 BottomSheet
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

// 测量阶段
enum MeasurePhase { measuring, complete }

class MeasureState {
  final MeasurePhase phase;
  final ScaleMeasurement? m;
  const MeasureState(this.phase, this.m);
}

class _HistoryScreenState extends State<HistoryScreen> {
  final BleScaleService _ble = BleScaleService.shared;
  List<ScaleMeasurement> _records = [];
  bool _loading = true;
  bool _autoConnecting = false;
  bool _bleConnected = false;

  // 测量 sheet 状态
  final ValueNotifier<MeasureState?> _measure =
      ValueNotifier<MeasureState?>(null);
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
    _tryAutoConnect();
  }

  @override
  void dispose() {
    _measure.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final records = await HistoryStorage.load();
    if (mounted) setState(() { _records = records; _loading = false; });
  }

  Future<void> _tryAutoConnect() async {
    final last = await _ble.getLastDevice();
    if (last == null || !mounted) return;
    setState(() => _autoConnecting = true);
    _setupListeners();
    final ok = await _ble.connect(last);
    if (!mounted) return;
    setState(() {
      _autoConnecting = false;
      _bleConnected = ok;
    });
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Row(children: [Icon(Icons.check_circle, color: Colors.white, size: 20), SizedBox(width: 8), Expanded(child: Text('已连接，请站上体脂秤'))]),
        behavior: SnackBarBehavior.floating, backgroundColor: Colors.teal, duration: Duration(seconds: 2),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Row(children: [Icon(Icons.bluetooth_disabled, color: Colors.white, size: 20), SizedBox(width: 8), Expanded(child: Text('上次设备连接失败，请手动扫描'))]),
        behavior: SnackBarBehavior.floating, backgroundColor: Colors.red.shade700, duration: const Duration(seconds: 4),
        action: SnackBarAction(label: '扫描', textColor: Colors.white, onPressed: () => Navigator.pushNamed(context, '/scan').then((_) { _setupListeners(); _load(); })),
      ));
    }
  }

  /// 绑定测量生命周期回调 (复刻逆向 ICWeightScale27Worker: 开始/进行/判稳/离秤保存)
  void _setupListeners() {
    _ble.onConnectionChange = (c) {
      if (mounted) setState(() => _bleConnected = c);
    };
    // 站上秤 → 弹出 BottomSheet
    _ble.onMeasureStart = () {
      _measure.value = const MeasureState(MeasurePhase.measuring, null);
      _openSheet();
    };
    // 实时体重刷新
    _ble.onMeasureUpdate = (m) {
      // 已锁定(complete)后不被后续帧覆盖回 measuring
      final cur = _measure.value;
      if (cur?.phase == MeasurePhase.complete) {
        _measure.value = MeasureState(MeasurePhase.complete, m);
      } else {
        _measure.value = MeasureState(MeasurePhase.measuring, m);
      }
    };
    // 判稳 → 测量完成，立即保存 (每个测量周期只触发一次，天然去重、无延迟)
    _ble.onMeasureComplete = (m) {
      _measure.value = MeasureState(MeasurePhase.complete, m);
      _saveResult(m);
    };
    // 离秤: 仅重置状态，不保存 (保存已在判稳时完成)。BottomSheet 不自动收起。
    _ble.onMeasureReset = (_) {
      // 保留上一帧显示值，仅回到"称重中"状态提示 (不清零、不关闭)
      final cur = _measure.value;
      if (cur?.phase == MeasurePhase.complete) {
        // 已完成并保存过 → 保持显示最终结果，等待用户手动关闭或再次测量
        return;
      }
      _measure.value = MeasureState(MeasurePhase.measuring, cur?.m);
    };
  }

  void _saveResult(ScaleMeasurement m) {
    if (m.weightKg <= 1.0) return;
    HistoryStorage.save(m);
    _updateHomeWidget(m);
    _load();
  }

  void _openSheet() {
    if (_sheetOpen || !mounted) return;
    _sheetOpen = true;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MeasureSheet(measure: _measure, log: () => _ble.recentLogs.join('\n')),
    ).whenComplete(() => _sheetOpen = false);
  }

  Future<void> _updateHomeWidget(ScaleMeasurement m) async {
    try {
      await HomeWidget.saveWidgetData<String>('weight', m.weightKg.toStringAsFixed(2));
      await HomeWidget.saveWidgetData<String>('bodyFat', m.bodyFatPercent.toStringAsFixed(1));
      await HomeWidget.saveWidgetData<String>('bmi', m.bmi.toStringAsFixed(1));
      await HomeWidget.saveWidgetData<String>('muscle', m.musclePercent.toStringAsFixed(1));
      final now = DateTime.now();
      await HomeWidget.saveWidgetData<String>('time', '${now.month.toString().padLeft(2,'0')}-${now.day.toString().padLeft(2,'0')} ${now.hour.toString().padLeft(2,'0')}:${now.minute.toString().padLeft(2,'0')}');
      for (final name in ['ScaleWidgetProvider', 'ScaleWidget1x1Provider', 'ScaleWidget1x2Provider']) {
        await HomeWidget.updateWidget(androidName: name, qualifiedAndroidName: 'com.example.scale_app.$name');
      }
    } catch (_) {}
  }

  void _showProfileDialog() {
    final hCtrl = TextEditingController(text: '170');
    final aCtrl = TextEditingController(text: '30');
    final wCtrl = TextEditingController(text: '70');
    int g = 1;
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
      title: const Text('个人资料'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<int>(value: g, decoration: const InputDecoration(labelText: '性别'), items: const [DropdownMenuItem(value: 1, child: Text('男')), DropdownMenuItem(value: 0, child: Text('女'))], onChanged: (v) => setD(() => g = v ?? 1)),
        TextField(controller: hCtrl, decoration: const InputDecoration(labelText: '身高 (cm)'), keyboardType: TextInputType.number),
        TextField(controller: aCtrl, decoration: const InputDecoration(labelText: '年龄'), keyboardType: TextInputType.number),
        TextField(controller: wCtrl, decoration: const InputDecoration(labelText: '参考体重 (kg)'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () {
          _ble.setUserInfo(heightCm: int.tryParse(hCtrl.text), age: int.tryParse(aCtrl.text), gender: g, weightKg: double.tryParse(wCtrl.text));
          Navigator.pop(ctx);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('资料已保存'), behavior: SnackBarBehavior.floating));
        }, child: const Text('保存')),
      ],
    )));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('体脂秤'),
          if (_bleConnected) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: Colors.teal.shade100, borderRadius: BorderRadius.circular(10)),
              child: Text('已连接', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.teal.shade800)),
            ),
          ],
        ]),
        centerTitle: true,
        actions: [
          if (_records.isNotEmpty) IconButton(icon: const Icon(Icons.delete_sweep), tooltip: '清空', onPressed: () async {
            final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('确认清空'), content: const Text('删除全部历史记录？'), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定'))]));
            if (ok == true) { await HistoryStorage.clearAll(); _load(); }
          }),
          IconButton(icon: const Icon(Icons.person_outline), tooltip: '个人资料', onPressed: _showProfileDialog),
          IconButton(icon: const Icon(Icons.bluetooth_searching), tooltip: '扫描设备', onPressed: () {
            Navigator.pushNamed(context, '/scan').then((_) { _setupListeners(); _load(); });
          }),
        ],
      ),
      body: _records.isEmpty ? _buildEmpty() : _buildList(),
    );
  }

  Widget _buildEmpty() => Center(child: Padding(padding: const EdgeInsets.all(40), child: Column(mainAxisSize: MainAxisSize.min, children: [
    Container(padding: const EdgeInsets.all(28), decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.teal.shade50, Colors.blue.shade50], begin: Alignment.topLeft, end: Alignment.bottomRight), shape: BoxShape.circle), child: Icon(Icons.monitor_weight, size: 64, color: Colors.teal.shade300)),
    const SizedBox(height: 24),
    Text('欢迎使用体脂秤', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.grey.shade800)),
    const SizedBox(height: 8),
    Text('站上体脂秤开始第一次测量\n数据将自动保存在这里', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Colors.grey.shade500, height: 1.5)),
    const SizedBox(height: 32),
    if (_autoConnecting) ...[const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 2.5)), const SizedBox(height: 12), Text('正在连接上次设备...', style: TextStyle(color: Colors.grey.shade600))] else ...[FilledButton.icon(onPressed: () { Navigator.pushNamed(context, '/scan').then((_) { _setupListeners(); _load(); }); }, icon: const Icon(Icons.bluetooth_searching), label: const Text('扫描蓝牙设备'), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14)))],
  ])));

  Widget _buildList() => ListView.builder(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    itemCount: _records.length,
    itemBuilder: (ctx, i) => Dismissible(
      key: Key('hist_${_records[i].measuredAt.millisecondsSinceEpoch}'),
      direction: DismissDirection.endToStart,
      background: Container(alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), margin: const EdgeInsets.symmetric(vertical: 4), decoration: BoxDecoration(color: Colors.red.shade300, borderRadius: BorderRadius.circular(14)), child: const Icon(Icons.delete_outline, color: Colors.white, size: 24)),
      confirmDismiss: (_) async { await HistoryStorage.delete(i); _load(); return false; },
      child: _buildRow(_records[i]),
    ),
  );

  Widget _buildRow(ScaleMeasurement m) {
    final date = '${m.measuredAt.month.toString().padLeft(2,'0')}-${m.measuredAt.day.toString().padLeft(2,'0')} ${m.measuredAt.hour.toString().padLeft(2,'0')}:${m.measuredAt.minute.toString().padLeft(2,'0')}';
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: ClipRRect(borderRadius: BorderRadius.circular(14), child: Material(color: Colors.grey.shade100, child: InkWell(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _DetailPage(m: m))), child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(m.weightKg.toStringAsFixed(2), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, height: 1.0)),
        const SizedBox(width: 4), const Padding(padding: EdgeInsets.only(bottom: 4), child: Text('kg', style: TextStyle(fontSize: 14, color: Colors.grey))),
        const Spacer(),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(date, style: const TextStyle(fontSize: 12, color: Colors.black45)), const SizedBox(height: 2), Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade400)]),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 5, runSpacing: 5, children: [
        _pill('BMI  ${m.bmi.toStringAsFixed(1)}', _bmiLabel(m.bmi)),
        _pill('体脂  ${m.bodyFatPercent.toStringAsFixed(1)}%', _bodyFatLabel(m.bodyFatPercent, m.gender)),
        _pill('肌肉  ${m.musclePercent.toStringAsFixed(1)}%', _muscleLabel(m.musclePercent)),
        _pill('水分  ${m.moisturePercent.toStringAsFixed(1)}%', _waterLabel(m.moisturePercent)),
      ]),
    ]))))));
  }

  Widget _pill(String text, String label) {
    final c = label == '优' ? Colors.teal : label == '偏高' ? Colors.orange : label == '偏低' ? Colors.blue : Colors.grey;
    return Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: c.shade50, borderRadius: BorderRadius.circular(10)), child: Text('$text  $label', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: c.shade700)));
  }

  String _bodyFatLabel(double bf, int g) { if (g == 0) { if (bf < 11) return '偏低'; if (bf <= 21) return '优'; if (bf <= 25) return '标准'; return '偏高'; } if (bf < 21) return '偏低'; if (bf <= 31) return '优'; if (bf <= 35) return '标准'; return '偏高'; }
  String _bmiLabel(double v) { if (v < 18.5) return '偏低'; if (v <= 24.9) return '优'; if (v <= 28) return '标准'; return '偏高'; }
  String _muscleLabel(double v) { if (v < 60) return '偏低'; if (v <= 78) return '标准'; return '优'; }
  String _waterLabel(double v) { if (v < 45) return '偏低'; if (v <= 65) return '优'; return '标准'; }
}

// ═══════════════════════════════════════════
//  测量 BOTTOM SHEET (由生命周期回调驱动)
// ═══════════════════════════════════════════

class _MeasureSheet extends StatefulWidget {
  final ValueNotifier<MeasureState?> measure;
  final String Function() log;
  const _MeasureSheet({required this.measure, required this.log});

  @override
  State<_MeasureSheet> createState() => _MeasureSheetState();
}

class _MeasureSheetState extends State<_MeasureSheet> {
  int _tapCount = 0;
  Timer? _tapReset;

  @override
  void dispose() {
    _tapReset?.cancel();
    super.dispose();
  }

  // 连续点击 5 次 → 信息框(Dialog)日志弹窗 (非 BottomSheet)
  void _onTap() {
    _tapCount++;
    _tapReset?.cancel();
    _tapReset = Timer(const Duration(seconds: 2), () => _tapCount = 0);
    if (_tapCount >= 5) {
      _tapCount = 0;
      _showLogDialog();
    }
  }

  void _showLogDialog() {
    final log = widget.log();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Row(children: [
        const Icon(Icons.article_outlined, size: 20),
        const SizedBox(width: 8),
        const Text('连接日志', style: TextStyle(fontSize: 17)),
        const Spacer(),
        IconButton(icon: const Icon(Icons.copy, size: 18), tooltip: '复制', onPressed: () {
          Clipboard.setData(ClipboardData(text: log));
          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('已复制'), behavior: SnackBarBehavior.floating, duration: Duration(seconds: 1)));
        }),
      ]),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      content: SizedBox(width: double.maxFinite, child: Container(
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxHeight: 380),
        decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(10)),
        child: SingleChildScrollView(child: Text(log.trim().isEmpty ? '暂无日志' : log, style: const TextStyle(fontSize: 10, fontFamily: 'monospace', height: 1.4))),
      )),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: ValueListenableBuilder<MeasureState?>(
          valueListenable: widget.measure,
          builder: (ctx, state, _) {
            final phase = state?.phase ?? MeasurePhase.measuring;
            final m = state?.m;
            final stable = phase == MeasurePhase.complete;
            return ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
              children: [
                Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                const SizedBox(height: 16),
                _statusPill(stable),
                const SizedBox(height: 20),
                GestureDetector(onTap: _onTap, child: _weightCard(m, stable)),
                const SizedBox(height: 20),
                if (m != null && stable) _composition(m),
                if (m != null && !stable) Padding(padding: const EdgeInsets.only(top: 20), child: Center(child: Text('请保持站立不动，正在测量...', style: TextStyle(color: Colors.grey.shade500, fontSize: 13)))),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _statusPill(bool stable) => Center(child: AnimatedContainer(
    duration: const Duration(milliseconds: 300),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
    decoration: BoxDecoration(color: stable ? Colors.teal.shade50 : Colors.orange.shade50, borderRadius: BorderRadius.circular(22), border: Border.all(color: (stable ? Colors.teal : Colors.orange).shade200, width: 0.5)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(stable ? Icons.check_circle : Icons.hourglass_empty, color: stable ? Colors.teal : Colors.orange, size: 18),
      const SizedBox(width: 6),
      Text(stable ? '测量完成' : '称重中...', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: stable ? Colors.teal.shade700 : Colors.orange.shade700)),
    ]),
  ));

  Widget _weightCard(ScaleMeasurement? m, bool stable) {
    final color = stable ? Colors.teal : Colors.blue;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(colors: [color.withValues(alpha: 0.08), color.withValues(alpha: 0.03)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        border: Border.all(color: color.withValues(alpha: 0.14), width: 1),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.06), blurRadius: 20, offset: const Offset(0, 4))],
      ),
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 24), child: Column(children: [
        Text((m?.weightKg ?? 0).toStringAsFixed(2), style: TextStyle(fontSize: 72, fontWeight: FontWeight.w800, color: color, height: 1.1)),
        const SizedBox(height: 4),
        Text('kg', style: TextStyle(fontSize: 15, color: Colors.grey.shade500)),
        if ((m?.hr ?? 0) > 0) ...[const SizedBox(height: 6), Text('❤️ ${m!.hr} bpm', style: TextStyle(fontSize: 13, color: Colors.red.shade400))],
      ])),
    );
  }

  Widget _composition(ScaleMeasurement m) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (m.bodyScore > 0) Center(child: Padding(padding: const EdgeInsets.only(bottom: 16), child: Column(children: [
        Text(m.bodyScore.toStringAsFixed(0), style: TextStyle(fontSize: 44, fontWeight: FontWeight.w800, color: m.bodyScore >= 80 ? Colors.teal : m.bodyScore >= 60 ? Colors.orange : Colors.red.shade400)),
        Text('身体评分', style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
      ]))),
      _section('核心指标', [
        _metric('体脂率', '${m.bodyFatPercent.toStringAsFixed(1)}%', _bf(m.bodyFatPercent, m.gender)),
        _metric('BMI', m.bmi.toStringAsFixed(1), _bmi(m.bmi)),
        _metric('基础代谢', '${m.bmr.toStringAsFixed(0)} kcal', _bmr(m.bmr, m.gender)),
      ]),
      const SizedBox(height: 12),
      _section('身体构成', [
        _metric('肌肉量', '${m.muscleKg.toStringAsFixed(2)} kg', null),
        _metric('骨量', '${m.boneMass.toStringAsFixed(2)} kg', _bone(m.boneMass, m.gender)),
        _metric('体水分量', '${m.waterKg.toStringAsFixed(2)} kg', null),
        _metric('蛋白量', '${m.proteinKg.toStringAsFixed(2)} kg', null),
      ]),
      const SizedBox(height: 12),
      _section('比率', [
        _metric('肌肉率', '${m.musclePercent.toStringAsFixed(1)}%', _mu(m.musclePercent)),
        _metric('骨骼肌率', '${m.skeletalMusclePercent.toStringAsFixed(1)}%', _skm(m.skeletalMusclePercent, m.gender)),
        _metric('水分率', '${m.moisturePercent.toStringAsFixed(1)}%', _wa(m.moisturePercent)),
        _metric('蛋白质率', '${m.proteinPercent.toStringAsFixed(1)}%', _pro(m.proteinPercent)),
        _metric('皮下脂肪率', '${m.subcutaneousFatPercent.toStringAsFixed(1)}%', _sub(m.subcutaneousFatPercent, m.gender)),
      ]),
      if (m.visceralFat > 0) ...[const SizedBox(height: 12), _section('其他', [
        _metric('内脏脂肪', '${m.visceralFat.toStringAsFixed(1)} 级', _vis(m.visceralFat)),
        if (m.bodyAge > 0) _metric('身体年龄', '${m.bodyAge.toStringAsFixed(0)} 岁', null),
      ])],
    ]);
  }

  Widget _section(String t, List<Widget> c) => Container(width: double.infinity, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(14)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey.shade500, letterSpacing: 1)), const SizedBox(height: 10), ...c]));

  Widget _metric(String l, String v, String? r) => Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
    Text(l, style: TextStyle(fontSize: 14, color: Colors.grey.shade700)),
    Row(mainAxisSize: MainAxisSize.min, children: [
      Text(v, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      if (r != null) ...[const SizedBox(width: 8), _badge(r)],
    ]),
  ]));

  Widget _badge(String r) { final c = r == '优' ? Colors.teal : r == '标准' ? Colors.blue : r == '偏低' ? Colors.indigo : Colors.orange; return Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)), child: Text(r, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c))); }

  String _bf(double v, int g) { if (g == 0) { if (v < 11) return '偏低'; if (v <= 21) return '优'; if (v <= 25) return '标准'; return '偏高'; } if (v < 21) return '偏低'; if (v <= 31) return '优'; if (v <= 35) return '标准'; return '偏高'; }
  String _bmi(double v) { if (v < 18.5) return '偏低'; if (v <= 24.9) return '优'; if (v <= 28) return '标准'; return '偏高'; }
  String _mu(double v) { if (v < 60) return '偏低'; if (v <= 78) return '标准'; return '优'; }
  String _wa(double v) { if (v < 45) return '偏低'; if (v <= 65) return '优'; return '标准'; }
  // 基础代谢: 高于标准为优 (代谢旺盛)
  String _bmr(double v, int g) { final base = g == 1 ? 1500.0 : 1200.0; if (v < base * 0.9) return '偏低'; if (v >= base) return '优'; return '标准'; }
  // 骨量: 依性别与体重的正常范围
  String _bone(double v, int g) { final lo = g == 1 ? 2.5 : 1.8; final hi = g == 1 ? 3.5 : 2.8; if (v < lo) return '偏低'; if (v <= hi) return '优'; return '偏高'; }
  // 骨骼肌率
  String _skm(double v, int g) { final lo = g == 1 ? 49.0 : 40.0; final hi = g == 1 ? 59.0 : 50.0; if (v < lo) return '偏低'; if (v <= hi) return '优'; return '偏高'; }
  // 蛋白质率: 16~20% 为优
  String _pro(double v) { if (v < 16) return '偏低'; if (v <= 20) return '优'; return '偏高'; }
  // 皮下脂肪率
  String _sub(double v, int g) { if (g == 0) { if (v < 18) return '偏低'; if (v <= 28) return '优'; return '偏高'; } if (v < 8) return '偏低'; if (v <= 17) return '优'; return '偏高'; }
  // 内脏脂肪等级: 1~9 优, 10~14 标准, ≥15 偏高
  String _vis(double v) { if (v < 1) return '偏低'; if (v <= 9) return '优'; if (v <= 14) return '标准'; return '偏高'; }
}

// ═══════════════════════════════════════════
//  DETAIL PAGE
// ═══════════════════════════════════════════

class _DetailPage extends StatelessWidget {
  final ScaleMeasurement m;
  const _DetailPage({required this.m});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('测量详情'), centerTitle: true),
    body: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(children: [
      if (m.bodyScore > 0) _score(),
      const SizedBox(height: 16),
      Row(children: [_sc('体脂率', '${m.bodyFatPercent.toStringAsFixed(1)}%', _bf(m.bodyFatPercent, m.gender), Colors.orange), const SizedBox(width: 12), _sc('BMI', m.bmi.toStringAsFixed(1), _bmi(m.bmi), Colors.blue), const SizedBox(width: 12), _sc('基础代谢', '${m.bmr.toStringAsFixed(0)} kcal', _bmr(m.bmr, m.gender), Colors.teal)]),
      const SizedBox(height: 16),
      _sect('身体构成', [_r('体重', '${m.weightKg.toStringAsFixed(2)} kg'), _r('肌肉量', '${m.muscleKg.toStringAsFixed(2)} kg'), _r('骨量', '${m.boneMass.toStringAsFixed(2)} kg', _bone(m.boneMass, m.gender)), _r('体水分量', '${m.waterKg.toStringAsFixed(2)} kg'), _r('蛋白量', '${m.proteinKg.toStringAsFixed(2)} kg')]),
      const SizedBox(height: 16),
      _sect('各项比率', [_r('肌肉率', '${m.musclePercent.toStringAsFixed(1)}%', _mu(m.musclePercent)), _r('骨骼肌率', '${m.skeletalMusclePercent.toStringAsFixed(1)}%', _skm(m.skeletalMusclePercent, m.gender)), _r('水分率', '${m.moisturePercent.toStringAsFixed(1)}%', _wa(m.moisturePercent)), _r('蛋白质率', '${m.proteinPercent.toStringAsFixed(1)}%', _pro(m.proteinPercent)), _r('皮下脂肪率', '${m.subcutaneousFatPercent.toStringAsFixed(1)}%', _sub(m.subcutaneousFatPercent, m.gender))]),
      if (m.visceralFat > 0) ...[const SizedBox(height: 16), _sect('其他', [_r('内脏脂肪', '${m.visceralFat.toStringAsFixed(1)} 级', _vis(m.visceralFat)), if (m.bodyAge > 0) _r('身体年龄', '${m.bodyAge.toStringAsFixed(0)} 岁'), if (m.bodyScore > 0) _r('身体评分', m.bodyScore.toStringAsFixed(0))])],
    ])),
  );

  Widget _score() { final c = m.bodyScore >= 80 ? Colors.teal : m.bodyScore >= 60 ? Colors.orange : Colors.red; final date = '${m.measuredAt.year}-${m.measuredAt.month.toString().padLeft(2,'0')}-${m.measuredAt.day.toString().padLeft(2,'0')} ${m.measuredAt.hour.toString().padLeft(2,'0')}:${m.measuredAt.minute.toString().padLeft(2,'0')}'; return Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 24), decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), gradient: LinearGradient(colors: [c.withValues(alpha: 0.06), c.withValues(alpha: 0.02)], begin: Alignment.topLeft, end: Alignment.bottomRight), border: Border.all(color: c.withValues(alpha: 0.12))), child: Column(children: [Text(m.bodyScore.toStringAsFixed(0), style: TextStyle(fontSize: 52, fontWeight: FontWeight.w800, color: c, height: 1.1)), const SizedBox(height: 2), Text(date, style: const TextStyle(color: Colors.grey, fontSize: 13)), const SizedBox(height: 6), Text('身体评分', style: TextStyle(fontSize: 12, color: Colors.grey.shade500))])); }
  Widget _sc(String l, String v, String? r, Color c) => Expanded(child: Container(height: 92, padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6), decoration: BoxDecoration(color: c.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(14), border: Border.all(color: c.withValues(alpha: 0.12))), child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(v, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c), textAlign: TextAlign.center), Text(l, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)), if (r != null) _badge(r) else const SizedBox(height: 16)])));
  Widget _badge(String r) { final c = r == '优' ? Colors.teal : r == '标准' ? Colors.blue : r == '偏低' ? Colors.indigo : Colors.orange; return Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)), child: Text(r, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: c))); }
  Widget _sect(String t, List<Widget> c) => Container(width: double.infinity, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(14)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey.shade500, letterSpacing: 1)), const SizedBox(height: 8), ...c]));
  Widget _r(String l, String v, [String? r]) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l, style: TextStyle(fontSize: 14, color: Colors.grey.shade700)), Row(mainAxisSize: MainAxisSize.min, children: [Text(v, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)), if (r != null) ...[const SizedBox(width: 8), _badge(r)]])]));

  static String _bf(double v, int g) { if (g == 0) { if (v < 11) return '偏低'; if (v <= 21) return '优'; if (v <= 25) return '标准'; return '偏高'; } if (v < 21) return '偏低'; if (v <= 31) return '优'; if (v <= 35) return '标准'; return '偏高'; }
  static String _bmi(double v) { if (v < 18.5) return '偏低'; if (v <= 24.9) return '优'; if (v <= 28) return '标准'; return '偏高'; }
  static String _mu(double v) { if (v < 60) return '偏低'; if (v <= 78) return '标准'; return '优'; }
  static String _wa(double v) { if (v < 45) return '偏低'; if (v <= 65) return '优'; return '标准'; }
  static String _bmr(double v, int g) { final base = g == 1 ? 1500.0 : 1200.0; if (v < base * 0.9) return '偏低'; if (v >= base) return '优'; return '标准'; }
  static String _bone(double v, int g) { final lo = g == 1 ? 2.5 : 1.8; final hi = g == 1 ? 3.5 : 2.8; if (v < lo) return '偏低'; if (v <= hi) return '优'; return '偏高'; }
  static String _skm(double v, int g) { final lo = g == 1 ? 49.0 : 40.0; final hi = g == 1 ? 59.0 : 50.0; if (v < lo) return '偏低'; if (v <= hi) return '优'; return '偏高'; }
  static String _pro(double v) { if (v < 16) return '偏低'; if (v <= 20) return '优'; return '偏高'; }
  static String _sub(double v, int g) { if (g == 0) { if (v < 18) return '偏低'; if (v <= 28) return '优'; return '偏高'; } if (v < 8) return '偏低'; if (v <= 17) return '优'; return '偏高'; }
  static String _vis(double v) { if (v < 1) return '偏低'; if (v <= 9) return '优'; if (v <= 14) return '标准'; return '偏高'; }
}
