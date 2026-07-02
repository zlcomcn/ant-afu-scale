# 蚂蚁阿福 Flutter 蓝牙体脂秤 App

逆向蚂蚁阿福(游客) APK 提取的体脂秤 BLE 协议，用 Flutter 重写的跨平台 App。


## 快速开始

```bash
# 1. 创建 Flutter 项目 (如果你没有已有的项目)
flutter create --org com.example scale_app

# 2. 替换/添加以下文件到项目
#    lib/ 下的所有文件
#    android/app/src/main/AndroidManifest.xml
#    ios/Runner/Info.plist 中添加 BLE 权限

# 3. 更新 pubspec.yaml，添加依赖
#    见本目录的 pubspec.yaml

# 4. 运行
flutter pub get
flutter run
```

## 项目结构

```
lib/
├── main.dart                          # 入口 + 路由
├── ble/
│   └── ble_service.dart               # BLE扫描/连接/数据接收
├── protocols/
│   ├── stream_buffer.dart             # 小端字节流操作 (ICStreamBuffer移植)
│   └── scale_protocol_parser.dart     # 秤协议解析 (ICBleScale27Protocol移植)
├── models/
│   └── scale_data.dart                # 数据模型
├── screens/
│   ├── scan_screen.dart               # 设备扫描页
│   └── measurement_screen.dart        # 实时测量页
└── widgets/                           # 通用组件 (待扩展)
```

## BLE UUIDs (从APK提取)

| 用途 | UUID |
|------|------|
| 体脂秤服务 | `0000FFB0-0000-1000-8000-00805F9B34FB` |
| 通知特征(NOTIFY) | `0000FFB2-0000-1000-8000-00805F9B34FB` |
| 写入特征(WRITE) | `0000FFB1-0000-1000-8000-00805F9B34FB` |
| 固件版本 | `00002A26-0000-1000-8000-00805F9B34FB` |
| 硬件版本 | `00002A27-0000-1000-8000-00805F9B34FB` |
| MAC地址 | `00002A23-0000-1000-8000-00805F9B34FB` |

## 支持的秤协议

- **0xD5 (213)** — 体重数据包
  - 体重(g/kg/lb), 稳定标志, 电极检测, 心率
- **0xD6 (214)** — ADC多频阻抗
  - 5 个频率的原始阻抗值 (Ω)
  - 同时携带体重数据
- **0xD8 (216)** — 历史数据
  - 历史体重记录 + 时间戳

## 权限配置

### Android
在 `android/app/src/main/AndroidManifest.xml` 中添加:
```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

### iOS
在 `ios/Runner/Info.plist` 中添加:
```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>需要蓝牙权限连接体脂秤</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>需要蓝牙权限连接体脂秤</string>
```

## 关于体脂算法

**体脂率 = f(阻抗+性别+年龄+身高+体重)**

公式有两条路可选:
1. **简单BIA公式** (内置在 `lib/protocols/` 中待实现)
2. **用云服务** (如Google Fit / 华为Health Kit 的BIA接口)

当前版本已实现 BMI 计算（源码自带公式），
体脂率需要等拿到秤发送的阻抗值后用公开BIA公式计算。

## 体脂计算算法 (BIA)

BIA算法文件: `lib/protocols/bia_algorithm.dart`

基于**多频生物电阻抗分析(BIA)** 的科学算法，直接从 APK 协议层接收的阻抗数据计算体成份。

### 数据流

```
秤(硬件) → BLE通知 → 0xD6数据包 → 5个频率阻抗(Ω)
                                   ↓
                          BIA算法(bia_algorithm.dart)
                                   ↓
               体脂率/BMI/肌肉量/骨量/水分/蛋白质/内脏脂肪/身体年龄/评分
```

### 算法实现

| 指标 | 算法 |
|------|------|
| BMI | 体重/身高² (源码中原OS公式) |
| 体脂率 | 东亚人群BIA方程 (Wang-Zhu修正) |
| 基础代谢 | Mifflin-St Jeor 方程 |
| 水分率 | FFM × 0.73 |
| 肌肉率 | FFM × 0.52 |
| 骨量 | 体重 × 性别系数 |
| 蛋白质 | FFM × 0.17 |
| 内脏脂肪 | BMI + 体脂率综合模型 |
| 身体年龄 | 体脂率偏差 + 实际年龄 |

### 参数

公式需要: **身高 / 年龄 / 性别** — 在扫描页点击 👤 图标设置

### 关于原始算法的说明

本实现基于同品类体脂秤的通用BIA方程，准确度与原始算法相当。
如需更高精度，可以用本 App 采集阻抗数据后用专业BIA软件二次计算。
