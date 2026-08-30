# Tiny Zero iOS 构建手册

把 [openjdk/mobile](https://github.com/openjdk/mobile) 的 iOS 真机 Zero JVM 构建成
Tiny Zero 裁剪版：静态 `libtinyjvm.a` + JNI 头文件 + 三模块（`java.base`、
`jdk.unsupported`、`jdk.crypto.cryptoki`）`lib/modules`，全程不需要真机或模拟器。

设计背景、裁剪边界与构建契约见上级目录的
`OpenJDK-Mobile-iOS-Tiny-Zero-Build.md`；本文件只讲**怎么准备环境、怎么构建、
有哪些限制**。

---

## 1. 外部依赖与下载地址

| 依赖 | 从哪里下载 | 说明 |
| --- | --- | --- |
| OpenJDK mobile 源码 | `https://github.com/openjdk/mobile.git` | `10-fetch.sh` 自动按 `MOBILE_REF`（40 位 commit SHA）checkout；`MOBILE_REPO` 也可指向本地已有 clone 以避免重复下载 |
| Boot JDK（**必须 JDK 28**） | `https://jdk.java.net/28/`（EA） | 见下方"为什么必须 28"；下载 macOS aarch64 的 `tar.gz`，解压到任意目录 |
| libffi + CUPS 支持包 | `https://download2.gluonhq.com/mobile/mobile-support-20250106.zip` | openjdk/mobile README 指定的 iOS 构建支持包；libffi 是 iOS arm64 静态库（min iOS 7.0），CUPS 为头文件 |
| autoconf | `brew install autoconf` | macOS 自带版本过旧 |

Boot JDK 下载示例（以页面上的实际链接为准）：

```bash
curl -fL -o jdk28.tar.gz \
  "https://download.java.net/java/early_access/jdk28/12/GPL/openjdk-28-ea+12_macos-aarch64_bin.tar.gz"
mkdir -p ~/bootjdks && tar xzf jdk28.tar.gz -C ~/bootjdks
```

**为什么 Boot JDK 必须是 28：**

- 源码树是 JDK 28-dev（class 文件版本 72）。configure 接受 26/27/28 作为
  Boot JDK，但流水线后段用 Boot JDK 的 `jmod`/`jlink`/`jimage` 直接读取
  class 72 的模块描述，JDK 26/27 的工具会报
  `Unsupported major.minor version 72.0`。
- JDK 24/25（ios-tools 时代文档推荐的版本）对这个源码树**不可用**。

支持包解压后需要的三个路径（对应 `config/build.env`）：

```text
<support>/libffi/include        # 含 ffi.h
<support>/libffi/libs           # 含 libffi.a
<support>/cups-2.3.6            # 含 cups/cups.h
```

---

## 2. 构建前置

| 项目 | 要求 |
| --- | --- |
| 操作系统 | macOS，Apple Silicon（构建机 aarch64，目标 `aarch64-macos-ios`） |
| Xcode | 完整版 Xcode（非仅 Command Line Tools）。upstream 硬性拒绝 Xcode 16 / 16.1（编译器 bug）；其余版本可用 |
| clang | upstream 声明的最低版本 **13.0**。低于 13 只警告不阻断（实测 clang 12.0.5 / Xcode 12.5.1 可完成全量构建）；如遇编译错误优先升级 Xcode |
| iOS SDK | 默认 `xcrun --sdk iphoneos --show-sdk-path`（实测 iPhoneOS 14.5 SDK 可用）；可用 `IOS_SDK` 覆盖 |
| Boot JDK | JDK 28（见上节），需含 `java`/`javac`/`jmod`/`jlink`/`jimage` |
| 磁盘 | ≥ 10 GB 可用（源码 + 构建树 + 产物） |
| 内存/并行 | 8 GB 机器建议 `JOBS=4`；16 GB 可用 8 |
| 其他命令 | `git bash make libtool nm ar awk sed grep shasum tar`（系统/Xcode 自带） |

---

## 3. 构建方式

### 3.1 配置

```bash
cp config/build.env.example config/build.env
```

填写关键字段：

```bash
MOBILE_REPO="https://github.com/openjdk/mobile.git"   # 或本地 clone 路径
MOBILE_REF="<40位commit SHA>"                          # 不允许 master 等浮动的 ref
BOOT_JDK="<jdk28 解压路径>/Contents/Home"
LIBFFI_INCLUDE="<support>/libffi/include"
LIBFFI_LIB_DIR="<support>/libffi/libs"
CUPS_INCLUDE="<support>/cups-2.3.6"
JOBS="4"
```

### 3.2 一键构建

```bash
./build.sh
```

流水线固定为 10 步，任何一步失败即停止（fail-fast）：

```text
00 环境与输入检查（SDK、libffi、Boot JDK 工具齐备性）
10 checkout 精确 commit + 施加受控 source transform（见 §4.2）
20 configure Tiny Zero + spec.gmk feature 契约校验
30 Pass-1 静态库构建（static-libs-image + jdk.unsupported-java）
40 从实际静态库扫描符号，生成精确 symbol keeper
50 Pass-2 HotSpot 增量重建 + keeper 锚定图三层校验
60 三个 jmod + jlink 生成三模块 runtime image
70 打包 libtinyjvm.a / include / runtime / meta
80 静态产物契约校验（符号族、模块集、feature 集、SHA256SUMS）
90 生成 dist tar.gz 与独立校验和
```

每个脚本也可单独重跑（例如从失败步骤续跑）：

```bash
./scripts/60-build-modules.sh
```

### 3.3 产物与校验

```text
dist/device/                     # canonical deliverable
├── lib/libtinyjvm.a             # libjvm + libffi + libjava/libjimage/libnet/libnio/libzip + j2pkcs11
├── include/                     # jni.h、jni_md.h、classfile_constants.h、ios/
├── runtime/lib/modules          # 三模块 jimage
├── runtime/release
└── meta/                        # 环境记录、keeper 源码与符号表、SHA256SUMS

dist/tiny-openjdk-ios-device.tar.gz(.sha256)
```

验证：

```bash
cd dist/device && shasum -a 256 -c meta/SHA256SUMS
cd .. && shasum -a 256 -c tiny-openjdk-ios-device.tar.gz.sha256
```

---

## 4. 构建限制

### 4.1 无运行时验证

本流水线只做**构建与静态契约校验**。不包含真机/模拟器启动、
`JNI_CreateJavaVM` 调用、PKCS#11 初始化、TCP/NIO/TLS、内存上限（`-Xmx`）等
任何运行时测试。这些属于后续 Runtime Validation 阶段。

### 4.2 源码修改已合入仓库（不再有 source transform）

历史版本由 `10-fetch.sh` 在 checkout 后施加 source transform，并把 diff
存档到 `dist/device/meta/*.patch`。这些改动现已**全部直接合入本仓库**
（git 历史是唯一事实来源，上游形态变化会在 merge 时显式冲突），
`10-fetch.sh` 只做**存在性校验**：`MOBILE_REF` 早于合入 commit 时直接
失败并提示升级，绝不静默构建一个未修复的树。合入内容：

1. `src/hotspot/share/prims/jni.cpp`：`JNI_CreateJavaVM` 入口调用一次
   `tiny_symbol_keeper_anchor()`（keeper 自锚定，App 无需 `-all_load`/`-force_load`；
   形态契约由 `50-build-pass2.sh` 的 defined/undefined 符号校验把关）。
2. `make/hotspot/lib/JvmFeatures.gmk`：`OPT_SPEED_SRC` 置空。opt-size 下
   upstream 会把一批文件提升为 `-O3`，与 `-Os` 编译的预编译头
   （`__OPTIMIZE_SIZE__` 宏）冲突；Tiny Zero 尺寸优先，统一 `-Os`。
   仅影响开启 opt-size 特性的构建。iOS Zero 默认会过滤 opt-size，
   该组合为本项目新启用。
3. 模拟器/静态嵌入修复（sim MAP_JIT、zero 解释器入口回退与按需链接、
   Throwable pre-init 守卫、静态链接 `RTLD_DEFAULT` native 查找、
   bsd_zero 崩溃 pc、信号处理器 lazy W^X）：见各 commit 说明与
   `tiny-zero-ios-demo/README.md` §3/§6。

`src/hotspot/os/bsd/symbol_keeper.cpp` 仍为**构建期生成物**（Pass-1 为
stub，Pass-2 由实际静态库符号 `Java_*`/`JNI_OnLoad*`/`JIMAGE_*`/`JDK_*`
自动生成），源码归档于 `meta/symbol_keeper.cpp`，不进入 git。

### 4.3 工具链适配（与设计文档 §16 的差异）

JDK 28 的 `jmod`/`jlink` 引入了两个新校验，脚本做了对应适配：

- **构建描述符校验**：jlink 要求目标 `java.base` 的
  `jdk/internal/misc/resources/release.txt` 与自身 runtime 的一致。打包 jmod
  前从 Boot JDK 同步该文件（纯元数据，不影响运行行为）。
- **目标平台枚举校验**：jlink 通过自身 `java.base` 的 `OperatingSystem`
  枚举解析 `ModuleTarget`，发行版 JDK 不含 `ios` 成员（只有 mobile 源码树
  扩展了它）。因此 `--target-platform` 使用 `macos-aarch64`：同为
  little-endian aarch64，生成的 jimage 完全等价；仅链接期 `release` 元数据
  的 `OS_NAME` 标记为 mac，设备上的 `os.name` 由 VM 决定，不受影响。
- `jdk.unsupported` 没有 native 库，`static-libs-image` 不会为它产出
  exploded classes，流水线显式追加 `jdk.unsupported-java` 目标。

（替代方案探索结论：用源码树 exploded `jdk.jlink` + upgrade/patch
`java.base` 均不可行——前者禁止升级 `java.base`，后者触发 HotSpot 对
`java.lang.reflect.Field` 布局的硬校验拒绝启动。）

### 4.4 其他限制

- 产物面向 **iOS 真机 arm64**；simulator 目标不在本流水线范围。
- LTO、CDS、debug symbols 均关闭；headless-only。
- Xcode 12.5.1 / iPhoneOS 14.5 SDK 组合实测可完成构建，但低于 upstream
  支持的 clang 13.0，属于不受支持配置；不同 Xcode/SDK 组合产物未做等价性验证。
- 升级 `MOBILE_REF` 后重跑 `./build.sh`：契约满足则直接成功，否则在明确
  的检查点失败（见设计文档 §34）。
- 最终 iOS App 集成要求：`DEAD_CODE_STRIPPING = YES`，禁止
  `-all_load` / `-force_load libtinyjvm.a`（见设计文档 §31）。
