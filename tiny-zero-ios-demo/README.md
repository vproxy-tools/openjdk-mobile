# Tiny Zero iOS Demo — vproxy

在 iOS app 内嵌 OpenJDK Mobile **Zero JVM**，运行**未经修改的 vproxy**
（`-Deploy=helloworld`：8080 端口的 HTTP+UDP 应答服务，启动自带
TCP/UDP 自检），并以 `-Dvfd=posix` 使用 vproxy 的**原生 PosixFDs 实现**
（libpni/libvfdposix 两个 framework，PNI + libae 事件循环），通过 iOS 26
的 `BGContinuedProcessingTask` 在后台长期运行（30 天进度窗口）；模拟器
与 iOS<26 走 `beginBackgroundTask` 回退。

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
│   ├── build-java.sh         # → third_party/vproxy.jar + 双 SDK 原生 framework
│   ├── stage-frameworks.sh   # 按平台把 framework 变体暂存进 third_party/Frameworks
│   ├── package-ipa.py        # 未签名 ipa(分发用,接收方自行签名)
│   └── sign-ipa.py           # 本机离线签名 ipa(证书+描述文件,无需手机在线)
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
   `VPROXY_JAR=<路径>` 指定。`-Dvfd=posix` 所需的 libpni/libvfdposix
   framework 由 `build-java.sh` 在 vproxy 根目录执行
   `SDK_NAME=<sdk> make ios-vfdposix` 一并构建（真机+模拟器双份，存入
   `third_party/vproxy-frameworks/`；已存在则跳过，`VPROXY_ROOT` 可覆盖
   checkout 位置）。
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

   --- Documents/java-console.log ---
   [native] wrote <容器>/Documents/.vproxy/resolv.conf
   System.loadLibrary(pni)
   System.loadLibrary(vfdposix)
   USING POSIX NATIVE FDs Impl
   HTTP server is listening on 8080
   TCP seems OK
   UDP seems OK
   ```

   `USING POSIX NATIVE FDs Impl` 表示 vproxy 正经 `-Dvfd=posix` 走原生
   PosixFDs（libvfdposix 内的 libae 事件循环），而非 JDK NIO 实现。

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
Release）、`OUTPUT`（输出路径）。

## 本机离线签名 ipa（不连手机）

签名只需要两样本机记录：**钥匙串里的开发证书** + **一份已把目标设备
UDID 注册进去的描述文件**（首次用 Xcode 连手机时生成）。手机只在
**安装**时才需要连接。曾在这台 Mac 上配对过 iPhone 的话，按下面三步
确认记录还在（示例输出已脱敏，实际会显示真实设备名/UDID/team/邮箱）：

```bash
# 1. 已配对的设备列表（unavailable 只是当前未连接，配对记录仍在）
xcrun devicectl list devices
# Name           Hostname                     Identifier                             State        Model
# -------------  ---------------------------  ------------------------------------  -----------  --------
# 某某的iPhone    moumou.coredevice.local      ABCDEF01-1234-5678-9ABC-DEF012345678   unavailable  iPhone 13

# 2. 描述文件（provisioning profile）：Xcode 下载后存放在固定位置，
#    文件名是 UUID，需要解码才能看出对应哪个 app / 哪个 team
ls ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/
# aaaabbbb-cccc-dddd-eeee-ffff00001111.mobileprovision
# （Xcode GUI 里的对应入口：Settings → Accounts → 选中 Apple ID →
#   Download Manual Profiles；老版本 Xcode 放在
#   ~/Library/MobileDevice/Provisioning Profiles/）
security cms -D -i ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/<UUID>.mobileprovision \
  | plutil -extract TeamIdentifier.0 raw -
# ABCD1234EF

# 3. 可用的签名证书（显示 40 位哈希 + 证书名）
security find-identity -v -p codesigning
#   1) AAAABBBBCCCCDDDDEEEEFFFF0000111122223333 "Apple Development: your-name@example.com (XXXXXXXXXX)"
#     2 valid identities found
```

描述文件内容都可用 `security cms -D -i <文件>` 解码成 plist 查看，常用
字段：`Entitlements.application-identifier`（`<team>.<bundle id>`，判断
是否匹配本 app）、`ExpirationDate`（有效期）、`ProvisionedDevices`（已
注册设备 UDID 列表，安装时手机必须在此列）。

确认无误后，一条命令离线签名：

```bash
./support/sign-ipa.py    # → build/TinyHttpServer-Debug-signed.ipa
```

脚本自动完成：挑选匹配 bundle id 的最新本地描述文件 → 校验有效期 →
按证书 OU 匹配 team 选出有效证书（**按哈希签名**，避免钥匙串里同名
证书的二义）→ 从描述文件派生 entitlements → 先签 `Frameworks/` 下两个
framework 与全部 `*.dylib` marker、再签主程序（嵌入
`embedded.mobileprovision`）→ `codesign --verify` → 重新打包 ipa。
可用 `--profile <路径>`、`--identity <名称或哈希>`、`-o <输出>` 覆盖
默认选择；对其他 ipa 签名直接把路径作为参数传入。

安装（这一步才需要手机在线）：

```bash
xcrun devicectl device install app --device <设备名或UDID> \
  build/TinyHttpServer-Debug-signed.ipa
```

**有效期**：免费个人团队的描述文件 7 天过期，签出的 app 同步失效
（脚本会在临近过期时警告）。过期后**无需连接手机**即可续签：依赖
Xcode 的 Apple ID 会话执行 `xcodebuild … -allowProvisioningUpdates`
拉取新描述文件（`./support/run-device-demo.py` 内置了这套逻辑），
再重跑 `sign-ipa.py` 即可。我们自己的签名不改写 bundle id，因此
README 上文 iLoader 的
`BGTaskSchedulerPermittedIdentifiers` 补丁在这条路**不需要**。

### 后台模式与 iLoader 的 bundle id 改写

iLoader 签名时会把 bundle id 改写为 `com.foo.App.<TEAMID>`，却**没有
同步改写** `BGTaskSchedulerPermittedIdentifiers`（上游 bug：
[nab138/iloader#649](https://github.com/nab138/iloader/issues/649)，
2026-09 时仍 Open。**该 issue 修复发布后，新版 iLoader 安装无需以下
补丁**），白名单又只做精确匹配，因此后台任务被拒——app 会明确报错
（错误卡片带一键复制），前台模式不受影响。

补丁：把 `support/patch-ipa-team.py`（单文件、纯标准库，Windows 可
运行）连同 ipa 一起发给接收方，用报错中改写后 bundle id 的末段作
team id 执行：

```bash
python3 patch-ipa-team.py TinyHttpServer-Debug-unsigned.ipa ABCD1234EF
# → TinyHttpServer-Debug-unsigned-ABCD1234EF.ipa
```

改完的 ipa 用 iLoader 正常签名安装，后台模式即可用（真机已验证）。

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
- `-Dvfd=posix` 走 FFM（静态链入的 libfallbackLinker/libffi）；模拟器
  已端到端验证，真机上的 FFM upcall（libffi closure）路径未验证。
