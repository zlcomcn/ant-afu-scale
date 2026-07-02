import 'package:flutter/material.dart';
import '../ble/ble_service.dart';
import '../models/scale_data.dart';

/// 设备扫描页面
class ScanScreen extends StatefulWidget {
  final BleScaleService bleService;

  const ScanScreen({super.key, required this.bleService});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final List<ScaleDevice> _devices = [];
  bool _isScanning = false;
  String? _error;
  bool _bleReady = false;
  ScaleDevice? _lastDevice;

  @override
  void initState() {
    super.initState();
    _initBle();
    _loadLastDevice();
  }

  Future<void> _loadLastDevice() async {
    final last = await widget.bleService.getLastDevice();
    if (mounted) {
      setState(() => _lastDevice = last);
    }
  }

  Future<void> _initBle() async {
    final ok = await widget.bleService.init();
    if (mounted) {
      setState(() {
        _bleReady = ok;
        _error = ok ? null : '此设备不支持 BLE 或蓝牙未开启';
      });
    }
  }

  Future<void> _startScan() async {
    if (!_bleReady) {
      await _initBle();
      if (!_bleReady) return;
    }

    setState(() {
      _devices.clear();
      _isScanning = true;
      _error = null;
    });

    widget.bleService.onDeviceFound = (device) {
      if (mounted) {
        setState(() => _devices.add(device));
      }
    };
    widget.bleService.onScanStateChange = (scanning) {
      if (mounted) {
        setState(() => _isScanning = scanning);
      }
    };

    await widget.bleService.startScan();
  }

  Future<void> _stopScan() async {
    await widget.bleService.stopScan();
    if (mounted) setState(() => _isScanning = false);
  }

  Future<void> _connect(ScaleDevice device) async {
    await _stopScan();
    if (!mounted) return;

    final ok = await widget.bleService.connect(device);
    if (mounted) {
      if (ok) {
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('连接失败，请重试'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _showProfileDialog() {
    final hCtrl = TextEditingController(text: '170');
    final aCtrl = TextEditingController(text: '30');
    final wCtrl = TextEditingController(text: '70');
    int selectedGender = 1;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          title: const Text('个人资料'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  value: selectedGender,
                  decoration: const InputDecoration(labelText: '性别'),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('男')),
                    DropdownMenuItem(value: 0, child: Text('女')),
                  ],
                  onChanged: (v) => setDState(() => selectedGender = v ?? 1),
                ),
                TextField(
                  controller: hCtrl,
                  decoration: const InputDecoration(labelText: '身高 (cm)'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: aCtrl,
                  decoration: const InputDecoration(labelText: '年龄'),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: wCtrl,
                  decoration: const InputDecoration(labelText: '参考体重 (kg)'),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                widget.bleService.setUserInfo(
                  heightCm: int.tryParse(hCtrl.text),
                  age: int.tryParse(aCtrl.text),
                  gender: selectedGender,
                  weightKg: double.tryParse(wCtrl.text),
                );
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('资料已保存'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('蓝牙体脂秤'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '历史记录',
            onPressed: () => Navigator.pushNamed(context, '/history'),
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: '个人资料',
            onPressed: _showProfileDialog,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? _stopScan : _startScan,
        icon: Icon(_isScanning ? Icons.stop : Icons.bluetooth_searching),
        label: Text(_isScanning ? '停止扫描' : '扫描设备'),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.bluetooth_disabled, size: 56, color: Colors.red.shade300),
              ),
              const SizedBox(height: 20),
              Text(_error!, style: TextStyle(color: Colors.grey.shade700, fontSize: 16)),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _initBle,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_isScanning && _devices.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 72,
                height: 72,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.blue.shade300,
                ),
              ),
              const SizedBox(height: 24),
              Text('正在搜索附近 BLE 设备...',
                  style: TextStyle(fontSize: 16, color: Colors.grey.shade700)),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  '站上秤或长按唤醒后等待设备出现\n二维码只含型号，不含 MAC 地址',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 13, height: 1.5),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_devices.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.bluetooth, size: 56, color: Colors.blue.shade300),
              ),
              const SizedBox(height: 20),
              Text('点击下方按钮开始扫描',
                  style: TextStyle(fontSize: 16, color: Colors.grey.shade700)),
              if (_lastDevice != null) ...[
                const SizedBox(height: 20),
                FilledButton.tonalIcon(
                  onPressed: () => _connect(_lastDevice!),
                  icon: const Icon(Icons.link),
                  label: const Text('连接上次设备'),
                ),
                const SizedBox(height: 8),
                Text(
                  _lastDevice!.deviceId,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final sorted = [..._devices]..sort((a, b) {
        if (a.likelyScale != b.likelyScale) return a.likelyScale ? -1 : 1;
        return b.rssi.compareTo(a.rssi);
      });

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: sorted.length,
      itemBuilder: (context, i) => _buildDeviceCard(sorted[i]),
    );
  }

  Widget _buildDeviceCard(ScaleDevice d) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: d.likelyScale ? 3 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: d.likelyScale
            ? BorderSide(color: Colors.teal.shade200, width: 1.5)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _connect(d),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: d.likelyScale ? Colors.teal.shade50 : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.monitor_weight_outlined,
                  color: d.likelyScale ? Colors.teal : Colors.grey.shade500,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            d.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 15),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (d.likelyScale)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.teal.shade50,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text('体脂秤',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.teal.shade700,
                                    fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'RSSI ${d.rssi} dBm  ·  ${d.macAddress ?? d.deviceId}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (d.matchReason.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(d.matchReason,
                          style: TextStyle(
                              fontSize: 11, color: Colors.orange.shade600)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
}
