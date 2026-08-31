# Tiny Zero iOS 构建手册

把 [openjdk/mobile](https://github.com/openjdk/mobile) 的 iOS 真机 Zero JVM 构建成
Tiny Zero 裁剪版：静态 `libtinyjvm.a` + JNI 头文件 + 三模块（`java.base`、
`jdk.unsupported`、`jdk.crypto.cryptoki`）runtime 树，全程不需要真机或模拟器。

设计决策、契约与排障要点（面向后续维护）见本目录 `AGENTS.md`；
本文件只讲**怎么准备环境、怎么构建、产物是什么**。

## 1. 外部依赖

| 依赖 | 从哪里下载 | 说明 |
| --- | --- | --- |
| OpenJDK mobile 源码 | 本仓库自身 | 管线直接构建本仓库工作区（含未提交改动），不 clone、不 checkout、不 pin commit |
| Boot JDK（**必须 JDK 28**） | `https://jdk.java.net/28/`（EA） | 源码树是 JDK 28-dev（class 文件版本 72），流水线后段用 Boot JDK 的 jmod/jlink/jimage 直接读取模块内容，更低版本的工具会报 `Unsupported major.minor version 72.0` |
| libffi + CUPS 支持包 | `https://download2.gluonhq.com/mobile/mobile-support-20250106.zip` | openjdk/mobile README 指定的 iOS 构建支持包 |
| autoconf | `brew install autoconf` | macOS 自带版本过旧 |

支持包解压后需要的三个路径（对应 `config/build.env`）：

```text
<support>/libffi/include        # 含 ffi.h
<support>/libffi/libs           # 含 libffi.a
<support>/cups-2.3.6            # 含 cups/cups.h
```

## 2. 构建前置

| 项目 | 要求 |
| --- | --- |
| 操作系统 | macOS，Apple Silicon（构建机 aarch64，目标 `aarch64-macos-ios`） |
| Xcode | 完整版 Xcode（非仅 Command Line Tools）。upstream 硬性拒绝 Xcode 16 / 16.1；低于 upstream 声明的 clang 13.0 只警告不阻断 |
| iOS SDK | 默认 `xcrun --sdk iphoneos --show-sdk-path`，可用 `IOS_SDK` 覆盖 |
| 磁盘 | ≥ 10 GB 可用 |
| 内存/并行 | 8 GB 机器建议 `JOBS=4`；16 GB 可用 8 |

## 3. 构建

```bash
# 创建本机配置（gitignored），四个必填项见上节；可选 IOS_SDK/JOBS/CONF_NAME
cat > config/build.env <<'EOF'
BOOT_JDK="/path/to/jdk-28.jdk/Contents/Home"
LIBFFI_INCLUDE="/path/to/mobile-support/libffi/include"
LIBFFI_LIB_DIR="/path/to/mobile-support/libffi/libs"
CUPS_INCLUDE="/path/to/mobile-support/cups-2.3.6"
EOF
./build.sh                                     # 一键，fail-fast
```

流水线固定 10 步，任何一步失败即停止；每步也可单独重跑（续跑）：

```text
00 环境与输入检查          50 Pass-2 HotSpot 增量重建 + keeper 校验
10 源码检查 + stub keeper  60 三个 jmod + jlink runtime image
20 configure + feature 契约校验 70 打包 libtinyjvm.a / include / runtime / meta
30 Pass-1 静态库构建        80 静态产物契约校验 + SHA256SUMS
40 扫描实际符号生成 keeper   90 dist tar.gz 与校验和
```

清理构建产物：`./clean.sh`（删除 `work/`、`dist/` 与本仓库 `build/` 下
本管线的构建配置；源码即本仓库工作区，不涉及 checkout）。

## 4. 产物与校验

```text
dist/device/                     # canonical deliverable
├── lib/libtinyjvm.a             # libjvm + libffi + libjava/jimage/net/nio/zip + j2pkcs11
├── include/                     # jni.h、jni_md.h、classfile_constants.h、ios/
├── runtime/                     # 即 app 的 <bundle>/lib(java_home):
│   ├── lib/modules + lib/tzdb.dat
│   ├── release
│   ├── conf/                    # java.security 等(来自 Boot JDK)
│   └── libjimage.dylib / libj2pkcs11.dylib   # 0 字节 builtin-lib marker
└── meta/                        # 环境记录、keeper 源码与符号表、SHA256SUMS

dist/tiny-openjdk-ios-device.tar.gz(.sha256)
```

验证：

```bash
cd dist/device && shasum -a 256 -c meta/SHA256SUMS
cd .. && shasum -a 256 -c tiny-openjdk-ios-device.tar.gz.sha256
```

## 5. 限制

- 只做**构建与静态契约校验**：不含真机/模拟器启动、`JNI_CreateJavaVM`、
  PKCS#11、TCP/NIO/TLS、内存上限等任何运行时测试。
- 产物面向 **iOS 真机 arm64**；模拟器目标由
  `../tiny-zero-ios-demo/support/build-sim-jvm.sh` 在同一工作区里另开
  configure conf 构建。
- LTO、CDS、debug symbols 均关闭；headless-only。
- 管线构建的是**工作区当前状态**：改动 JDK 源码后重跑 `./build.sh` 即可，
  无需同步任何 pin；port 修复缺失或契约不满足时在明确检查点失败
  （见 `AGENTS.md`）。
