import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/scale_data.dart';
import '../protocols/scale_protocol_parser.dart';
import '../protocols/bia_algorithm.dart';

/// 体脂秤 BLE 连接管理
class BleScaleService {
  static final BleScaleService shared = BleScaleService._();
  BleScaleService._();
  // BLE UUIDs (从 ICWeightScale27Worker 提取)
  static const String serviceUuid = '0000ffb0-0000-1000-8000-00805f9b34fb';
  static const String notifyUuid = '0000ffb2-0000-1000-8000-00805f9b34fb';
  static const String indicateUuid = '0000ffb3-0000-1000-8000-00805f9b34fb';
  static const String writeUuid = '0000ffb1-0000-1000-8000-00805f9b34fb';
  static const String _lastDeviceIdKey = 'last_scale_device_id';
  static const String _lastDeviceNameKey = 'last_scale_device_name';

  // 扫描状态
  bool _isScanning = false;
  StreamSubscription? _scanSub;
  final List<StreamSubscription> _notifySubs = [];

  // 连接状态
  BluetoothDevice? _device;
  BluetoothConnectionState _connectionState =
      BluetoothConnectionState.disconnected;
  StreamSubscription? _connSub;
  List<BluetoothService> _services = [];

  // 数据回调
  final List<ScaleDevice> _foundDevices = [];
  Function(ScaleDevice device)? onDeviceFound;
  Function(ScaleMeasurement measurement)? onMeasurement;
  Function(bool connected)? onConnectionChange;
  Function(bool scanning)? onScanStateChange;
  Function(String log)? onLog;
  final List<String> _logLines = [];

  // ── 测量生命周期 (复刻逆向 ICWeightScale27Worker 的 state 语义) ──
  // 逆向逻辑: state!=0 实时称重(MeasureWeightData); state=0 且已稳定 → MeasureOver。
  // OEM 变体 state 恒为1，改用重量稳定检测复刻同一套 开始/进行/结束/离秤 语义。
  static const double _kOnScaleKg = 3.0; // 站上阈值 (>此判定有人)
  static const double _kOffScaleKg = 2.0; // 离秤阈值 (<此判定人离开)
  static const double _kStableDeltaKg = 0.15; // 两帧变化小于此 → 视为未变化
  static const int _kStableHoldMs = 1500; // 未变化持续此时长 → 判定测量结束

  /// 检测到人站上秤，测量开始
  void Function()? onMeasureStart;
  /// 实时体重刷新 (测量进行中，每帧)
  void Function(ScaleMeasurement m)? onMeasureUpdate;
  /// 测量判稳，锁定 UI 显示 (对应逆向 稳定态，但此刻不保存)
  void Function(ScaleMeasurement m)? onMeasureComplete;
  /// 人离秤 (state==0)。若此前已判稳则回传最终稳定值用于保存，否则回传 null
  void Function(ScaleMeasurement? finalStable)? onMeasureReset;

  _MeasurePhase _phase = _MeasurePhase.idle;
  double _lastLiveWeight = 0;
  DateTime? _lastChangeAt;
  ScaleMeasurement? _stableCandidate;
  ScaleMeasurement? _finalStable; // 已判稳的最终值 (离秤时保存)

  void _resetMeasureLifecycle() {
    _phase = _MeasurePhase.idle;
    _lastLiveWeight = 0;
    _lastChangeAt = null;
    _stableCandidate = null;
    _finalStable = null;
  }

