# Tiny Zero iOS Demo — TinyHttpServer

在 iOS app 内嵌 OpenJDK Mobile **Zero JVM**,运行一个监听 `127.0.0.1:<port>` 的
迷你 HTTP server(任何请求都返回同一个 HTML 页面:JVM 信息、系统时间与全部
`System.getProperties()`),并通过 iOS 26 的
`BGContinuedProcessingTask` 在后台长期运行(以 30 天为进度窗口);
模拟器与 iOS<26 走 `beginBackgroundTask` 回退。

> **状态(2026-08-30)**:模拟器 demo **完整运行并通过从零复现验证**
> (`support/run-sim-demo.sh`,清空全部产物后单脚本重建,约 3 分钟构建;
> JVM 引导热启动约 10 秒,冷启动实测可到 1–4 分钟):curl 返回 HTTP 200 与
> Tiny Zero HTML(含系统时间与 properties 表),心跳/请求日志落盘,
> `-autostop` 优雅停止。真机(device slice)尚未部署验证。

## 1. 目录结构

```text
tiny-zero-ios-demo/
├── project.yml                  # xcodegen 工程定义(生成 TinyHttpServer.xcodeproj)
├── App/
│   ├── TinyHttpServerApp.swift  # 入口 + AppDelegate(BGTask 注册必须在启动早期)
│   ├── ContentView.swift        # UI:端口/后台任务开关/启停/30天进度/错误/控制台
│   ├── JvmModel.swift           # @Observable 状态机、日志与状态持久化、C 回调桥
│   ├── BackgroundExecution.swift# 原生 BGContinuedProcessingTask(非反射)+ 回退实现
│   ├── Info.plist               # xcodegen 生成管理(BGTaskSchedulerPermittedIdentifiers)
│   └── Simulator.entitlements   # 模拟器构建的 JIT entitlement(MAP_JIT 需要)
├── Native/
│   ├── jvm_bridge.h/.mm         # JNI 桥:CreateJavaVM/RegisterNatives/线程/停止/日志回调
│   └── ios_wx_shims.mm          # weak 符号补齐(见 §5 链接要求)
├── Java/TinyHttpServer.java     # Java 侧 HTTP server(纯 java.base)
├── support/
│   ├── run-sim-demo.sh          # ★ 一键复现:构建→安装→启动→curl 验证(幂等)
│   ├── build-sim-libffi.sh      # 交叉编译 iOS Simulator 版 libffi(首次,装到 ~/ios-sim-support)
│   ├── build-sim-jvm.sh         # Zero variant 模拟器 JVM:6 个受控 patch +
│   │                            #   jmod/jlink 产出 patched runtime image
│   └── build-java.sh            # Boot JDK javac → third_party/TinyHttpServer.jar
├── third_party/                 # 构建产物(gitignore,由脚本生成)
├── work-generated/              # sim jmod/jlink 中间产物(gitignore)
└── build/                       # xcodebuild 输出(gitignore)
```

## 2. 一键复现(已实测)

```bash
cd tiny-zero-ios-demo
./support/run-sim-demo.sh
```

脚本幂等,自动完成:创建/启动 iPhone 13(iOS 26.5)模拟器 → 编译缺失的
libffi/Zero JVM/jar/app → ad-hoc 补签 entitlement → 安装 →
`-autostart 8080 -direct` 启动 → 轮询 curl 直到 HTTP 200 → 打印响应与
落盘日志。实测从清空产物到 200 约 3 分钟(其中 OpenJDK 静态库构建 ~2:50,
JVM 引导 ~10 秒)。

实测输出(节选):

```
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
<h1>Hello from the Tiny Zero JVM &#x1f34f;</h1>
<p>servedRequests=2, uptime=9s</p>
<h2>System time</h2>
<p><code>2026-08-30T10:45:52.948Z</code> …(epoch ms、zone: Asia/Shanghai、本地时间)</p>
<h2>System.getProperties()</h2>
… 46 项排序后的属性表(java.version / java.vm.name / java.home / os.name …)
--- Documents/java-console.log ---
1788036896029 http: 127.0.0.1 "GET / HTTP/1.1"
```

### 前置条件

