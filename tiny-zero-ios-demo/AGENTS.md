# AGENTS.md — tiny-zero-ios-demo 维护说明

面向后续维护者的架构与契约说明。使用步骤见 `README.md`；可复用嵌入层的
集成指南见 `JvmEmbed/README.md`。

## 目录边界

- `JvmEmbed/`：**公共部分**，可拷贝到其他工程复用（JNI 桥、W^X weak
  shims、IosBootstrap 日志转发、BGContinuedProcessingTask 封装）。
  不依赖 vproxy；main class、program args、额外 VM options、DNS 配置
  路径全部由调用方传入。
- `App/`：**程序部分**，本 demo 的 UI 与编排（JvmModel 状态机、
  ContentView、entitlements）。
- `support/`：构建/运行脚本；`third_party/`、`work-generated/`、
  `build/`、`*.xcodeproj` 均为生成物，不入 git。

## 启动链路

`JvmModel.start()` → （后台模式先 `BackgroundExecution.begin()`）→
`launchJVM()`：bundle 资源完整性检查（lib/modules、两个 jar、
`Frameworks/` 下的 libpni/libvfdposix）→ `tinyvm_write_dns_config`（经
libresolv `res_9_*` 收集系统 DNS 写入 `<user.home>/.vproxy/resolv.conf`，
模拟器与真机同一路径；失败即报错不启动）→ `tinyvm_start("vproxy.jar:
vproxy-ios-bootstrap.jar", Documents, "io.vproxy.app.app.Main",
["-Deploy=helloworld"], ["--add-exports=…", "--enable-native-access=
ALL-UNNAMED", "-Dvfd=posix", "-Djava.library.path=<bundle>/Frameworks/
libpni.framework:…/libvfdposix.framework"], …)`。vproxy **零修改**；
`-Djava.home` 不传（os_bsd 推导 `java_home=<bundle>/lib`）；
`-Duser.home` 指向 `Documents/`——真机数据容器**根目录只读**（模拟器
可写，不要以模拟器表现推断真机）。

`-Dvfd=posix` 让 vproxy 走原生 PosixFDs（libae 事件循环）而非 JDK NIO
实现：`PosixFDs` 构造时 `System.loadLibrary("vfdposix")`，JVM 在
`java.library.path` 列出的 framework 目录内找到内层
`libvfdposix.dylib`；其对 `@rpath/libpni.framework/libpni.dylib` 的依赖
由 app 自带的 `@executable_path/Frameworks` rpath 解析（Java 侧也会显式
`System.loadLibrary("pni")`）。FFM downcall 走 Zero 变种静态链入的
libfallbackLinker（见 `../tiny-zero-ios-build/AGENTS.md`）。

## 链接与 bundle 契约（改动打包/链接时必读）

- `-lz -framework CoreFoundation -Wl,-export_dynamic`；
  `DEAD_CODE_STRIPPING=YES`；禁止 `-all_load`/`-force_load`（keeper 由
  桥内锚定调用拉入）。
- 真机 Debug 必须 `ENABLE_DEBUG_DYLIB[sdk=iphoneos*]=NO`（Xcode 26 把
  app 代码连同静态 JVM 链进 `*.debug.dylib`，java_home 推导与进程符号
  解析都以主可执行文件为前提）。
- 模拟器：`com.apple.security.cs.allow-jit` entitlement + 每次构建后
  `codesign -f -s -` 补签（ad-hoc 签名丢 entitlement）。
- `<bundle>/lib` 树（modules/release/conf/tzdb.dat/三个极小 Mach-O
  marker dylib——内容不会被加载，但外部签名工具要求每个 `.dylib`
  都是合法 Mach-O，0 字节会被拒）
  由 `support/build-sim-jvm.sh`（模拟器）或
  `support/run-device-demo.py`（真机，从 dist/device/runtime 拷贝）装配，
  两侧共用 `tiny-zero-ios-build/scripts/lib/runtime-image.sh`，布局保持
  一致。
- `<bundle>/Frameworks/{libpni,libvfdposix}.framework`：vproxy 原生库
  （`-Dvfd=posix` 载荷，`make ios-vfdposix` 产物）。`build-java.sh` 双 SDK
  构建到 `third_party/vproxy-frameworks/<sdk>/`，`stage-frameworks.sh`
  把对应变体暂存到 `third_party/Frameworks/`（project.yml 以 Embed
  Frameworks 拷入 bundle；不参与链接，仅运行时 System.loadLibrary 加载）。
  **暂存目录与存储目录拼写必须不同**（`Frameworks` vs
  `vproxy-frameworks`）：默认 APFS 大小写不敏感，同名会互相覆盖。模拟器
  流程默认暂存 simulator 切片；真机/打包流程先重暂存 iphoneos 切片
  （与 `<bundle>/lib` 的 marker dylib 同一套就地换切方案）。
- 内部库 marker 的取舍（为什么只有 jimage/j2pkcs11 有 marker）见
  `../tiny-zero-ios-build/AGENTS.md` 的 runtime 树契约一节。
- app 自定义 native 方法必须显式 `RegisterNatives`（静态构建中
  `ClassLoader.findNative` 恒为空）。

## VM 参数（JvmEmbed/Native/jvm_bridge.mm）

