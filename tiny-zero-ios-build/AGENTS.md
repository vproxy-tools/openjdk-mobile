# AGENTS.md — tiny-zero-ios-build 维护说明

面向后续维护者的设计与契约说明。使用说明（环境、构建步骤）见 `README.md`。

## 范围与产物定义

Tiny Zero = Zero 解释器 + SerialGC + opt-size，关闭
cds/dtrace/epsilongc/g1gc/jfr/jni-check/jvmti/link-time-opt/management/
parallelgc/services/shenandoahgc/vm-structs（`scripts/20-configure.sh`
的 `JVM_FEATURES`；configure 后从 `spec.gmk` 回读断言，不信参数）。
runtime image 只含 `java.base`、`jdk.unsupported`、`jdk.crypto.cryptoki`
三个模块。native 只发布 java.base 所需 archive + cryptoki archive +
`libffi.a`。选择 Zero 而非 Minimal 的原因：iOS 不提供普通 HotSpot 依赖的
可写可执行代码区，mobile 的 iOS 官方目标就是 Zero + `static-libs-image`。

## 流水线结构（为什么是两遍 build）

symbol keeper 的内容取决于**真实静态库里有哪些符号**，而静态库本身要
完整编译一次才存在：

1. Pass 1（`30`）：带 stub keeper 全量构建 `static-libs-image
   jdk.unsupported-java`（`jdk.unsupported` 无 native 库，
   static-libs-image 不为它产出 exploded classes，必须显式追加该目标）。
2. `40`：对真实 archive 跑 `nm -gU`，筛 `Java_*`/`JNI_OnLoad*`/
   `JNI_OnUnload*`/`JIMAGE_*`/`JDK_*`，生成精确 keeper
   （`src/hotspot/os/bsd/symbol_keeper.cpp`，构建期生成物，gitignored；
   归档在 `dist/device/meta/symbol_keeper.cpp`）。
3. Pass 2（`50`）：增量重建，`libjvm.a` 的 SHA256 **必须变化**（否则说明
   keeper 没编进去，fail-fast），且 keeper 锚点符号必须已定义。

## symbol keeper 契约

- keeper 用一张 relocation table（`tiny_kept_symbols[]`）引用所有入选
  符号；`tiny_symbol_keeper_anchor()` 内联汇编引用该表。
- **树内没有任何代码引用锚点**——这是刻意设计：锚点由嵌入方在
  `JNI_CreateJavaVM` 之前调用一次（本仓库 demo 在
  `tiny-zero-ios-demo/JvmEmbed/Native/jvm_bridge.mm` 的
  `tinyvm_start()` 里），普通链接即可把 keeper 对象连同全部保留符号拉进
  最终可执行文件。最终 App 侧禁止 `-all_load`/`-force_load`，保持
  `DEAD_CODE_STRIPPING=YES`。
- 兼容符号 `loadfunctions()`（ios-tools 时代的 keeper API）继续保留。
- `JIMAGE_*` 符号用真实头 `jimage.hpp` 声明（重复声明成 void(void) 会
  构成 overload 冲突）；其余符号用通用 `void f(void);` 声明，只取地址、
  从不调用。

## 已合入源码树的 port 修复（不再有 patch 层）

以下修复直接合在本仓库 git 历史中，**不要**重新引入 patch/transform 层。
`scripts/lib/port-fixes.sh` 对**工作区**做存在性校验（marker 必须
选用**只有修复后树才存在**的字符串，勿用 MAP_JIT/RTLD_DEFAULT 这类上游
本就有的 token），工作区过旧时 fail-fast：

| 文件 | 修复 |
| --- | --- |
| `src/hotspot/os/bsd/os_bsd.cpp` | 模拟器 `anon_mmap` 恢复 `MAP_JIT`（macOS 26 要求可执行映射必须是 MAP_JIT）；标记 `TARGET_OS_SIMULATOR` |
| `src/hotspot/cpu/zero/zeroInterpreter_zero.cpp` | 未链接方法 `from_interpreted_entry()==null` 时回退解释器入口表；常量池 cache 为空时按需 `link_class`（verify→rewrite→link）；标记 `set_callee_entry_point` |
| `src/java.base/.../Throwable.java` | pre-init 窗口（`!VM.isBooted()`）`getOurStackTrace()` 返回空数组；标记 `VM.isBooted` |
| `src/hotspot/os/posix/os_posix.cpp` | 静态链接时 `get_default_process_handle()` 返回 `RTLD_DEFAULT`（否则 two-level namespace 只搜主镜像，native 解析全部落入 `ClassLoader.findNative` 兜底，引导期类初始化重入时死锁/NPE 风暴）；标记 `is_vm_statically_linked` |
| `src/hotspot/os/posix/signals_posix.cpp` | 模拟器信号处理器入口 lazy W^X：macOS 26 的 MAP_JIT 页严格写/执行二态，按 SIGBUS fault 方向翻转（dlsym 解析 `pthread_jit_write_protect_np`，SDK 标注 iOS 不可用但模拟器运行时存在）；附带 `[zero-sig]` SIGSEGV addr/pc 诊断输出；标记 `lazy_wx_flip` |
| `src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp` | darwin arm64 下 `ucontext_get_pc` 返回真实 pc（原为 `ShouldNotCallThis`，崩溃报告路径二次 fatal，hs_err 打不出 native 栈）；仅崩溃路径调用；标记 `__ss.__pc` |

