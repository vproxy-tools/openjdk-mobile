# Tiny Zero iOS Demo — vproxy

在 iOS app 内嵌 OpenJDK Mobile **Zero JVM**，运行**未经修改的 vproxy**
（`-Deploy=helloworld`：8080 端口的 HTTP+UDP 应答服务，启动自带
TCP/UDP 自检），并通过 iOS 26 的 `BGContinuedProcessingTask` 在后台长期
运行（30 天进度窗口）；模拟器与 iOS<26 走 `beginBackgroundTask` 回退。

架构、契约与排障要点（面向维护）见 `AGENTS.md`；嵌入层复用指南见
`JvmEmbed/README.md`；JVM 静态库的构建见
[`../tiny-zero-ios-build`](../tiny-zero-ios-build/README.md)。

## 目录结构

```text
tiny-zero-ios-demo/
├── project.yml               # xcodegen 工程定义(生成 TinyHttpServer.xcodeproj)
├── JvmEmbed/                 # ★ 公共部分:可复用的 JVM 嵌入层(见 JvmEmbed/README.md)
│   ├── Native/               #   jvm_bridge(JNI 桥) + ios_wx_shims(W^X weak 符号)
│   ├── Java/IosBootstrap.java#   stdout/stderr 逐行原样转发
│   └── Swift/BackgroundExecution.swift # 后台任务封装(iOS 26 原生 + 回退)
├── App/                      # 程序部分:本 demo 的 UI 与编排
│   ├── TinyHttpServerApp.swift
│   ├── ContentView.swift
│   ├── JvmModel.swift
│   └── Simulator.entitlements
├── support/
│   ├── run-sim-demo.sh       # ★ 模拟器一键复现:构建→安装→启动→curl 验证(幂等)
│   ├── run-device-demo.py    # 真机一键部署(纯命令行,无 Xcode GUI)
│   ├── build-sim-libffi.sh   # 首次:模拟器 libffi → ~/ios-sim-support
│   ├── build-sim-jvm.sh      # 模拟器 Zero JVM + runtime 树 → third_party/
│   └── build-java.sh         # → third_party/vproxy.jar + vproxy-ios-bootstrap.jar
├── third_party/              # 构建产物(gitignore)
├── work-generated/           # sim jmod/jlink 中间产物(gitignore)
└── build/                    # xcodebuild 输出(gitignore)
```

## 从零到模拟器跑通

1. **设备流水线**（约 30–60 分钟，一次性）：按
   [`../tiny-zero-ios-build/README.md`](../tiny-zero-ios-build/README.md)
   准备依赖并 `./build.sh`。它在本仓库工作区完成设备构建并生成精确
   symbol keeper，模拟器构建直接复用。
2. **vproxy**（已存在则跳过）：`git clone --recursive
   https://github.com/wkgcass/vproxy` 到本仓库同级目录，
   `./gradlew shadowjar` 产出 `build/libs/vproxy.jar`；也可用
   `VPROXY_JAR=<路径>` 指定。
3. **模拟器 demo**：

   ```bash
   cd tiny-zero-ios-demo
   ./support/run-sim-demo.sh
   ```

   自动完成：创建/启动 iPhone 13（iOS 26.5）模拟器 → 编译缺失的
   libffi/Zero JVM/jar/app → ad-hoc 补签 entitlement → 安装 →
   `-autostart -direct` 启动 → 轮询 curl 直到 HTTP 200 → 打印响应与
   落盘日志。预期输出（节选）：

   ```text
   HTTP/1.1 200 OK

   vproxy 1.0.0-BETA-13-DEV
   --- Documents/java-console.log ---
   [native] wrote <容器>/Documents/.vproxy/resolv.conf
   HTTP server is listening on 8080
   TCP seems OK
   UDP seems OK
   ```

前置条件：Xcode 26+（含 iOS 26.5 模拟器 runtime）、`xcodegen`
（`brew install xcodegen`）、完成第 1、2 步。

## 真机部署

```bash
cd tiny-zero-ios-demo
./support/run-device-demo.py                                    # 默认 -autostart(后台任务流程)
LAUNCH_ARGS="-autostart -direct" ./support/run-device-demo.py  # 前台直启
```

脚本自动完成：选择已连接设备 → 从 `dist/device` 装配产物 → 从本机描述
文件推导签名 team → `xcodebuild` 签名构建 → `devicectl` 安装并带参启动
→ curl 验证 → 拉回 `Documents/java-console.log`。环境变量覆盖：
`DEVICE`/`TEAM_ID`/`LAUNCH_ARGS`/`DEVICE_IP`。注意：首次需先在
Xcode GUI 选 team 并 Run 一次生成本机描述文件；手机需保持解锁；详细
行为与续签逻辑见 `AGENTS.md`。

## 打包未签名 ipa（分发）

