# OpenJDK Mobile iOS Tiny Zero：稳定裁剪构建设计

> 目标：在 **不连接真机、不运行模拟器、不做运行时测试** 的前提下，把 OpenJDK Mobile 的 iOS 真机 Zero JVM 做成一套可重复、可审计、可持续维护的 **Tiny Zero** 构建，并稳定产出可供后续 iOS 工程链接的静态 JVM、JNI 头文件和三模块 `lib/modules`。
>
> 本文对应附带的 `tiny-zero-ios-build` 脚本目录。本文讨论的是**构建和裁剪阶段**；真机内存、功能、网络和性能测试明确留到后续阶段。

---

## 1. 实际场景与约束

本方案不是通用 OpenJDK Mobile 发行版，而是针对以下实际场景定制：

- 目标平台：**iOS 真机 arm64**。
- JVM：必须使用 OpenJDK Mobile 当前可用于普通 iOS 真机的 **Zero** 模式，不使用 Server/C1/C2。
- 应用形态：长期运行的网络服务/网络扩展方向。
- Java 侧会使用 TCP/NIO/线程/加密等能力，并可能维持约百条 TCP 连接。
- 内存目标后续会围绕约 `-Xmx20M ~ -Xmx32M` 调优，但**本阶段不进行真机内存测试**。
- 当前应用模块依赖只有：

```java
requires java.base;
requires jdk.unsupported;
requires jdk.crypto.cryptoki;
```

因此本阶段的核心目标是：

1. JVM 只保留 Zero + Serial GC + 必要 runtime。
2. Java runtime image 只保留 3 个模块。
3. Native 只发布 Java Base 所需 archive + `jdk.crypto.cryptoki` native archive + `libffi.a`。
4. 为静态 JNI/native lookup 自动生成精确 symbol keeper。
5. 所有版本、配置、产物都可记录、校验和复现。
6. 不为了“编译少一点”过早大改 OpenJDK build graph；先保证**最终发布物真正裁干净**。

---

## 2. 为什么最终方案是 Tiny Zero，而不是 Minimal

OpenJDK Mobile 当前 README 明确说明：

- iOS 默认 JVM 是 Zero。
- 原因是 iOS 不提供普通 HotSpot 所依赖的 writable + executable 代码区使用模式。
- Server 等其他 variant 主要可用于 simulator。
- iOS 官方构建目标是 `static-libs-image`。

当前 `make/autoconf/jvm-features.m4` 还明确规定：

- Zero **不可启用**：
  - `compiler1`
  - `compiler2`
  - `minimal`
  - `zgc`
- Zero 默认只过滤：
  - `jfr`
  - `link-time-opt`
  - `opt-size`

也就是说，**Zero 默认不是“小型 JVM”**。如果不主动配置，它仍会从平台可用 feature 中继承很多本项目不需要的功能。

因此本方案的产品定义是：

```text
Tiny Zero
├── Zero C++ Interpreter
├── Serial GC
├── opt-size
│
├── NO C1
├── NO C2
├── NO CDS
├── NO DTrace
├── NO Epsilon GC
├── NO G1
├── NO JFR
├── NO JNI Check
├── NO JVMTI
├── NO LTO（第一版）
├── NO Management
├── NO Parallel GC
├── NO Services
├── NO Shenandoah
├── NO VM Structs
└── NO ZGC
```

`CDS` 在未来真机阶段可以重新 A/B 测试，但**当前“只做裁剪构建”的基线直接关闭**，从而减少 build feature 和 native code，并让构建产物更单一。

---

## 3. 最终交付物

最终发布目录固定为：

```text
dist/device/
├── lib/
│   └── libtinyjvm.a
│
├── include/
│   ├── jni.h
│   ├── ...
│   └── ios/
│
├── runtime/
│   ├── release
│   └── lib/
│       └── modules
│
└── meta/
    ├── environment.txt
    ├── mobile-commit.txt
    ├── jvm-features.txt
    ├── runtime-modules.txt
    ├── native-input-libs.txt
    ├── native-keep-symbols.txt
    ├── symbol_keeper.cpp
    ├── tiny-jni-anchor.patch
    ├── libjvm-pass2.defined.nm.txt
    ├── libjvm-pass2.undefined.nm.txt
    ├── libtinyjvm.members.txt
    ├── libtinyjvm.nm.txt
    ├── modules-jimage-list.txt
    └── SHA256SUMS
```

另外生成：

```text
dist/tiny-openjdk-ios-device.tar.gz
dist/tiny-openjdk-ios-device.tar.gz.sha256
```

**这个 `dist/device` 才是 canonical deliverable。**

OpenJDK 自己的：