构建侧的两个历史改动已提取出源码树（源码树保持 upstream 形态）：

- `jni.cpp` keeper 锚点调用 → 改由嵌入方调用（见上节契约）。
- `JvmFeatures.gmk` `OPT_SPEED_SRC` 置空（opt-size 下 -O3 提升与 -Os PCH
  的 `__OPTIMIZE_SIZE__` 状态冲突）→ 改为 configure 传
  `--disable-precompiled-headers`（`20-configure.sh`）。

## JDK 28 工具链适配（`scripts/lib/runtime-image.sh`）

- Boot JDK 必须 28：jmod/jlink/jimage 要能读 class 文件版本 72。
- **构建描述符校验**：jlink 要求目标 `java.base` 的
  `jdk/internal/misc/resources/release.txt` 与自身 runtime 一致 → jmod
  打包前从 Boot JDK 同步该文件（纯元数据）。
- **目标平台枚举校验**：jlink 用自身 `OperatingSystem` 枚举解析
  `ModuleTarget`，发行版 JDK 没有 `ios` 成员 → `--target-platform
  macos-aarch64`（同 endianness/字长，jimage 等价；设备上 `os.name` 由
  VM 决定，不受链接期元数据影响）。
- 备选方案均不可行（源码树 exploded `jdk.jlink` 禁止升级 `java.base`；
  patch `java.base` 触发 HotSpot 对 `java.lang.reflect.Field` 布局的硬
  校验拒绝启动），不要再走。

## runtime 树契约（`stage_runtime_lib`）

`dist/device/runtime/` 整体即 app 的 `<bundle>/lib`（静态链接 iOS JVM 把
`java_home` 推导为 `<可执行目录>/lib`，`-Djava.home` 会被覆盖）：

```text
lib/modules + release   # jlink 三模块镜像
conf/ + lib/tzdb.dat    # 三模块 jlink 镜像不带;取自 Boot JDK
                        # (tzdb 缺失 → java.util/java.time 时区全部 NoClassDefFoundError)
libjimage.dylib         # 0 字节 marker:System.loadLibrary("jimage")
libj2pkcs11.dylib       # 0 字节 marker:System.loadLibrary("j2pkcs11")
```

marker 原理（上游自带的静态库协议，只补最后一块）：marker 存在于系统库
路径 → `NativeLibraries.findBuiltinLib` 剥掉前后缀后在进程内查
`JNI_OnLoad_<名>`（靠 os_posix 修复的 `RTLD_DEFAULT` + App 链接
`-export_dynamic` + keeper 锚定的 `DEF_STATIC_JNI_OnLoad` 定义）→
builtin 路径跳过 dlopen。**注意**：只有 `System.loadLibrary` 失败会抛
`UnsatisfiedLinkError`，`BootLoader.loadLibrary` 失败静默返回 null、
natives 继续经进程符号解析，所以 `net`/`nio`/`zip` **不要**加 marker
（`net` archive 里根本没有 `JNI_OnLoad_net` 定义，加了会落入真 dlopen
报错）。

## 共享脚本组件（`scripts/lib/`）

demo（`../tiny-zero-ios-demo/support/`）与本流水线共用，改接口时两边都查：

- `port-fixes.sh`：`check_port_fixes <src>` 修复存在性校验。
- `static-libs.sh`：基础 archive 清单、三模块清单、cryptoki archive 发现
  （优先 `support/native/jdk.crypto.cryptoki`，回退 static-libs 下
  `*pkcs11*.a`；**不要**硬编码 `libj2pkcs11.a` 路径）。
- `runtime-image.sh`：release 描述符同步、jmod 打包、jlink、runtime 树
  装配（见上两节）。

## 源码与可复现性

管线**直接构建本仓库工作区**（`common.sh` 把 `SRC_DIR` 解析为脚本所在
仓库根）：没有 clone/fetch/checkout，也没有任何 pin。工作区里是什么就
构建什么，包括未提交改动——改完源码重跑 `./build.sh` 即可。每次构建在
`dist/device/meta/` 记录实际状态（`mobile-commit.txt` = HEAD，
`source-status-after-prepare.txt` 在 `work/logs/`）。

## 环境契约

- upstream 硬性拒绝 Xcode 16/16.1（编译器 bug）；clang 低于 13.0 只警告。
- `80` 的 SHA256SUMS 用逐文件 `shasum`（BSD sort 无 `-z`；产物路径受控
  无换行，确定性排序即可）。
- 可复现性：`--with-source-date` 取工作区 HEAD 的 commit time。
