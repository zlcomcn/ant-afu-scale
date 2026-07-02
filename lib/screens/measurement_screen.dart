import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import '../ble/ble_service.dart';
import '../models/scale_data.dart';
import 'history_storage.dart';

/// 实时测量页面
class MeasurementScreen extends StatefulWidget {
  final BleScaleService bleService;

  const MeasurementScreen({super.key, required this.bleService});

  @override
  State<MeasurementScreen> createState() => _MeasurementScreenState();
}

class _MeasurementScreenState extends State<MeasurementScreen> {
  ScaleMeasurement? _current;
  final List<ScaleMeasurement> _history = [];
  bool _connected = true;
  String _log = '';

  Timer? _refreshTimer;
  Timer? _saveDebounce;
  ScaleMeasurement? _pendingSave;

  // ── secret log tap ──
  int _weightTapCount = 0;
  Timer? _tapResetTimer;

  @override
  void initState() {
    super.initState();

    widget.bleService.onMeasurement = (m) {
      if (mounted) {
        setState(() {
          _current = m;
        });
        _debounceSave(m);
      }
    };
    widget.bleService.onConnectionChange = (connected) {
      if (mounted) {
        setState(() => _connected = connected);
      }
    };
    widget.bleService.onLog = (msg) {
      if (mounted) {
        setState(() {
          _log = '$msg\n$_log'.split('\n').take(80).join('\n');
        });
      }
    };
    _log = widget.bleService.recentLogs.join('\n');
  }