```text
build/<conf>/images/static-libs/
```

只是中间构建目录，不作为发布物。

---

## 4. 构建层次

整个构建拆成四层：

```text
OpenJDK Source
      │
      ▼
┌───────────────────────────────────────┐
│ 1. HotSpot Tiny Zero                 │
│ Zero + SerialGC + opt-size           │
│ disable GC/JVMTI/JFR/services/...    │
└───────────────────────────────────────┘
      │
      ├─────────────────────┐
      ▼                     ▼
┌───────────────────┐  ┌──────────────────────┐
│ 2. Java Modules   │  │ 3. Native Archives   │
│ java.base         │  │ libjvm.a             │
│ jdk.unsupported   │  │ libjava.a            │
│ jdk.crypto...     │  │ libjimage.a          │
│       │           │  │ libnet.a             │
│    jmod/jlink     │  │ libnio.a             │
│       │           │  │ libzip.a             │
│   lib/modules     │  │ libffi.a             │
└───────────────────┘  │ cryptoki native .a   │
                       └──────────────────────┘
                                │
                                ▼
                     generated symbol keeper
                                │
                                ▼
                         second HotSpot build
                                │
                                ▼
                       merged libtinyjvm.a
                                │
                ┌───────────────┴─────────────┐
                ▼                             ▼
          runtime/lib/modules            include/*.h
                │                             │
                └──────────────┬──────────────┘
                               ▼
                         dist/device
```

---

## 5. 为什么不直接修改 `StaticLibsImage.gmk` 只编三个模块

当前 OpenJDK Mobile 的 `make/StaticLibsImage.gmk` 使用：

```make
ALL_MODULES = $(call FindAllModules)
```

然后遍历所有模块收集 static library。

从**最终包大小/RSS**角度，中间目录里有多少无关 `.a` 并不重要；真正重要的是最终 iOS target 链接了什么。

第一阶段直接大改 OpenJDK module build graph 有三个问题：

1. Boot JDK、build tools、interim modules 的依赖远比最终 runtime module graph 复杂。
2. 很容易为了少编译几个模块破坏 OpenJDK 自身构建链。
3. 对最终 iOS executable/RSS 没有直接收益。

所以稳定版本采用：

> **上游构建尽量少改，最终发布层严格 allowlist。**

即：

```text
OpenJDK build tree
    可以比较大

dist/device
    必须严格只包含 Tiny Zero 所需内容
```

后续如果构建时间成为问题，再单独做“build-time trimming” patch；不要和 runtime trimming 混在第一批补丁里。

---

## 6. 稳定构建的工程目录

附带脚本采用：

```text
tiny-zero-ios-build/
├── build.sh
├── config/
│   ├── build.env.example
│   └── build.env                 # 本地创建，不提交私有路径
├── scripts/
│   ├── common.sh
│   ├── 00-check-env.sh
│   ├── 10-fetch.sh
│   ├── 20-configure.sh
│   ├── 30-build-pass1.sh
│   ├── 40-generate-symbol-keeper.sh
│   ├── 50-build-pass2.sh
│   ├── 60-build-modules.sh
│   ├── 70-package-native.sh
│   ├── 80-verify-artifacts.sh
│   └── 90-package.sh
├── patches/
│   └── README.md
├── work/                         # 自动生成
└── dist/                         # 自动生成
```

---

## 7. 输入必须固定

### 7.1 OpenJDK Mobile 必须 pin 完整 commit SHA

禁止：

```bash
MOBILE_REF=master
```

必须：

```bash
MOBILE_REF=<40位commit SHA>
```

`10-fetch.sh` 会拒绝非 40 位 SHA。

这样 upstream `master` 后续变化不会改变历史构建结果。

---

### 7.2 Boot JDK

当前 OpenJDK Mobile README 仍将 **JDK 24 for macOS** 列为 iOS 构建 prerequisite。

构建脚本不把 major version 写死，而是要求：

```bash
BOOT_JDK=/absolute/path/to/jdk
```

原因是：

- OpenJDK Mobile branch 未来可能升级 build JDK 要求。
- 真正稳定的做法应该是 pin “具体 Boot JDK 安装物”，而不是在脚本里永远写 `24`。

构建 manifest 会记录：

```text
java -version
BOOT_JDK path
```

---

### 7.3 iOS SDK / Xcode

默认：

```bash
xcrun --sdk iphoneos --show-sdk-path
```

得到 SDK。

构建 manifest 会记录：

```text
Xcode version
iPhoneOS SDK version
clang version
SDK path
```

如果需要完全复现历史构建，应当在 CI/macOS builder 层额外 pin Xcode 版本。

---

### 7.4 libffi / CUPS

