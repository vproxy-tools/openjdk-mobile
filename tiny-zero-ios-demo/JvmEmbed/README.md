# JvmEmbed — iOS 静态嵌入 Tiny Zero JVM 的公共层

可拷贝到任意 iOS 工程复用。配套静态库由上级目录
[`tiny-zero-ios-build`](../../tiny-zero-ios-build/README.md) 产出
（`dist/device/` 下的 `lib/libtinyjvm.a`、`include/`、`runtime/`）。

## 内容

```text
JvmEmbed/
├── Native/
│   ├── jvm_bridge.h/.mm   # JNI 桥:pthread 上 CreateJavaVM、通用 main class
│   │                      # + program args/VM options、System.exit 停止、
│   │                      # stdout/stderr 行回调、libresolv DNS 收集、
│   │                      # symbol keeper 锚定调用
│   └── ios_wx_shims.mm    # Zero variant 的 W^X weak 符号(见下"链接要求")
├── Java/IosBootstrap.java # stdout/stderr 原样逐行转发(含 ANSI)到 app;
│                          # 随 app 编译进 classpath
└── Swift/
    └── BackgroundExecution.swift # iOS 26 BGContinuedProcessingTask +
                                  # iOS<26 beginBackgroundTask 回退;
                                  # identifier 自动取自 bundle id
```

## 集成步骤

1. 构建 JVM:`cd ../../tiny-zero-ios-build && ./build.sh`(产物在
   `dist/device/`)。
2. 把 `JvmEmbed/` 拷入工程,`Native/` 与 `Swift/` 加入 target sources;
   `SWIFT_OBJC_BRIDGING_HEADER` 指向 `JvmEmbed/Native/jvm_bridge.h`;
   `HEADER_SEARCH_PATHS` 加入 `dist/device/include`。
3. bundle 布局:把 `dist/device/runtime/` 整体作为文件夹引用
   (folder reference,蓝色文件夹)拷成 `<bundle>/lib`。静态链接的 iOS JVM
   推导 `java_home = <可执行目录>/lib`,因此必须满足:
   `<bundle>/lib/lib/modules`、`<bundle>/lib/release`、
   `<bundle>/lib/conf/`、`<bundle>/lib/lib/tzdb.dat`、
   `<bundle>/lib/libjimage.dylib` 与 `<bundle>/lib/libj2pkcs11.dylib`
   (0 字节 marker,见 AGENTS.md 的静态库协议说明)。
4. Java 载荷:主程序 jar + 由 `JvmEmbed/Java` 编译出的 bootstrap jar
   一起放进 bundle 资源(参考 `../support/build-java.sh`),classpath
   顺序为 `主程序.jar:bootstrap.jar`。
5. 启动(JvmModel.swift 为完整示例):

   ```swift
   // C 字符串数组:NULL 结尾;桥在 tinyvm_start 内同步拷贝,返回后即可 free
   var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup("-Deploy=xxx"), nil]
   defer { for p in cArgs { if let p { free(p) } } }
   tinyvm_write_dns_config(documentsPath, ".vproxy/resolv.conf") // 可选,DNS 需求方
   tinyvm_start("app.jar:bootstrap.jar", documentsPath,
                "com.example.Main", &cArgs, nil,
                { line in ... }, { code, reason in ... })
   ```

6. 后台运行(可选):AppDelegate 的 `didFinishLaunchingWithOptions` 里调用
   `registerContinuedProcessingLaunchHandler()`;Info.plist 列出
   `$(PRODUCT_BUNDLE_IDENTIFIER).continuedProcessing.*` 与
   `$(PRODUCT_BUNDLE_IDENTIFIER).continuedProcessing.demo`
   (identifier 规则见 `Swift/BackgroundExecution.swift` 头注释)。

## 链接要求(必须全部满足)

- `OTHER_LDFLAGS`:`-lz -framework CoreFoundation -Wl,-export_dynamic`。
  `-export_dynamic` 把静态链接的 JNI 符号放进动态符号表,VM 的
  dlsym(RTLD_DEFAULT) 查找依赖它;缺失会在引导期死锁。
- `DEAD_CODE_STRIPPING = YES`;**禁止** `-all_load` / `-force_load`
  (symbol keeper 由 `jvm_bridge.mm` 里的锚定调用拉入,无需强制加载)。
- 真机 Debug:`ENABLE_DEBUG_DYLIB[sdk=iphoneos*]=NO`(Xcode 26 的 debug
  dylib 会把 JVM 符号链出主可执行文件)。
- 模拟器:`com.apple.security.cs.allow-jit` entitlement(MAP_JIT 需要),
  且模拟器 ad-hoc 签名会丢 entitlement,每次构建后需补签:
  `codesign -f -s - --entitlements <entitlements> <app>`。
- app 自定义类的 native 方法必须显式 `RegisterNatives`(全静态构建中
  ClassLoader.findNative 找不到符号);桥内已对 `IosBootstrap.nativeLog`
  示范。

## 对源码树的要求

仓库工作区必须包含已合入的 Tiny Zero port 修复(脚本会自动校验并
fail-fast);VM 必选参数与原因见 `jvm_bridge.mm` 的选项注释。