  void _debounceSave(ScaleMeasurement m) {
    if (m.weightKg <= 1.0) return;
    _pendingSave = m;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () {
      if (_pendingSave != null && mounted) {
        final toSave = _pendingSave!;
        _history.add(toSave);
        HistoryStorage.save(toSave);
        _updateHomeWidget(toSave);
        _pendingSave = null;
      }
    });
  }

  void _onWeightTap() {
    _weightTapCount++;
    _tapResetTimer?.cancel();
    _tapResetTimer = Timer(const Duration(seconds: 2), () {
      _weightTapCount = 0;
    });
    if (_weightTapCount >= 5) {
      _weightTapCount = 0;
      _showLogSheet();
    }
  }

  void _showLogSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (ctx, scrollCtrl) => Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text('连接日志',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: () => Clipboard.setData(
                        ClipboardData(text: _log)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListView(
                  controller: scrollCtrl,
                  children: [
                    Text(
                      _log.trim().isEmpty ? '暂无日志' : _log,
                      style:
                          const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _tapResetTimer?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  // ═══════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final title = _current == null
        ? '测量中'
        : _connected
            ? '体重 ${_current!.weightKg.toStringAsFixed(1)} kg'
            : '已断开';
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 17)),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _disconnect,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '历史记录',
            onPressed: () => Navigator.pushNamed(context, '/history'),
          ),
          IconButton(
            icon: Icon(Icons.bluetooth_connected,
                color: _connected ? Colors.teal : Colors.red),
            onPressed: null,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Future<void> _disconnect() async {
    await widget.bleService.disconnect();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/scan');
    }
  }

  Widget _buildBody() {
    if (_current == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.accessibility_new, size: 72, color: Colors.teal),
            SizedBox(height: 16),
            Text('请站在体脂秤上开始测量',
                style: TextStyle(fontSize: 17)),
            SizedBox(height: 12),
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ],
        ),
      );
    }

    final m = _current!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        children: [
          _buildWeightCard(),
          const SizedBox(height: 12),
          _buildStableIndicator(m.isStabilized),
          const SizedBox(height: 20),
          if (m.isStabilized) ...[
            _buildBodyComposition(m),
            const SizedBox(height: 16),
          ],
          if (m.impedances.isNotEmpty) _buildImpedanceCard(m),
        ],
      ),
    );
  }

  // ═══ 体重卡片 — 液态玻璃 (静态) ═══

  Widget _buildWeightCard() {
    final color = (_current?.isStabilized ?? false) ? Colors.teal : Colors.blue;
    return GestureDetector(
      onTap: _onWeightTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(
            colors: [
              color.withValues(alpha: 0.08),
              color.withValues(alpha: 0.03),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(
            color: color.withValues(alpha: 0.14),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.06),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          children: [
            // 顶部高光
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 70,
              child: Container(
                decoration: const BoxDecoration(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  gradient: LinearGradient(
                    colors: [Color(0x30FFFFFF), Color(0x00FFFFFF)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            ),
            // 内容
            Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 30, horizontal: 24),
              child: Column(
                children: [
                  _weightDisplay(),
                  const SizedBox(height: 4),
                  Text('kg',
                      style: TextStyle(
                          fontSize: 15, color: Colors.grey.shade500)),
                  if ((_current?.hr ?? 0) > 0) ...[
                    const SizedBox(height: 6),
                    Text('❤️ ${_current!.hr} bpm',
                        style: TextStyle(
                            fontSize: 13, color: Colors.red.shade400)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _weightDisplay() {
    final color =
        (_current?.isStabilized ?? false) ? Colors.teal : Colors.blue;
    return Text(
      (_current?.weightKg ?? 0).toStringAsFixed(2),
      style: TextStyle(
        fontSize: 72,
        fontWeight: FontWeight.w800,
        color: color,
        height: 1.1,
      ),
    );
  }

  // ═══ 稳定指示器 ═══

  Widget _buildStableIndicator(bool stable) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: BoxDecoration(
        color: stable ? Colors.teal.shade50 : Colors.orange.shade50,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: (stable ? Colors.teal : Colors.orange).shade200,
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            stable ? Icons.check_circle : Icons.hourglass_empty,
            color: stable ? Colors.teal : Colors.orange,
            size: 18,
          ),
          const SizedBox(width: 6),
          Text(
            stable ? '测量稳定' : '称重中...',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: stable ? Colors.teal.shade700 : Colors.orange.shade700,
            ),
          ),
        ],
      ),
    );
  }

  // ═══ 体成份卡片 (无边框) ═══

  Widget _buildBodyComposition(ScaleMeasurement m) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text('体成份',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade800)),
        ),
        // 身体评分
        if (m.bodyScore > 0) ...[
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                children: [
                  Text(
                    m.bodyScore.toStringAsFixed(0),
                    style: TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w800,
                      color: m.bodyScore >= 80
                          ? Colors.teal
                          : m.bodyScore >= 60
                              ? Colors.orange
                              : Colors.red.shade400,
                    ),
                  ),
                  Text('身体评分',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                ],
              ),
            ),
          ),
        ],
        // 指标行
        _buildMetricSection('核心指标', [
          _metric('体脂率', '${m.bodyFatPercent.toStringAsFixed(1)}%',
              _bodyFatLabel(m.bodyFatPercent, _gender())),
          _metric('BMI', m.bmi.toStringAsFixed(1), _bmiLabel(m.bmi)),
          _metric('基础代谢', '${m.bmr.toStringAsFixed(0)} kcal', null),
        ]),
        const SizedBox(height: 12),
        _buildMetricSection('身体构成', [
          _metric('肌肉量', '${m.muscleKg.toStringAsFixed(2)} kg', null),
          _metric('骨量', '${m.boneMass.toStringAsFixed(2)} kg',
              _boneLabel(m.boneMass, _gender())),
          _metric('体水分量', '${m.waterKg.toStringAsFixed(2)} kg', null),
          _metric('蛋白量', '${m.proteinKg.toStringAsFixed(2)} kg', null),
        ]),
        const SizedBox(height: 12),
        _buildMetricSection('比率', [
          _metric('肌肉率', '${m.musclePercent.toStringAsFixed(1)}%',
              _muscleLabel(m.musclePercent, _gender())),
          _metric('骨骼肌率', '${m.skeletalMusclePercent.toStringAsFixed(1)}%',
              _skeletalMuscleLabel(m.skeletalMusclePercent, _gender())),
          _metric('水分率', '${m.moisturePercent.toStringAsFixed(1)}%',
              _waterLabel(m.moisturePercent, _gender())),
          _metric('蛋白质率', '${m.proteinPercent.toStringAsFixed(1)}%',
              _proteinLabel(m.proteinPercent)),
          _metric('皮下脂肪率', '${m.subcutaneousFatPercent.toStringAsFixed(1)}%', null),
        ]),
        if (m.visceralFat > 0) ...[
          const SizedBox(height: 12),
          _buildMetricSection('其他', [
            _metric('内脏脂肪', '${m.visceralFat.toStringAsFixed(1)} 级',
                _visceralLabel(m.visceralFat)),
            if (m.bodyAge > 0)
              _metric('身体年龄', '${m.bodyAge.toStringAsFixed(0)} 岁', null),
          ]),
        ],
      ],
    );
  }

  Widget _buildMetricSection(String title, List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade500,
                  letterSpacing: 1)),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _metric(String label, String value, String? rating) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style:
                  TextStyle(fontSize: 14, color: Colors.grey.shade700)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              if (rating != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: _labelColor(rating).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(rating,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _labelColor(rating))),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // ═══ 阻抗 ═══

  Widget _buildImpedanceCard(ScaleMeasurement m) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('多频阻抗',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade500,
                  letterSpacing: 1)),
          const SizedBox(height: 8),
          for (int i = 0; i < m.impedances.length; i++)
            _metric('频率 ${i + 1}', '${m.impedances[i].toStringAsFixed(0)} Ω', null),
        ],
      ),
    );
  }

  // ═══ helpers ═══

  Color _labelColor(String label) => switch (label) {
        '优' => Colors.teal,
        '标准' => Colors.blue,
        '偏高' || '偏低' => Colors.orange,
        _ => Colors.grey,
      };

  int _gender() => 1;

  String _bodyFatLabel(double v, int gender) {
    if (gender == 1) {
      if (v < 10) return '偏低';
      if (v <= 20) return '标准';
      if (v <= 25) return '偏高';
      return '偏高';
    }
    if (v < 18) return '偏低';
    if (v <= 28) return '标准';
    if (v <= 33) return '偏高';
    return '偏高';
  }

  String _bmiLabel(double v) {
    if (v < 18.5) return '偏低';
    if (v <= 24) return '标准';
    if (v <= 28) return '偏高';
    return '偏高';
  }

  String _muscleLabel(double v, int gender) {
    if (gender == 1) {
      if (v < 70) return '偏低';
      if (v <= 80) return '标准';
      return '优';
    }
    if (v < 60) return '偏低';
    if (v <= 70) return '标准';
    return '优';
  }

  String _boneLabel(double v, int gender) {
    if (gender == 1) {
      if (v < 2.5) return '偏低';
      if (v <= 3.2) return '标准';
      return '偏高';
    }
    if (v < 1.8) return '偏低';
    if (v <= 2.5) return '标准';
    return '偏高';
  }

  String _waterLabel(double v, int gender) {
    if (gender == 1) {
      if (v < 55) return '偏低';
      if (v <= 65) return '标准';
      return '偏高';
    }
    if (v < 50) return '偏低';
    if (v <= 60) return '标准';
    return '偏高';
  }

  String _proteinLabel(double v) {
    if (v < 16) return '偏低';
    if (v <= 20) return '标准';
    return '偏高';
  }

  String _visceralLabel(double v) {
    if (v < 5) return '优';
    if (v <= 9) return '标准';
    if (v <= 14) return '偏高';
    return '偏高';
  }

  String _skeletalMuscleLabel(double v, int gender) {
    if (gender == 1) {
      if (v < 33) return '偏低';
      if (v <= 45) return '标准';
      return '优';
    }
    if (v < 25) return '偏低';
    if (v <= 35) return '标准';
    return '优';
  }

  // ═══ Home Widget ═══

  Future<void> _updateHomeWidget(ScaleMeasurement m) async {
    try {
      await HomeWidget.saveWidgetData<String>(
          'weight', m.weightKg.toStringAsFixed(2));
      await HomeWidget.saveWidgetData<String>(
          'bodyFat', m.bodyFatPercent.toStringAsFixed(1));
      await HomeWidget.saveWidgetData<String>(
          'bmi', m.bmi.toStringAsFixed(1));
      await HomeWidget.saveWidgetData<String>(
          'muscle', m.musclePercent.toStringAsFixed(1));
      final now = DateTime.now();
      final time = '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
      await HomeWidget.saveWidgetData<String>('time', time);
      for (final name in [
        'ScaleWidgetProvider',
        'ScaleWidget1x1Provider',
        'ScaleWidget1x2Provider',
      ]) {
        await HomeWidget.updateWidget(
          androidName: name,
          qualifiedAndroidName: 'com.example.scale_app.$name',
        );
      }
    } catch (e) {
      // best-effort
    }
  }
}