不要依赖某个 `support.zip` 的目录结构。

配置直接要求三个明确路径：

```bash
LIBFFI_INCLUDE=/...
LIBFFI_LIB_DIR=/...
CUPS_INCLUDE=/...
```

并强制：

```text
$LIBFFI_LIB_DIR/libffi.a
```

必须存在。

这样无论 support 包以后改目录结构，构建核心脚本不需要跟着变化。

---

## 8. 已确定的 configure 命令

脚本最终执行的核心配置为：

```bash
bash configure \
  --with-conf-name=ios-aarch64-zero-tiny-release \
  --with-debug-level=release \
  --disable-warnings-as-errors \
  --openjdk-target=aarch64-macos-ios \
  --with-jvm-variants=zero \
  --with-jvm-features="serialgc,opt-size,-cds,-dtrace,-epsilongc,-g1gc,-jfr,-jni-check,-jvmti,-link-time-opt,-management,-parallelgc,-services,-shenandoahgc,-vm-structs" \
  --with-native-debug-symbols=none \
  --enable-headless-only \
  --with-boot-jdk="$BOOT_JDK" \
  --with-libffi-include="$LIBFFI_INCLUDE" \
  --with-libffi-lib="$LIBFFI_LIB_DIR" \
  --with-cups-include="$CUPS_INCLUDE" \
  --with-sysroot="$IOS_SDK" \
  --with-source-date="$SOURCE_DATE_EPOCH"
```

其中 `SOURCE_DATE_EPOCH` 自动取：

```bash
git show -s --format=%ct "$MOBILE_REF"
```

以减少构建时间戳导致的不确定性。

---

## 9. configure 后必须验证 feature，而不是相信参数

脚本读取：

```text
build/<conf>/spec.gmk
```

中的：

```make
JVM_FEATURES_zero := ...
```

并强制要求存在：

```text
zero
serialgc
opt-size
```

同时强制不存在：

```text
cds
compiler1
compiler2
dtrace
epsilongc
g1gc
jfr
jni-check
jvmti
link-time-opt
management
minimal
parallelgc
services
shenandoahgc
vm-structs
zgc
```

也就是说：

> **configure 成功 != Tiny Zero 配置成功。**

只有 `spec.gmk` 满足 contract 才继续 build。

这一点对长期跟 upstream 很重要：如果未来 feature 默认值或 build logic 改变，脚本会 fail-fast，而不是静默生成一个变肥的 JVM。

---

## 10. 第一遍 OpenJDK 构建

已确认的官方目标仍然是：

```bash
make LOG=cmdlines,info \
  JOBS="$JOBS" \
  CONF=ios-aarch64-zero-tiny-release \
  static-libs-image
```

第一遍 build 的目的有两个：

1. 生成 Tiny Zero `libjvm.a` 和 Java Base static archives。
2. 生成 `jdk.crypto.cryptoki` 的真实 native static archive，以便后续根据实际符号自动制作 keeper。

第一遍 source tree 中会预先放一个：

```cpp
extern "C" void loadfunctions() {
}
```

的 `symbol_keeper.cpp` stub。

这样这个源文件从 configure/build 一开始就存在，第二遍只需要替换内容，Make 能稳定感知它发生变化。

---

## 11. 为什么 symbol keeper 必须自动生成，而且必须自带链接锚点

OpenJDK Mobile 的 iOS 工具链已经在使用：

```text
src/hotspot/os/bsd/symbol_keeper.cpp
```

来解决 static-link 环境下 native entry symbol 可能被 linker 丢弃的问题。当前 `ios-tools` 的 keeper 通过大量 `Java_*` / `JIMAGE_*` / `JDK_*` 引用形成静态 relocation。当前公开实现还保留了 `loadfunctions()` 这个函数名。

但仅仅“把 `symbol_keeper.cpp` 编进 `libjvm.a`”还不够。

静态 archive 的链接规则是：

```text
libjvm.a
  ├── jni.o                    <- App 需要 JNI_CreateJavaVM，所以会被拉入
  └── symbol_keeper.o          <- 如果没有任何已拉入 object 引用它，可能完全不被拉入
```

如果 `symbol_keeper.o` 自己没有来自最终根符号的可达引用，那么即使它内部引用了一千个 JNI symbols，它也可能整个留在 archive 里而不进入最终 Mach-O。

因此 Tiny Zero 增加一个非常小、但非常重要的源码修改：

```text
JNI_CreateJavaVM
      │
      ▼
tiny_symbol_keeper_anchor()
      │
      ▼
tiny_kept_symbols[]
      │
      ├── Java_...
      ├── JIMAGE_...
      └── PKCS11 Java_...
```