| 依赖 | 说明 |
| --- | --- |
| `../tiny-zero-ios-build` | 先完成 Tiny Zero 构建(`./build.sh`),提供源码树、Boot JDK、CUPS 配置(`config/build.env`) |
| Xcode 26+(含 iOS 26.5 模拟器 runtime) | 实测 Xcode 26.6 |
| `xcodegen` | `brew install xcodegen` |
| JDK 28 Boot JDK、Gluon 支持包 | 由 tiny-zero-ios-build 的 `config/build.env` 指向 |

### 分步(等价于一键脚本)

```bash
cd tiny-zero-ios-demo
./support/build-sim-libffi.sh      # 首次:模拟器 libffi → ~/ios-sim-support(已装则秒过)
./support/build-sim-jvm.sh         # Zero JVM(6 patch)+ jmod/jlink + conf/tzdb → third_party/
./support/build-java.sh            # → third_party/TinyHttpServer.jar
xcodegen generate
xcodebuild -project TinyHttpServer.xcodeproj -scheme TinyHttpServer \
  -sdk iphonesimulator -configuration Debug -derivedDataPath build \
  ARCHS=arm64 build
# 模拟器 ad-hoc 签名丢 entitlement(MAP_JIT 需要),构建后手动补签:
codesign -f -s - --entitlements App/Simulator.entitlements \
  build/Build/Products/Debug-iphonesimulator/TinyHttpServer.app

# 设备(Xcode 26 默认不带 iPhone 13 机型,已存在则跳过)
xcrun simctl create "iPhone 13" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-13 \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcrun simctl boot "iPhone 13"
xcrun simctl install "iPhone 13" \
  build/Build/Products/Debug-iphonesimulator/TinyHttpServer.app

xcrun simctl launch "iPhone 13" com.wkgcass.TinyHttpServer \
  -autostart 8080 -direct        # 引导约 10 秒后监听
curl -v http://127.0.0.1:8080/   # 模拟器与 Mac 共享 loopback
CONTAINER=$(xcrun simctl get_app_container "iPhone 13" \
  com.wkgcass.TinyHttpServer data)
cat "$CONTAINER/Documents/java-console.log"
```

### 手动启动与 GUI 模拟器

```bash
# 打开 Simulator.app 图形窗口并显示设备(设备需已 boot)
open -a Simulator --args -CurrentDeviceUDID "$(xcrun simctl list devices |
  grep '"iPhone 13"' | grep -oE '[0-9A-F-]{36}' | head -1)"
# 或设备已 boot 时简单地:
open -a Simulator

# 启动 app(热启动引导约 10–60 秒后监听,冷启动可达数分钟;UI 可手动交互)
xcrun simctl launch "iPhone 13" com.wkgcass.TinyHttpServer -autostart 8080 -direct
#   -direct        前台直启(不申请后台任务)——模拟器上可正常跑通
#   不带 -direct   走 BGContinuedProcessingTask:模拟器上 submit 必失败
#                  (code=1),按设计直接报错、JVM 不启动;真机才是真验证
#   -autostop 120  到时自动"停止"(可选)
#   不带 -autostart 启动后停在 UI,手动点"启动"

# 验证 / 查看落盘日志 / 停止
curl http://127.0.0.1:8080/
tail -f "$(xcrun simctl get_app_container "iPhone 13" \
  com.wkgcass.TinyHttpServer data)/Documents/java-console.log"
xcrun simctl terminate "iPhone 13" com.wkgcass.TinyHttpServer
```

## 3. 模拟器 JVM:Zero variant、6 个受控 patch 与 runtime image