  /// 测量生命周期状态机 — 每收到一帧体重调用
  void _updateMeasureLifecycle(ScaleMeasurement m) {
    final kg = m.weightKg;
    final now = DateTime.now();

    // 离秤检测: 重量掉回阈值以下 (等价逆向 state==0) → 仅重置，准备下一次测量
    if (kg < _kOffScaleKg) {
      if (_phase != _MeasurePhase.idle) {
        _log('测量重置: 人已离秤 (${kg.toStringAsFixed(2)}kg)');
        _resetMeasureLifecycle();
        onMeasureReset?.call(null);
      }
      return;
    }

    // 未达站上阈值 (2~3kg 的模糊区间) — 不触发开始，等待稳定站立
    if (kg < _kOnScaleKg && _phase == _MeasurePhase.idle) return;

    // 测量开始
    if (_phase == _MeasurePhase.idle) {
      _phase = _MeasurePhase.measuring;
      _lastLiveWeight = kg;
      _lastChangeAt = now;
      _log('测量开始: 检测到站上 (${kg.toStringAsFixed(2)}kg)');
      onMeasureStart?.call();
    }

    // 已判稳: 仅接受与锁定值接近的帧 (阻抗后到但体重不变)，
    // 忽略离秤过程中的跳变/低值，避免最终稳定值被污染成 0。
    if (_phase == _MeasurePhase.complete) {
      final locked = _finalStable;
      if (locked != null && (kg - locked.weightKg).abs() <= _kStableDeltaKg) {
        _finalStable = m;
        onMeasureUpdate?.call(m);
      }
      return;
    }

    // 实时刷新
    onMeasureUpdate?.call(m);

    // 判定重量是否还在变化 (逆向: abs(new-old) > 阈值)
    final delta = (kg - _lastLiveWeight).abs();
    if (delta > _kStableDeltaKg) {
      // 还在变化 → 重置稳定计时
      _lastLiveWeight = kg;
      _lastChangeAt = now;
      _stableCandidate = m;
      return;
    }

    // 未明显变化 — 累计稳定时长
    _stableCandidate = m;
    final heldMs = now.difference(_lastChangeAt ?? now).inMilliseconds;
    if (heldMs >= _kStableHoldMs) {
      _phase = _MeasurePhase.complete;
      _finalStable = _stableCandidate ?? m;
      _log('测量完成(判稳): ${kg.toStringAsFixed(2)}kg (持续${heldMs}ms)，立即保存');
      onMeasureComplete?.call(_finalStable!);
    }
  }

  // 用户信息 (用于体脂计算)
  int _heightCm = 170;
  int _age = 30;
  int _gender = 1; // 0=女 1=男
  double _refWeightKg = 70;

  // 缓存: 最近一次体重 (用于与阻抗合并)
  ScaleMeasurement? _lastWeightData;

  /// 设置用户信息 (影响体脂计算精度)
  void setUserInfo({int? heightCm, int? age, int? gender, double? weightKg}) {
    if (heightCm != null) _heightCm = heightCm;
    if (age != null) _age = age;
    if (gender != null) _gender = gender;
    if (weightKg != null) _refWeightKg = weightKg;
  }

  bool get isScanning => _isScanning;
  bool get isConnected =>
      _connectionState == BluetoothConnectionState.connected;
  List<ScaleDevice> get foundDevices => List.unmodifiable(_foundDevices);
  List<String> get recentLogs => List.unmodifiable(_logLines);