具体要求：

1. `src/hotspot/share/prims/jni.cpp` 在 `JNI_CreateJavaVM(...)` 入口调用一次：

```cpp
tiny_symbol_keeper_anchor();
```

2. `symbol_keeper.cpp` 定义 `tiny_symbol_keeper_anchor()`。
3. keeper 内使用**函数地址 relocation table**，而不是运行时逐个调用 native 函数。
4. 保留 `loadfunctions()` 作为与当前 ios-tools 的兼容入口，但最终 App **不需要调用它**。

这样最终应用正常直接引用：

```text
JNI_CreateJavaVM
```

就足以把 keeper 和所需 native JNI entry 拉进链接图。

因此后续 App 不需要为了 JNI native lookup 使用：

```text
-all_load
-force_load libtinyjvm.a
```

这对 Tiny 构建非常重要。

---

## 12. `jni.cpp` 锚点 patch 如何稳定维护

本方案不维护一份容易错位的大型长期 diff，而是在 checkout 完指定 commit 后由 `10-fetch.sh` 做一个**精确、失败即停**的 source transform：

- 在 `#include "jni.h"` 后声明：

```cpp
extern "C" void tiny_symbol_keeper_anchor();
```

- 在当前精确签名：

```cpp
_JNI_IMPORT_OR_EXPORT_ jint JNICALL JNI_CreateJavaVM(
    JavaVM **vm, void **penv, void *args) {
```

入口插入：

```cpp
tiny_symbol_keeper_anchor();
```

脚本要求两个匹配点都**恰好出现一次**。如果 upstream 改了 `jni.cpp` 的代码形态：

```text
FAIL
```

而不是猜测新的插入位置。

生成的实际 diff 保存到：

```text
work/generated/tiny-jni-anchor.patch
dist/device/meta/tiny-jni-anchor.patch
```

所以每次构建都能审计到底改了 upstream 什么。

---

## 13. 两遍 build 生成精确 keeper

### Pass 1

第一遍 source tree 先放一个同时定义：

```cpp
tiny_symbol_keeper_anchor()
loadfunctions()
```

的空 stub，因此 `jni.cpp` 的 anchor reference 从第一遍开始就能正常链接。

然后构建 native archives。

### 自动扫描

脚本对以下实际产物执行 Apple `nm`：

```text
libjava.a
libjimage.a
libnet.a
libnio.a
libzip.a
jdk.crypto.cryptoki 产生的所有 .a
```

筛选 **defined global symbols**：

```text
Java_*
JNI_OnLoad*
JNI_OnUnload*
JIMAGE_*
JDK_*
```

形成：

```text
work/generated/native-keep-symbols.txt
```

### 自动生成 relocation table

生成的 `symbol_keeper.cpp` 结构等价于：

```cpp
extern "C" {
void Java_xxx(void);
void Java_yyy(void);
// ...
}

using TinyNativeSymbol = void(void);

static TinyNativeSymbol* const tiny_kept_symbols[] = {
    &Java_xxx,
    &Java_yyy,
    // ...
};

extern "C" void tiny_symbol_keeper_anchor() {
    __asm__ __volatile__("" : : "r"(tiny_kept_symbols) : "memory");
}

extern "C" void loadfunctions() {
    tiny_symbol_keeper_anchor();
}
```

这里故意给函数写统一的占位声明签名，因为**永远不通过这些声明调用函数，只取地址形成 relocation**。实际 JNI 函数 ABI/signature 仍由它们自己的编译单元决定。

这种形式比逐个运行时访问/打印 native symbol 更适合生产 Tiny runtime：

- anchor 执行成本接近零；
- relocation table 仍会把所有目标放进链接图；
- linker 可以明确看到 `JNI_CreateJavaVM -> anchor -> table -> native functions` 的可达关系。

### Pass 2

再次：

```bash
make LOG=cmdlines,info \
  JOBS="$JOBS" \
  CONF=ios-aarch64-zero-tiny-release \
  static-libs-image
```

脚本执行三层检查：

1. Pass 1 与 Pass 2 的 `libjvm.a` SHA-256 必须不同；否则说明 keeper 没重新编译。
2. `nm -gU libjvm.a` 必须看到 **defined** `tiny_symbol_keeper_anchor`。
3. `nm -u libjvm.a` 必须仍能看到某个 archive member 对 `tiny_symbol_keeper_anchor` 的 **undefined edge**，证明 `JNI_CreateJavaVM` 所在 object 确实依赖 keeper object。

只有三项都满足才进入打包阶段。

---

## 14. Java runtime：只保留三个 module

当前两个附加 module 的 `module-info.java` 很简单：

### `jdk.unsupported`