```bash
./support/package-ipa.py    # → build/TinyHttpServer-<CONFIG>-unsigned.ipa
```

无签名（`CODE_SIGNING_ALLOWED=NO`）真机构建 + 标准 `Payload/` 打包，
自带校验（二进制确未签名、modules/tzdb/marker 为合法 Mach-O/jar 齐全）。
接收方用 iLoader/Sideloadly/AltStore 等工具以**自己的证书**签名安装
（免费个人证书同样 7 天有效）。环境变量：`CONFIG`（默认 Debug，可选
Release）、`OUTPUT`（输出路径）、`TEAM_ID`（见下）。

### 后台模式与 bundle id 改写（iLoader 场景）

根因是上游 bug：iLoader 签名时把 bundle id 改写为
`com.foo.App.<TEAMID>`，却**没有同步改写**
`BGTaskSchedulerPermittedIdentifiers`
（[nab138/iloader#649](https://github.com/nab138/iloader/issues/649)；
2026-09 时仍 Open、尚无修复。**该 issue 修复发布后，新版 iLoader 的
安装不再需要本节任何补丁**）。而白名单在 iOS 26.5 上是**纯精确匹配**
（通配条目实测无效，故 plist 只保留具体条目），于是运行时推导的任务
标识（`BGContinuedProcessingTask`）被系统拒绝。app 会在提交前自检并
给出含 team id 的明确报错（错误卡片带一键复制）；前台模式不受影响。

**解决一：接收方自行改写 ipa（推荐，无需开发者）**

把通用包和 `support/patch-ipa-team.py`（单文件、纯标准库，Windows
也可运行）发给接收方。team id 取自 app 报错里改写后 bundle id
（形如 `com.wkgcass.TinyHttpServer.<TEAMID>`）的**末段**，然后在任意
有 Python 的电脑上执行：

```bash
python3 patch-ipa-team.py TinyHttpServer-Debug-unsigned.ipa 2XC9XJ2N34
# → TinyHttpServer-Debug-unsigned-2XC9XJ2N34.ipa
```

脚本把 `<bundle>.<TEAMID>.continuedProcessing.demo` **追加**进白名单
（保留原条目、对已打补丁的包重复执行幂等、保留 zip 条目元数据），
改完的 ipa 用 iLoader 正常签名安装，后台模式即可用（真机已验证）。

**解决二：让开发者构建专属 ipa**

与解决一等价，由开发者在打包时直接烘入 team 条目（省去接收方操作）：

```bash
TEAM_ID=2XC9XJ2N34 ./support/package-ipa.py
# → build/TinyHttpServer-Debug-team-2XC9XJ2N34-unsigned.ipa
```

指定 `TEAM_ID` 时输出文件名自动带 `team-<TEAMID>`；不指定则不添加
任何条目，plist 只含原始标识。

**解决三：保留原始 bundle id 安装**

用不改写 bundle id 的方式签名安装，通用包后台模式直接可用：
Sideloadly 的保留选项、TrollStore 免签安装、或 Mac 端
Sideloadly/`idevicesigner` 以原 id 重签。

## 手动操作（等价于一键脚本）

```bash
cd tiny-zero-ios-demo
./support/build-sim-libffi.sh      # 首次
./support/build-sim-jvm.sh
./support/build-java.sh
xcodegen generate
xcodebuild -project TinyHttpServer.xcodeproj -scheme TinyHttpServer \
  -sdk iphonesimulator -configuration Debug -derivedDataPath build \
  ARCHS=arm64 build
# 模拟器 ad-hoc 签名丢 entitlement(MAP_JIT 需要),每次构建后补签:
codesign -f -s - --entitlements App/Simulator.entitlements \
  build/Build/Products/Debug-iphonesimulator/TinyHttpServer.app
xcrun simctl install "iPhone 13" \
  build/Build/Products/Debug-iphonesimulator/TinyHttpServer.app
xcrun simctl launch "iPhone 13" com.wkgcass.TinyHttpServer -autostart -direct
curl http://127.0.0.1:8080/        # 模拟器与 Mac 共享 loopback
```

启动参数：`-autostart`（跳过 UI 直接启动）、`-direct`（前台直启，不申请
后台任务；模拟器上后台任务 submit 必失败属预期）、`-autostop <秒>`
（到时自动停止并退出）。想看 app 界面：`open -a Simulator`（设备需已
boot）。

清理生成物：`./clean.sh`（删除 `third_party/`、`build/`、`build-java/`、
`work-generated/`、`TinyHttpServer.xcodeproj/`；`~/ios-sim-support` 与
设备流水线产物不受影响）。

## 已知限制

- 模拟器上 BGTaskScheduler 不可用，`BGContinuedProcessingTask` 的真实
  验证需 iOS 26 真机。
- 模拟器每次构建后需手动（或经一键脚本）补签 entitlement。