  Future<ScaleDevice?> getLastDevice() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_lastDeviceIdKey);
    if (id == null || id.isEmpty) return null;
    return ScaleDevice(
      deviceId: id,
      name: prefs.getString(_lastDeviceNameKey) ?? '上次连接设备',
      rssi: 0,
      macAddress: id,
      likelyScale: true,
      matchReason: '上次连接',
    );
  }

  Future<void> _saveLastDevice(ScaleDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastDeviceIdKey, device.deviceId);
    await prefs.setString(_lastDeviceNameKey, device.name);
  }

  /// 初始化 BLE
  Future<bool> init() async {
    try {
      if (await FlutterBluePlus.isSupported == false) {
        _log('此设备不支持 BLE');
        return false;
      }

      final permissionsOk = await _ensurePermissions();
      if (!permissionsOk) {
        _log('蓝牙扫描权限未授予');
        return false;
      }

      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first;
      _log('BLE 已就绪');
      return true;
    } catch (e) {
      _log('BLE 初始化失败: $e');
      return false;
    }
  }

  /// 开始扫描体脂秤
  Future<void> startScan({Duration? timeout}) async {
    if (_isScanning) return;
    _foundDevices.clear();

    try {
      // 停止之前的扫描
      await FlutterBluePlus.stopScan();
      _isScanning = true;

      _scanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (final result in results) {
          final device = result.device;
          final name = device.platformName.isNotEmpty
              ? device.platformName
              : result.advertisementData.advName.isNotEmpty
                  ? result.advertisementData.advName
                  : '未知设备';
          final advData = result.advertisementData;
          final deviceId = device.remoteId.str;
          final serviceUuids = advData.serviceUuids
              .map((g) => g.toString().toLowerCase())
              .toList();
          final manufacturerDataHex = _manufacturerDataHex(advData);
          final match =
              _classifyScanResult(name, serviceUuids, manufacturerDataHex);

          // 去重
          if (_foundDevices.any((d) => d.deviceId == deviceId)) continue;

          final sd = ScaleDevice(
            deviceId: deviceId,
            name: name,
            rssi: result.rssi,
            macAddress: deviceId,
            serviceUuids: serviceUuids,
            manufacturerDataHex: manufacturerDataHex,
            likelyScale: match.$1,
            matchReason: match.$2,
          );
          _foundDevices.add(sd);
          onDeviceFound?.call(sd);
          _log(
            '发现设备: $name [$deviceId] RSSI=${result.rssi} '
            'services=${serviceUuids.join(',')} mfg=$manufacturerDataHex '
            '${match.$1 ? "match=${match.$2}" : ""}',
          );
        }
      });

      await FlutterBluePlus.startScan(
        androidScanMode: AndroidScanMode.lowLatency,
        timeout: timeout,
      );

      _log(timeout == null
          ? '开始宽范围扫描 BLE 设备，需手动停止...'
          : '开始宽范围扫描 BLE 设备，${timeout.inSeconds}秒后自动停止...');
    } catch (e) {
      _log('扫描启动失败: $e');
      _isScanning = false;
      onScanStateChange?.call(false);
    }
  }

  /// 停止扫描
  Future<void> stopScan() async {
    try {
      await _scanSub?.cancel();
      _scanSub = null;
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _isScanning = false;
    onScanStateChange?.call(false);
    _log('扫描已停止, 发现 ${_foundDevices.length} 个设备');
  }

  /// 连接指定设备
  Future<bool> connect(ScaleDevice device) async {
    try {
      _device = BluetoothDevice.fromId(device.deviceId);

      _connSub = _device!.connectionState.listen((state) {
        _connectionState = state;
        onConnectionChange?.call(state == BluetoothConnectionState.connected);
        _log('连接状态: $state');
      });

      await _device!.connect(timeout: const Duration(seconds: 15));
      await _saveLastDevice(device);
      await Future.delayed(const Duration(milliseconds: 500));

      // 发现服务
      _services = await _device!.discoverServices();
      _logDiscoveredServices(_services);

      // 订阅通知特征
      await _subscribeNotify();

      // 发送用户信息 & 时间同步。只有确认找到 FFB1 时才写，避免 fallback 写入未知设备特征。
      if (_hasExactWriteCharacteristic()) {
        await _sendInitCommands();
      } else {
        _log('未找到 FFB1，跳过初始化写入；等待设备主动通知');
      }

      return true;
    } catch (e) {
      _log('连接失败: $e');
      return false;
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    for (final sub in _notifySubs) {
      await sub.cancel();
    }
    _notifySubs.clear();
    await _connSub?.cancel();
    _connSub = null;

    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _connectionState = BluetoothConnectionState.disconnected;
    _resetMeasureLifecycle();
    onConnectionChange?.call(false);
    _log('已断开连接');
  }

  /// 订阅通知/指示特征 — V3 秤需要 FFB3 indicate + FFB2 notify 两路都打开
  Future<void> _subscribeNotify() async {
    if (_device == null) return;

    final services =
        _services.isNotEmpty ? _services : await _device!.discoverServices();
    BluetoothCharacteristic? exactNotify;
    BluetoothCharacteristic? exactIndicate;
    BluetoothCharacteristic? fallback;

    for (final svc in services) {
      final serviceId = svc.uuid.toString().toLowerCase();
      for (final chr in svc.characteristics) {
        final uuid = chr.uuid.toString().toLowerCase();
        if (_uuidMatches(serviceId, 'ffb0') && _uuidMatches(uuid, 'ffb2')) {
          exactNotify = chr;
        }
        if (_uuidMatches(serviceId, 'ffb0') && _uuidMatches(uuid, 'ffb3')) {
          exactIndicate = chr;
        }
        if (fallback == null &&
            (chr.properties.notify || chr.properties.indicate)) {
          fallback = chr;
        }
      }
    }

    if (exactIndicate != null) {
      await _subscribeCharacteristic(exactIndicate, label: 'FFB3 indicate');
    }
    if (exactNotify != null) {
      await _subscribeCharacteristic(exactNotify, label: 'FFB2 notify');
    }
    if (exactNotify != null || exactIndicate != null) return;

    if (fallback != null) {
      _log('未找到 FFB2/FFB3，改订阅可通知特征 ${fallback.uuid.toString().toLowerCase()}');
      await _subscribeCharacteristic(fallback, label: 'fallback');
      return;
    }

    _log('未找到任何 notify/indicate 特征!');
  }

  Future<void> _subscribeCharacteristic(BluetoothCharacteristic chr,
      {required String label}) async {
    final sub = chr.onValueReceived.listen((data) {
      _onDataReceived(Uint8List.fromList(data));
    });
    _notifySubs.add(sub);
    await chr.setNotifyValue(true);
    _log('已订阅 $label 特征 ${chr.uuid.toString().toLowerCase()}');
  }

  /// 收到秤的原始数据
  void _onDataReceived(Uint8List data) {
    try {
      _log('收到 BLE 数据: ${data.length} bytes');
      _log(
          'HEX: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');

      // 用协议解析器解码
      final results = ScaleProtocolParser.decode(data, 64);
      if (results.isEmpty) {
        _log(
            '协议解析为空: 长度=${data.length} 首字节=${data.isEmpty ? '-' : data[0].toRadixString(16)}');
      }

      for (final pkt in results) {
        _handlePacket(pkt);
      }
    } catch (e) {
      _log('数据解析错误: $e');
    }
  }

  /// 处理解析后的数据包 (集成BIA体脂计算)
  void _handlePacket(ScalePacketResult pkt) {
    final kg = pkt.weightKg;
    final impedances = pkt.adcs;
    final isStable = pkt.data['state'] == 1;

    _log(
        '解析: section=${pkt.section} type=${pkt.packetType.toRadixString(16)} '
        'kg=${kg?.toStringAsFixed(2) ?? "-"} state=${pkt.data['state']} '
        'weight_g=${pkt.weightG} flags_hex=${(pkt.data['flags_raw'] ?? pkt.weightG ?? 0).toRadixString(16)}');

    if (kg != null) {
      // 缓存体重数据
      _lastWeightData = ScaleMeasurement(
        weightG: pkt.weightG ?? (kg * 1000).round(),
        weightKg: kg,
        weightLb: kg * 2.20462,
        impedances: impedances,
        isStabilized: isStable,
        packetType: pkt.packetType,
      );

      // 已有阻抗数据 → 计算体成份
      if (impedances.isNotEmpty && isStable) {
        final result = BiaBodyComposition.calculate(
          impedances: impedances,
          weightKg: kg,
          heightCm: _heightCm,
          age: _age,
          gender: _gender,
          source: _lastWeightData!,
        );
        onMeasurement?.call(result);
        _updateMeasureLifecycle(result);
        _log('✅ 体成份: 体脂=${result.bodyFatPercent}% BMI=${result.bmi}');
      } else {
        // 纯体重数据 (无阻抗) — BMI 推算体成分
        final result = BiaBodyComposition.estimateFromBmi(
          weightKg: kg,
          heightCm: _heightCm,
          age: _age,
          gender: _gender,
          source: _lastWeightData!,
        );
        onMeasurement?.call(result);
        _updateMeasureLifecycle(result);
        _log('体重: ${kg.toStringAsFixed(2)}kg ${isStable ? "✅稳定" : "⏳称重中"}');
      }
      return;
    }

    // ADC 阻抗数据包 (单独来的时候)
    if (impedances.isNotEmpty) {
      _log(
          '⚡ 阻抗(${impedances.length}频): ${impedances.map((v) => '${v.toStringAsFixed(0)}Ω').join(', ')}');

      // 如果之前有缓存的稳定体重 → 合并计算体成份
      if (_lastWeightData != null && _lastWeightData!.isStabilized) {
        final result = BiaBodyComposition.calculate(
          impedances: impedances,
          weightKg: _lastWeightData!.weightKg,
          heightCm: _heightCm,
          age: _age,
          gender: _gender,
          source: _lastWeightData!,
        );
        onMeasurement?.call(result);
        _log('✅ 体成份: 体脂=${result.bodyFatPercent}% BMI=${result.bmi}');
      }
    }
  }

  /// 连接后发送初始化命令
  Future<void> _sendInitCommands() async {
    await Future.delayed(const Duration(milliseconds: 300));

    // 旧协议 AC — 维持设备应答通道
    final userInfo = ScaleProtocolParser.encodeUserInfo(
        _heightCm, _age, _gender, _refWeightKg);
    await _writeCharacteristic(userInfo);

    await Future.delayed(const Duration(milliseconds: 300));

    // General V2 BE — 触发设备进入完整测量模式
    final beFrames = ScaleProtocolParser.encodeUserInfoBE(
      heightCm: _heightCm,
      age: _age,
      gender: _gender,
      weightKg: _refWeightKg,
    );
    for (final frame in beFrames) {
      await _writeCharacteristic(frame);
      await Future.delayed(const Duration(milliseconds: 80));
    }

    await Future.delayed(const Duration(milliseconds: 200));

    // 时间同步
    final timeSync = ScaleProtocolParser.encodeTimeSync();
    await _writeCharacteristic(timeSync);

    _log('初始化命令已发送 (AC + BE x${beFrames.length} + A4)');
  }

  /// 写入特征
  Future<void> _writeCharacteristic(Uint8List data) async {
    if (_device == null) return;

    try {
      final services =
          _services.isNotEmpty ? _services : await _device!.discoverServices();
      BluetoothCharacteristic? fallback;
      for (final svc in services) {
        if (_uuidMatches(svc.uuid.toString(), 'ffb0')) {
          for (final chr in svc.characteristics) {
            if (_uuidMatches(chr.uuid.toString(), 'ffb1')) {
              await chr.write(data, withoutResponse: true);
              _log('写入 FFB1: ${data.length} bytes');
              return;
            }
          }
        }
        for (final chr in svc.characteristics) {
          if (fallback == null &&
              (chr.properties.writeWithoutResponse || chr.properties.write)) {
            fallback = chr;
          }
        }
      }
      if (fallback != null) {
        await fallback.write(data,
            withoutResponse: fallback.properties.writeWithoutResponse);
        _log(
            '写入 fallback ${fallback.uuid.toString().toLowerCase()}: ${data.length} bytes');
        return;
      }
      _log('未找到任何可写特征');
    } catch (e) {
      _log('写入失败: $e');
    }
  }

  bool _hasExactWriteCharacteristic() {
    for (final svc in _services) {
      if (!_uuidMatches(svc.uuid.toString(), 'ffb0')) continue;
      for (final chr in svc.characteristics) {
        if (_uuidMatches(chr.uuid.toString(), 'ffb1')) return true;
      }
    }
    return false;
  }

  void _log(String msg) {
    _logLines.insert(0, msg);
    if (_logLines.length > 80) {
      _logLines.removeRange(80, _logLines.length);
    }
    onLog?.call(msg);
  }

  bool _uuidMatches(String actual, String shortUuid) {
    final normalized = actual.toLowerCase().replaceAll('-', '');
    final short = shortUuid.toLowerCase().replaceAll('-', '');
    return normalized == short ||
        normalized == '0000${short}00001000800000805f9b34fb';
  }

  void _logDiscoveredServices(List<BluetoothService> services) {
    _log('服务发现完成: ${services.length} 个服务');
    for (final svc in services) {
      final serviceId = svc.uuid.toString().toLowerCase();
      _log('服务 $serviceId');
      for (final chr in svc.characteristics) {
        final props = <String>[];
        if (chr.properties.notify) props.add('notify');
        if (chr.properties.indicate) props.add('indicate');
        if (chr.properties.write) props.add('write');
        if (chr.properties.writeWithoutResponse) props.add('writeNoResp');
        if (chr.properties.read) props.add('read');
        _log('  特征 ${chr.uuid.toString().toLowerCase()} [${props.join(',')}]');
      }
    }
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid && !Platform.isIOS) return true;

    final permissions = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];

    final statuses = await permissions.request();
    for (final entry in statuses.entries) {
      _log('权限 ${entry.key}: ${entry.value}');
    }

    final bluetoothOk = statuses[Permission.bluetoothScan]?.isGranted == true &&
        statuses[Permission.bluetoothConnect]?.isGranted == true;
    final locationOk =
        statuses[Permission.locationWhenInUse]?.isGranted == true;

    if (!bluetoothOk || !locationOk) {
      _log('请在系统设置中允许附近设备和位置信息权限，否则 Android 会返回空扫描结果');
      return false;
    }

    if (Platform.isAndroid &&
        await Permission.location.serviceStatus.isDisabled) {
      _log('系统定位服务未开启；部分 Android 机型关闭定位时 BLE 扫描结果为空');
    }

    return true;
  }

  String _manufacturerDataHex(AdvertisementData advData) {
    final parts = <String>[];
    for (final entry in advData.manufacturerData.entries) {
      final id = entry.key.toRadixString(16).padLeft(4, '0');
      final bytes =
          entry.value.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
      parts.add('$id:$bytes');
    }
    return parts.join(';');
  }

  (bool, String) _classifyScanResult(
    String name,
    List<String> serviceUuids,
    String manufacturerDataHex,
  ) {
    final lowerName = name.toLowerCase();
    if (serviceUuids.any((uuid) => uuid == serviceUuid)) {
      return (true, '服务UUID匹配 FFB0');
    }
    if (lowerName.contains('afu') ||
        lowerName.contains('wl') ||
        lowerName.contains('tz')) {
      return (true, '名称疑似 AFU_WL_TZ');
    }
    if (lowerName.contains('scale') || lowerName.contains('weight')) {
      return (true, '名称包含体重秤关键词');
    }
    if (manufacturerDataHex.isNotEmpty && lowerName == '未知设备') {
      return (true, '无名设备但有厂商广播');
    }
    return (false, '');
  }

  /// 释放资源
  void dispose() {
    _scanSub?.cancel();
    for (final sub in _notifySubs) {
      sub.cancel();
    }
    _notifySubs.clear();
    _connSub?.cancel();
    FlutterBluePlus.stopScan();
  }
}

/// 测量生命周期阶段
enum _MeasurePhase { idle, measuring, complete }