没有额外 `requires`。

### `jdk.crypto.cryptoki`

当前模块描述中主要是：

```java
provides java.security.Provider
    with sun.security.pkcs11.SunPKCS11;
```

也没有新增显式模块依赖。

所以 runtime root module 固定为：

```text
java.base
jdk.unsupported
jdk.crypto.cryptoki
```

---

## 15. jmod / jlink 在这里怎么使用

这里不是让 iPhone 执行 macOS `jlink`。

而是：

```text
Mac build host
    │
    ├── host jmod
    └── host jlink
            │
            ▼
   读取 iOS target module classes
            │
            ▼
      target lib/modules
```

这正是当前 `openjdk-mobile/ios-tools` 对 iOS device `java.base` 采用的模式。

我们的脚本只是把官方的：

```bash
--add-modules java.base
```

扩展为三个 module。

---

## 16. 已确定的三模块 jimage 命令

首先创建 iOS target jmod：

```bash
"$BOOT_JDK/bin/jmod" create \
  --class-path "$BUILD_DIR/jdk/modules/java.base" \
  --target-platform ios-aarch64 \
  jmods-device/java.base.jmod

"$BOOT_JDK/bin/jmod" create \
  --class-path "$BUILD_DIR/jdk/modules/jdk.unsupported" \
  --target-platform ios-aarch64 \
  jmods-device/jdk.unsupported.jmod

"$BOOT_JDK/bin/jmod" create \
  --class-path "$BUILD_DIR/jdk/modules/jdk.crypto.cryptoki" \
  --target-platform ios-aarch64 \
  jmods-device/jdk.crypto.cryptoki.jmod
```

再：

```bash
"$BOOT_JDK/bin/jlink" \
  --module-path jmods-device \
  --add-modules java.base,jdk.unsupported,jdk.crypto.cryptoki \
  --strip-debug \
  --no-header-files \
  --no-man-pages \
  --output java-bundle-device
```

最终发布：

```text
java-bundle-device/lib/modules
java-bundle-device/release
```

而不是把 macOS Boot JDK 搬进 iOS。

---

## 17. Native allowlist

当前 ios-tools 的 device static library 已明确使用：

```text
libjvm.a
libffi.a
libjava.a
libzip.a
libnet.a
libnio.a
libjimage.a
```

本项目在此基础上再增加：

```text
jdk.crypto.cryptoki 产生的 native .a
```

`jdk.unsupported` 当前没有额外 native archive。

因此基础 native allowlist 为：

```text
libjvm.a
libffi.a
libjava.a
libjimage.a
libnet.a
libnio.a
libzip.a
<jdk.crypto.cryptoki native archive(s)>
```

---

## 18. 为什么不硬编码 `libj2pkcs11.a` 路径

普通动态 JDK 中 PKCS#11 native library 通常叫：

```text
libj2pkcs11
```

但稳定构建脚本不应该依赖“我猜这个 revision 的 static archive 一定在某个固定目录”。

因此要求是：

1. 优先扫描：

```text
build/<conf>/support/native/jdk.crypto.cryptoki/
```

2. 找出这个 module 实际生成的全部：

```text
*.a
```

3. 全部加入最终 native package。
4. 如果没有任何 `.a`：

```text
FAIL
```

这样 upstream 改 native archive 输出路径时，不会静默缺 PKCS#11。

---

## 19. 合并成单一静态库

最终：

```bash
libtool -static \
  -o libtinyjvm.a \
  libjvm.a \
  libffi.a \
  libjava.a \
  libjimage.a \
  libnet.a \
  libnio.a \
  libzip.a \
  <cryptoki archives...>
```

注意：

> `libtool -static` 只是把 archive 合并成一个方便交付的 archive，不等于最终 App 已把其中所有 object 强制链接进去。

这是我们想要的行为。

后续真正 iOS App link 时仍应使用：

```text
-dead_strip
```

并避免全局：

```text
-all_load
```

和粗暴：

```text
-force_load libtinyjvm.a
```

但这是 iOS App integration 阶段，本阶段只准备好可以被正确 dead-strip 的静态 runtime。

---

## 20. Headless

构建显式：

```bash
--enable-headless-only
```

原因：

- 本应用没有 AWT/Swing/Java2D GUI 需求。
- 最终三个 module 根本不包含 `java.desktop`。
- headless-only 还能减少 full OpenJDK 中间构建过程中部分 GUI native 内容。

如果未来 upstream 对 iOS headless-only 行为发生变化，configure 会直接失败，而不是自动退回 headful。

---

## 21. Debug symbols

稳定 release build 使用：

```bash
--with-native-debug-symbols=none
```

这主要减少：