模拟器使用 **Zero variant**(与真机 Tiny Zero 相同的解释器路径)。
`build-sim-jvm.sh` 在源码树上应用 **6 个精确、幂等、失败即停的 source
patch**(除 #3 外仅影响 `TARGET_OS_SIMULATOR`,对真机构建无行为影响),
再产出静态库与 runtime image:

1. **MAP_JIT**(`os_bsd.cpp`):`anon_mmap` 的 `__IOS__` 分支在模拟器下
   恢复 `MAP_JIT`——macOS 26 要求可执行映射必须是 MAP_JIT 的。
2. **Zero entry fallback + 按需链接**(`zeroInterpreter_zero.cpp`):
   未链接方法的 `from_interpreted_entry()` 为 null 时回退解释器入口表;
   常量池 cache 为 null 时按需 `InstanceKlass::link_class`
   (verify→rewrite→link)。
3. **Throwable guard**(`java.base/Throwable.java`):pre-init 窗口
   (`!VM.isBooted()`)的 `getOurStackTrace()` 返回空数组。
4. **Native lookup handle**(`os_posix.cpp`):静态链接时
   `get_default_process_handle()` 改返回 `RTLD_DEFAULT`(见 §6 根因)。
5. **lazy W^X**(`signals_posix.cpp`):`javaSignalHandler` 入口处理
   `SIGBUS/BUS_ADRALN`——macOS 26 的 MAP_JIT 页严格"可写或可执行"二态,
   而 iOS 构建把上游 W^X healing 的真实翻页调用裁掉了;按 fault 方向
   翻转(dlsym 解析,绕过 SDK 的 iOS 不可用标注)并重试指令。
6. **bsd_zero 崩溃报告**(`os_bsd_zero.cpp`):`ucontext_get_pc` 原为
   `ShouldNotCallThis`(错误报告路径二次 fatal,hs_err 打不出 native
   栈);darwin arm64 下返回真实 pc,仅崩溃路径调用。

configure 侧:`--with-jvm-variants=zero`、`--with-jvm-features="-jfr"`
(JFR 的 BSD `SystemProcessInterface` 未实现)、
`--with-extra-asflags="-target arm64-apple-ios14.5-simulator -isysroot …"`
(汇编步骤缺 `-target` 会把 `copy_bsd_aarch64.S` 编成 macOS 平台对象)。

runtime image:由 **sim 构建自己的 exploded classes** 做 jmod/jlink
(含 release 描述符同步与 `--target-platform macos-aarch64`,同 tiny-zero
流水线的适配),再从 Boot JDK 拷贝 `conf/`(java.security 等,三模块
jlink 镜像不带)与 `lib/tzdb.dat`(`sun.util.calendar.ZoneInfoFile` 读取
`<java_home>/lib/tzdb.dat`,缺失会导致 java.util 时区全部
`NoClassDefFoundError`)到 `lib/conf`、`lib/lib/`。

**静态链入的内部库与 `System.loadLibrary`**(如 `System.loadLibrary("jimage")`,
java.time 的 `ZoneRulesProvider` 初始化会经 boot loader 资源查找走到):
上游本就有完整的静态库协议,本 demo 只补了最后一块——在系统库路径
(`<bundle>/lib`)放 **0 字节 marker 文件**(`libjimage.dylib`、
`libj2pkcs11.dylib`)。链条:marker 触发 `NativeLibraries.findBuiltinLib`
→ 剥掉前后缀后在进程内查 `JNI_OnLoad_<名>`(os_posix 补丁的
`RTLD_DEFAULT` + `-export_dynamic` + symbol keeper 锚定的
`DEF_STATIC_JNI_OnLoad` 定义,返回 `JNI_VERSION_1_8`)→ builtin 路径
**跳过 dlopen**、直接使用进程句柄,后续符号经 RTLD_DEFAULT 解析。
**保持静态链入、符号已暴露、内部库 loadLibrary 等价于跳过**,零 JVM
代码改动。

内部库排查结论(交付模块 java.base + jdk.unsupported + jdk.crypto.cryptoki;
只有 `System.loadLibrary` 失败会抛 `UnsatisfiedLinkError`,
`BootLoader.loadLibrary` 失败**静默返回 null**、natives 继续经进程符号解析
——demo 的 ServerSocket/zip 已实证该路径):

| 库 | 加载方式 | 触发点 | 处理 |
| --- | --- | --- | --- |
| `jimage` | `System.loadLibrary` | jimage 读取(模块资源/ServiceLoader) | **marker 必需** ✓ |
| `j2pkcs11` | `System.loadLibrary` | `sun.security.pkcs11.wrapper.PKCS11` clinit(启用 SunPKCS11 时) | **marker 必需** ✓ |
| `net` | `BootLoader.loadLibrary`×6 | InetAddress/NetworkInterface/IOUtil 等 | 无需;**且不能加**(archive 无 `JNI_OnLoad_net` 定义,加了会落入真 dlopen 报错) |
| `nio`/`zip` | `BootLoader.loadLibrary` | IOUtil/UnixNativeDispatcher/ZipUtils | 无需(静默;符号已定义,真需要时可照加) |
| `osxsecurity` | `BootLoader.loadLibrary` | macOS KeychainStore | 库未链入,静默跳过 |
| `fallbackLinker` | `System.loadLibrary` | 仅 java.lang.foreign 指定 fallback ABI | 库未构建;不使用 FFM 则不触及 |

`jdk.unsupported` 没有任何 loadLibrary 调用(natives 在 libjava/hotspot,
直接符号解析)。真机 device slice 的 bundle 布局同理适用。

## 4. App 结构要点

- **JVM 启动时序与模式开关**:UI"后台任务"开关(运行中锁定):
  - 开(默认):提交 `BGContinuedProcessingTaskRequest` → **launchHandler
    里启动 JVM**。**不做任何静默降级**:模拟器上 submit 返回 code=1
    (unavailable)时直接报"submit 失败"且 JVM 不启动;提交成功但
    launchHandler 10 秒未触发同样报错。只有 iOS<26(该 API 不存在)
    才使用 `beginBackgroundTask`。
  - 关:**前台直启**(`-direct`),与后台任务机制完全隔离。
- **identifier**:iOS 26.5 拒绝 SDK 头文件建议的通配符形式,三处
  (plist/register/request)使用同一具体 id
  `com.wkgcass.tinyhttpserver.continued.demo`。
- **NSProgress** 同步 30 天窗口;**持久化**:日志每行落盘
  `Documents/java-console.log`,状态落 `java-state.json`,杀进程重开
  可见中断状态与历史。
- **`-autostart <port>` / `-autostop <s>` / `-direct`**:自动化验证参数。
- **停止语义**:按钮为"停止并退出 App"(或 `-autostop`)——停止即
  结束**整个 app 进程**(Java 程序的 `System.exit`/被杀语义)。停止
  开始时即收尾后台任务(NSProgress 走满 → `setTaskCompleted`),UI
  进度条显示完成、按钮转"退出中…";日志与状态已提前落盘,重开
  app 可见。退出仅依赖 `System.exit(0)`;若其未在 10 秒内完成(上游
  间歇缺陷,当前构建 15/15 未复现),提示手动关闭,绝不强杀进程。

## 5. 链接与运行时要求(app 集成 libtinyjvm 时必须)

1. `-lz`(zlib)、`-framework CoreFoundation`(java.base locale/属性 native)
2. **`-Wl,-export_dynamic`**(模拟器):把静态链接的 JNI 符号
   (`Java_*`/`JVM_*`)放进动态符号表,配合 §3 patch 4 的 `RTLD_DEFAULT`
   查找;缺失会导致所有 native 解析落入 Java `ClassLoader.findNative`
   兜底并死锁(§6)。
3. `Native/ios_wx_shims.mm`:`os::_jit_exec_enabled` 等三个符号的 weak
   定义(Zero variant 不编译 bsd_aarch64 的真实定义)。
4. **app 类的 native 方法需显式 `RegisterNatives`**(静态构建中
   classloader 查找为空):`jvm_bridge.mm` 注册了 `nativeLog`。
5. bundle 布局:静态 iOS JVM 推导 `java_home = <可执行目录>/lib`
   (`-Djava.home` 会被覆盖),因此必须是
   **`<bundle>/lib/lib/modules` + `<bundle>/lib/conf/` +
   `<bundle>/lib/lib/tzdb.dat`**(tzdb 供 java.util/java.time 时区)
   **+ `<bundle>/lib/libjimage.dylib`、`<bundle>/lib/libj2pkcs11.dylib`**
   (0 字节 marker,见 §3 静态库协议)。

JVM 参数(`jvm_bridge.mm`,当前实测值):`-Xrs -Djava.awt.headless=true
-XX:+UseSerialGC -Xint -XX:+UnlockDiagnosticVMOptions -XX:-ImplicitNullChecks
-XX:-UseCompactObjectHeaders -Xshare:off -Xms4g -XX:NewSize=1536m -Xss32m
-XX:-StackTraceInThrowable -XX:-RewriteBytecodes`。
说明:`-Xms/-Xss/NewSize` 是调试期保守值(实际引导后 heapUsed ≈ 7.5M,
可按需调小);`-Xint`/`-ImplicitNullChecks`/`-StackTraceInThrowable`
规避 Darwin 信号路径缺口;`-RewriteBytecodes`/`-UseCompactObjectHeaders`
为验证期保守项。

## 6. 已解决的关键问题(排障记录)

- **引导期 NoClassDefFoundError 构造风暴(数百万次,最终根因)**:
  `os::get_default_process_handle()` 使用 `dlopen(0, RTLD_FIRST)`,在
  macOS two-level namespace 下**只搜索主可执行镜像**,而静态链接的 JNI
  符号位于链接进 app 的 dylib(debug.dylib)中——每个 native 解析都落到
  Java `ClassLoader.findNative` 兜底,在类初始化重入时拿到 null holder
  而 NPE,异常构造相互触发直至引导期 GC。修复 = §3 patch 4(RTLD_DEFAULT)
  + `-export_dynamic` + `RegisterNatives`。
  (排障期间曾误判为"Zero 执行流错位";字节码级追踪证明
  `desiredAssertionStatus → Class.<clinit> → runtimeSetup →
  registerNatives → NativeLookup → findNative` 完全符合 Java 语义。)
- **早期崩溃链(均以受控 patch 解决)**:CodeCache 无法保留(MAP_JIT)、
  MAP_JIT 写保护(lazy W^X)、未链接方法入口/常量池 cache(entry
  fallback + 按需 link_class)、pre-init 的 getStackTrace NPE(Throwable
  guard)。
- **`System.exit` 间歇性卡住(历史复现,当前不可复现)**:停止的两级
  终止中,stage 1 的 `System.exit(0)` 曾多次卡在 JDK exit 路径内部
  (伴随 "no jimage in system library path" 警告,Java 冻结而进程
  存活)。三组对照实验(独立线程 vs 同线程调用、attach 机制开 vs 关)
  共 **15/15 轮在当前构建上全部干净自退**,attach 假说与调用线程假说
  均被排除;精确根因未获得栈级实锤(卡住窗口抓栈多次扑空)。怀疑与
  exit 内部日志失败处理经宿主重定向的 `System.err` 回调 JNI 的时序
  竞争相关(修复"双份日志"后未再复现)。按决策**不保留任何强制
  退出**:宿主只发起 `System.exit(0)` 并观察,若超时未完成则报错
  提示"请上滑手动关闭应用",进程交给用户处理。
- **java.time 时区两连修(本轮)**:① 缺 `tzdb.dat` → `ZoneInfoFile`
  `NoClassDefFoundError`(打包修复,§3);② `ZoneRulesProvider` clinit 的
  ServiceLoader 扫描 → Java 侧 jimage → `System.loadLibrary("jimage")`
  `UnsatisfiedLinkError`。靠 Java 侧打印完整 cause 链定位到根因后,用
  0 字节 marker 文件走通上游静态库协议(dlopen 被跳过),java.time
  全链路恢复,详见 §3。
- 诊断工具保留:`[zero-sig]`(每个 SIGSEGV 的 addr/pc 打 stderr,§3
  patch 5 内)、hs_err 于 app 沙盒 `tmp/`。

## 7. 已知限制

- 模拟器上 BGTaskScheduler 不可用(submit code=1),
  `BGContinuedProcessingTask` 的真实验证需 iOS 26 真机。
- 模拟器 ad-hoc 签名丢 entitlement,每次构建后需手动补签(§2)。

## 8. 真机部署(需要你参与)

1. `xcodegen generate` 后用 Xcode 打开工程,Signing & Capabilities 选
   你的 Team(免费个人账号即可)
2. iPhone 13 连接后直接 Run(链接 device slice `libtinyjvm.a`,
   Tiny Zero/Zero variant)。§5 的链接要求同样适用;真机无 MAP_JIT
   语义,CodeCache 行为是首要观察点(遇到问题带 `tmp/hs_err_pid*.log`)
3. iOS 26 真机上 `BGContinuedProcessingTask` 生效(submit 已按 iOS 26.5
   实测语义实现)