必需集：`-Xrs -Djava.awt.headless=true -XX:+UseSerialGC -Xint
-XX:+UnlockDiagnosticVMOptions -XX:-ImplicitNullChecks
-XX:-UseCompactObjectHeaders -Xshare:off -XX:-RewriteBytecodes
-XX:+DisableAttachMechanism`（每条的原因见代码注释；多为规避
Darwin/Zero 信号路径缺口与引导期状态）。`-Xms4g -XX:NewSize=1536m -Xss32m` 是引导期
保守值——实测引导完成后 heapUsed ≈ 7.5 MB，收紧内存上限时优先调这里。

## 后台任务（iOS 26 BGContinuedProcessingTask）

语义模型：submit(`.fail`) 成功即在前台开始工作负载，launchHandler 由
系统择机触发（数秒后/退后台时/进程被杀后的后台重启）只做接管
（expiration handler + 30 天 NSProgress）或无 UI 续跑。**不做静默降
级**：submit 失败直接报错且 JVM 不启动；只有 iOS<26（API 不存在）才用
`beginBackgroundTask`。

identifier 三道检查（缺一即静默不派发，改动 bundle id 时注意）：
① plist 同时列通配符与具体 id；② register/submit 用同一具体 id；
③ id 前缀与 bundle id **大小写一致**。当前实现：运行时从
`Bundle.main.bundleIdentifier` 派生，plist 用
`$(PRODUCT_BUNDLE_IDENTIFIER)`。

expiration 必须 `setTaskCompleted`：悬空任务会被系统 SIGKILL 进程。
停止/退出时先收尾任务（NSProgress 走满 → setTaskCompleted）再退出。
模拟器上 BGTaskScheduler 不可用（submit code=1），属预期，UI 会提示走
前台模式；continued processing 的真实验证只能真机。

## 停止语义

"停止" = 结束**整个 app 进程**（Java 程序的 `System.exit` 语义）。桥只
发起 `System.exit(0)` 并观察，**绝不强杀**：JVM 仍在引导或 exit 路径未
在预算内完成时返回错误，UI 恢复运行态并提示重试或手动上滑关闭。
引导期停止的等待预算由 `tinyvm_stop(30)` 给出。

## 日志与持久化

- stdout/stderr 经 `IosBootstrap` 逐行**原样**转发（含 ANSI；按字节切
  行，UTF-8 安全），Swift 侧解析 SGR 分段着色，落盘
  `Documents/java-console.log` 为剥离转义后的纯文本。
- 状态落 `Documents/java-state.json`（杀进程重开可见中断状态与历史）；
  每行日志触发节流（5s）持久化，相位转换时立即持久化。
- 内存日志窗口 400 行；恢复时读文件尾 64 KB。

## 验证

- 模拟器端到端：`support/run-sim-demo.sh`（幂等；构建→安装→
  `-autostart -direct`→curl HTTP 200 + TCP/UDP 自检 + 落盘日志）。
  从零约 3–10 分钟（大头是 sim 静态库构建）；JVM 引导热启动约 10 秒，
  冷启动可达 1–4 分钟，curl 轮询预算 400 秒。
- 真机：`support/run-device-demo.py`（`DEVICE`/`TEAM_ID`/`LAUNCH_ARGS`/
  `DEVICE_IP` 可覆盖）。注意：手机必须解锁才能拉起；app 参数
  必须用 `--` 与 devicectl 自身参数分隔；个人团队描述文件 7 天有效，
  过期先靠 `-allowProvisioningUpdates` 无人值守续签（依赖 Xcode 的
  Apple ID 会话）；HTTP 验证默认走 `<设备名>.local`。
- 打包未签名 ipa（分发）：`support/package-ipa.py`（无签名构建 +
  `Payload/` 打包 + bundle 校验；接收方自行签名安装）。
- 本机离线签名 ipa：`support/sign-ipa.py`（本地描述文件 + 钥匙串证书，
  不需要手机在线；按哈希选证书避免同名二义，entitlements 取自描述文件，
  深度 `codesign --verify`。设备/team/证书的查询命令见 README）。
- 真机崩溃排查：hs_err 在 app 沙盒 `tmp/`（`devicectl device copy from
  --domain-type appDataContainer --domain-identifier <id> --source tmp/`）；
  模拟器每个 SIGSEGV 有 `[zero-sig] addr/pc` 输出（signals_posix 修复内）。

## 依赖版本锚点

- Xcode 26+（含 iOS 26.5 模拟器 runtime）；`xcodegen`。
- vproxy：`../vproxy`（同级目录）`./gradlew shadowjar` 的产物
  `build/libs/vproxy.jar`，或 `VPROXY_JAR=<路径>` 覆盖；**jar 已存在则
  不重建**，脚本只拷贝。libpni/libvfdposix 框架另由 vproxy 根目录的
  `SDK_NAME=<sdk> make ios-vfdposix` 双 SDK 构建并入库
  `third_party/vproxy-frameworks/`（已存在则跳过；`VPROXY_ROOT` 可覆盖
  checkout 位置）。
- Boot JDK 28、Gluon 支持包路径由 `../tiny-zero-ios-build/config/
  build.env` 提供；模拟器 libffi 由 `support/build-sim-libffi.sh` 装到
  `~/ios-sim-support/libffi`（一次性）。