- build artifact
- static archive/debug info
- 最终分发体积

当前阶段目标是做 release Tiny runtime，因此直接关闭。

未来如需调试，应建立独立：

```text
ios-aarch64-zero-tiny-fastdebug
```

或带 external debug symbols 的 profile，不要污染 release profile。

---

## 22. 第一版不启用 LTO

虽然 Zero 默认 filter 中包括：

```text
link-time-opt
```

本方案第一版仍明确：

```text
-link-time-opt
```

原因不是认为 LTO 没价值，而是：

- 当前首先需要稳定、可维护的 cross compile。
- LTO 同时涉及 OpenJDK clang、static archive 和 Apple final linker。
- 它应该作为**独立构建 profile**加入，而不是第一版 Tiny 基线的一部分。

后续可以做：

```text
tiny-release
tiny-release-lto
```

两个 profile。

本阶段不展开。

---

## 23. 本阶段不做 java.base package-level 删除

虽然最终只有三个模块，但：

```text
java.base
```

内部仍很大。

本阶段**不直接删除**：

```text
java.time
java.text
java.math
java.util.regex
...
```

原因是实际场景需要：

```text
java.net
java.nio
java.security
javax.crypto
javax.net.ssl
sun.nio.*
sun.security.*
reflection
Unsafe
```

并且 PKCS#11/security provider 存在：

```text
ServiceLoader
provider lookup
Class.forName
resource lookup
```

等隐式加载路径。

在没有真机/完整 workload 测试的阶段，source-level 删除 `java.base` package 风险过高。

当前阶段的原则是：

> **module-level trim + VM feature trim + native allowlist，先做到确定性安全裁剪。**

---

## 24. 本阶段不修改 OpenJDK 深层 runtime 子系统

以下仍可以在后续继续 source-level 裁：

```text
NMT
PerfData
heap dump
diagnostic commands
error reporting
logging
部分 serviceability residual
更多 unused native code
```

但这些不进入第一版稳定构建。

原因：

- 有些已经会被 feature gate 或最终 linker 消掉。
- 有些没有独立 configure feature。
- 在没有运行测试阶段直接移除会提高 bootstrap/class-loading/crash handling 风险。

正确流程应是后续根据：

```text
final Mach-O link map
nm
size
Instruments
RSS/dirty pages
```

再决定。

---

## 25. 静态产物校验，不属于测试

用户当前不方便连接真机或 simulator，所以本阶段明确**没有运行测试**。

但是构建结束必须执行静态 contract verification。

### 25.1 JVM feature

检查：

```text
zero
serialgc
opt-size
```

存在。

禁止 feature 不存在。

### 25.2 Module image

检查 `runtime/release`：

```text
MODULES="java.base jdk.crypto.cryptoki jdk.unsupported"
```

只允许这三个 module。

### 25.3 Native symbols

对最终：

```text
libtinyjvm.a
```

执行：

```bash
xcrun nm -gU
```

至少要求能看到：

```text
Java_sun_nio_ch_...
Java_sun_security_pkcs11_...
JIMAGE_...
tiny_symbol_keeper_anchor
```

另外 Pass 2 的 `libjvm.a` 必须同时存在 keeper anchor 的 defined symbol 和来自 `JNI_CreateJavaVM` object 的 undefined reference edge。

### 25.4 Archive

保存：

```bash
ar -t libtinyjvm.a
```

结果进入 manifest。

### 25.5 jimage

使用 Boot JDK：

```bash
jimage list runtime/lib/modules
```

保存完整列表。

### 25.6 Checksums

整个 `dist/device` 生成：

```text
SHA256SUMS
```

最终 tarball 再生成独立 SHA-256。

这些都属于**构建产物完整性检查**，不要求运行 iOS 程序。

---

## 26. 一键构建

准备：

```bash
cp config/build.env.example config/build.env
```

填写：

```text
MOBILE_REF
BOOT_JDK
LIBFFI_INCLUDE
LIBFFI_LIB_DIR
CUPS_INCLUDE
```

然后：

```bash
./build.sh
```

流水线固定：

```text
00 check environment
10 checkout exact source commit
20 configure Tiny Zero
30 pass-1 native build
40 generate precise symbol keeper
50 pass-2 HotSpot build + anchor graph verification
60 build three-module jimage
70 package native/runtime/header
80 verify static artifacts
90 create tar.gz + checksum
```

---

## 27. 为什么要两遍 build，而不是维护手写 patch

两遍 build 会增加一些编译时间，但对当前目标更合理：

### 手写 keeper

```text
优点：
- 少一次 build

缺点：
- upstream native symbol 变化后容易漏
- PKCS#11 容易漏
- 大量人工列表
- 不容易判断哪些 symbol 已失效
```

### 自动 keeper

```text
优点：
- 从当前实际 archive 自动生成
- 天然跟随 upstream
- 只针对最终选择的 native libraries
- build 输出自带 symbols manifest
- 可 reproducible

缺点：
- 多一次 HotSpot incremental build
```

本项目当前更看重：

```text
稳定
可维护
可复现
```

所以选择自动 keeper。

---

## 28. 构建失败策略

脚本统一 fail-fast。

以下情况必须直接失败：

- `MOBILE_REF` 不是完整 SHA。
- Boot JDK 缺 `jmod/jlink/jimage`。
- iPhoneOS SDK 找不到。
- libffi 路径错误。
- configure 后实际 JVM feature 不符合 Tiny contract。
- `libjvm.a` 未产生。
- 任意三个 module 的 `jdk/modules/<module>` 未产生。
- `jdk.crypto.cryptoki` 没有 native static archive。
- 自动生成 keeper 得到 0 个 symbol。
- 第二遍 build 后 `libjvm.a` hash 未变化。
- jlink 最终 module set 出现第 4 个 module。
- final archive 缺 NIO/PKCS11/JIMAGE native symbols。
- checksum 生成失败。

不做“尽量继续”的模糊构建。

---

## 29. 构建日志与可审计信息

每次构建保存：

```text
work/logs/environment.txt
work/logs/configure.log
work/logs/jvm-features.txt
work/logs/build-pass1.log
work/logs/build-pass2.log
work/logs/mobile-commit.txt

work/generated/native-keeper-input-libs.txt
work/generated/native-keep-symbols.txt
work/generated/symbol_keeper.cpp
work/generated/symbol_keeper.patch
work/generated/tiny-jni-anchor.patch
work/generated/libjvm-pass2.defined.nm.txt
work/generated/libjvm-pass2.undefined.nm.txt
work/generated/*.jmod.describe.txt
```

最终关键内容复制到：

```text
dist/device/meta/
```

这样无需回忆“当时怎么编的”。

---

## 30. CI 建议

未来放到 CI 时，CI 只需要提供：

```text
macOS runner
固定 Xcode
固定 Boot JDK
固定 libffi/CUPS support inputs
config/build.env
```

执行：

```bash
./build.sh
```

然后发布：

```text
dist/tiny-openjdk-ios-device.tar.gz
dist/tiny-openjdk-ios-device.tar.gz.sha256
```

CI 不需要：

```text
iPhone
Simulator
Signing certificate
Provisioning profile
```

因为本阶段不生成/运行最终 App。

---

## 31. 后续 iOS App 集成要求（这里只定义要求，不测试）

本构建阶段不写最终 App，但产物是按以下 integration contract 制作的：

### 必须

链接：

```text
libtinyjvm.a
```

App bundle 携带：

```text
runtime/lib/modules
```

并使用：

```text
include/
```

中的 JNI headers。

### final linker

要求：

```text
DEAD_CODE_STRIPPING = YES
```

即最终链接器使用 dead strip。

### 禁止默认使用

```text
-all_load
-force_load libtinyjvm.a
```

因为这样会破坏 Tiny runtime 的最终 native dead stripping。

如果以后发现某个特定 static registration 仍然缺失，应当：

- 精确找出 archive/object。
- 优先扩展 `nm` 选择规则或修复自锚定 symbol keeper。
- 只有在确认无法建立正常引用边时，才针对最小范围使用 force-load。

---

## 32. 本阶段明确不包含的内容

以下全部不属于本轮：

- 真机启动。
- Simulator 启动。
- `JNI_CreateJavaVM` 实际调用测试。
- PKCS#11 provider 实际初始化。
- TCP/NIO 实际运行。
- 100 TCP connection test。
- TLS 测试。
- `-Xmx20M`/`-Xmx32M` 验证。
- `-Xss256k` 验证。
- RSS/physical footprint。
- CDS on/off A/B。
- LTO benchmark。
- App Store / entitlement。
- VPN/Network Extension 生命周期。
- iOS 后台限制。

这些等到能接真机或 simulator 后另做 Runtime Validation 文档。

---

## 33. 当前稳定版本的最终裁剪边界

### JVM

保留：

```text
Zero
Serial GC
opt-size
```

裁掉：

```text
CDS
C1
C2
DTrace
Epsilon
G1
JFR
JNI Check
JVMTI
LTO
Management
Minimal
Parallel GC
Services
Shenandoah
VM Structs
ZGC
```

### Java modules

只保留：

```text
java.base
jdk.unsupported
jdk.crypto.cryptoki
```

### Native

发布 allowlist：

```text
libjvm.a
libjava.a
libjimage.a
libnet.a
libnio.a
libzip.a
libffi.a
jdk.crypto.cryptoki native archive(s)
```

### Static native symbol preservation

不使用全量 `-all_load`。

使用：

```text
actual selected archives
    ↓
nm
    ↓
precise symbol_keeper.cpp
    ↓
JNI_CreateJavaVM self-anchor
    ↓
second HotSpot build
```

### 发布物

只有：

```text
libtinyjvm.a
include/
runtime/lib/modules
metadata/checksums
```

---

## 34. 后续维护原则

跟进 OpenJDK Mobile upstream 时，不要靠“记住哪些参数以前有效”。

只依赖以下 machine-checkable contract：

```text
1. exact commit SHA
2. configure must succeed
3. spec.gmk feature set must exactly satisfy Tiny contract
4. required static archives must exist
5. three module dirs must exist
6. symbol keeper must be regenerated from actual archives
7. JNI_CreateJavaVM must retain a static edge to the keeper anchor
8. second libjvm must contain generated keeper and anchor graph
9. jlink image must contain only three modules
10. final archive must contain required native symbol families
11. all output must have checksums
```

这让未来 rebase 成为：

```text
升级 MOBILE_REF
      ↓
./build.sh
      ↓
成功：构建 contract 没变
失败：明确知道 upstream 改了哪个边界
```

而不是重新人工检查整个 build。

---

## 35. 参考的当前 upstream 行为

本设计基于当前公开仓库中的以下事实：

- OpenJDK Mobile README 的 iOS Zero / `static-libs-image` 构建说明。
- `make/autoconf/jvm-features.m4` 的 Zero unavailable/filter 规则及 `--with-jvm-features` 语法。
- `make/StaticLibsImage.gmk` 当前通过 `FindAllModules` 遍历 static libs。
- `openjdk-mobile/ios-tools` 当前会把 `symbol_keeper.cpp` 放入 HotSpot BSD source。
- ios-tools 当前使用 macOS JDK 的 `jmod` + `jlink` 为 iOS device 构造 `lib/modules`。
- ios-tools 当前 device static archive 使用：
  `libjvm.a + libffi.a + libjava.a + libzip.a + libnet.a + libnio.a + libjimage.a`。
- 当前 `jdk.crypto.cryptoki/module-info.java` 提供 `SunPKCS11` Provider。
- 当前 `jdk.unsupported/module-info.java` 没有附加 `requires`。

上游链接：

- https://github.com/openjdk/mobile
- https://github.com/openjdk/mobile/blob/master/make/autoconf/jvm-features.m4
- https://github.com/openjdk/mobile/blob/master/make/StaticLibsImage.gmk
- https://github.com/openjdk/mobile/blob/master/src/jdk.crypto.cryptoki/share/classes/module-info.java
- https://github.com/openjdk/mobile/blob/master/src/jdk.unsupported/share/classes/module-info.java
- https://github.com/openjdk-mobile/ios-tools
- https://github.com/openjdk-mobile/ios-tools/blob/main/.github/workflows/build-openjdk.yml
- https://github.com/openjdk-mobile/ios-tools/blob/main/.github/workflows/combine-xcframework.yml
- https://github.com/openjdk-mobile/ios-tools/blob/main/.github/scripts/build-xcframework.sh
- https://github.com/openjdk-mobile/ios-tools/blob/main/openjdk-ext/src/hotspot/symbol_keeper.cpp

---

## 36. 执行结论

第一阶段不要继续追求更激进的源码删除。

先把以下链路做成**稳定的一键构建产品**：

```text
Pinned OpenJDK Mobile
        │
        ▼
Tiny Zero configure
        │
        ▼
Pass-1 static build
        │
        ▼
Generate native symbol keeper
        │
        ▼
Pass-2 libjvm
        │
        ├───────────────┐
        ▼               ▼
3-module jimage      native allowlist
        │               │
        └───────┬───────┘
                ▼
          libtinyjvm.a
          lib/modules
          JNI headers
          manifests
          checksums
                │
                ▼
        deterministic dist
```

到这里为止，已经完成：

- VM feature 裁剪。
- GC 裁剪。
- module 裁剪。
- native archive 裁剪。
- static JNI symbol 精确保留，并由 `JNI_CreateJavaVM` 自锚定。
- debug info 裁剪。
- headless 化。
- 可复现 source pinning。
- 构建 contract 校验。
- 最终发布包整理。

而且完全不需要连接 iPhone 或启动 simulator。

下一阶段再单独处理“能否启动、内存多少、哪些 runtime flag 最合适”，不要把两阶段混在一起。
