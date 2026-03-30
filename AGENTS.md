# WebKit iOS 构建提示词（会话沉淀）

以下内容用于后续在本机继续构建/调试 WebKit 时直接复用。

## 提权要求（重点）

- 在 Codex 环境中执行 `Tools/Scripts/build-webkit`（无论 `--ios-simulator` 还是 `--ios-device`）必须使用提权运行。
- 若未提权，常见现象包括：`xcodebuild` 无法正确访问开发者服务、工作区识别异常（如 “is not a workspace file”）或构建流程中途失败。
- 结论：只要启动 WebKit 构建，第一选择就是提权执行，不要先尝试非提权构建。

## 构建日志误报处理（重点）

- 若构建日志中出现 `webkitdirs` 包相关报错：`Attempt to call undefined import method ... prohibitUnknownPort`，且构建命令会话未退出（仍在持续输出编译日志），一律视为中间噪声。
- 处理准则：不要中断当前构建、不要立刻修改脚本、不要把该条日志判定为最终失败。
- 仅以命令最终退出码和最终产物状态作为成功/失败依据。

## 可直接复制的提示词

请按以下约束执行：

1. WebKit 检出工作副本分支要和 iOS 模拟器版本相近，尽可能一致。
2. Xcode 版本（含其 iOS Simulator SDK）也要和 iOS 模拟器版本相近。
3. 默认使用发布构建（调试构建无法运行）：`--release`。
4. 默认启用 ccache：`--use-ccache WK_USE_CCACHE=YES`。
5. 默认忽略所有警告（避免 warning 当成 error 阻塞构建）。

## 默认构建指令（iOS Simulator）

```bash
Tools/Scripts/build-webkit --ios-simulator --release --use-ccache WK_USE_CCACHE=YES
```

## 真机构建关键结论（iOS Device）

- 真机构建必须使用 `--ios-device`。
- 必须显式指定 `ARCHS='arm64 arm64e'`。  
  否则构建容易混入 `x86_64`，导致 `iphoneos` 产物链路异常或不完整。
- 真机产物目录：`WebKitBuild/Release-iphoneos`（包含 `WebKit.framework`、`WebCore.framework`、`JavaScriptCore.framework` 等）。

推荐真机构建命令：

```bash
Tools/Scripts/build-webkit --ios-device --release --use-ccache \
WK_USE_CCACHE=YES \
ARCHS='arm64 arm64e' \
GCC_TREAT_WARNINGS_AS_ERRORS=NO \
OTHER_CFLAGS='$(inherited) -Wno-error -Wno-error=strict-prototypes -Wno-strict-prototypes -Wno-error=deprecated-declarations' \
OTHER_CPLUSPLUSFLAGS='$(inherited) -Wno-error -Wno-error=deprecated-declarations'
```

## 公开 SDK 对齐固件特性（两层强制开启）

当使用公开 iPhoneOS SDK 且需要尽量逼近固件内 WebKit 特性时，建议同时做两层：

1. `build-webkit` feature 参数层：`--jit --dfg-jit --ftl-jit`
2. 编译器预处理层：在 `OTHER_CFLAGS` / `OTHER_CPLUSPLUSFLAGS` 显式追加 `-D` 宏，避免仅靠 build setting 传递导致条件编译未生效。

推荐命令（iOS Device / Release）：

```bash
Tools/Scripts/build-webkit --ios-device --release --use-ccache --jit --dfg-jit --ftl-jit \
WK_USE_CCACHE=YES ARCHS='arm64 arm64e' \
GCC_TREAT_WARNINGS_AS_ERRORS=NO \
OTHER_CFLAGS='$(inherited) -Wno-error -Wno-error=strict-prototypes -Wno-strict-prototypes -Wno-error=deprecated-declarations -DENABLE_JIT_OPERATION_VALIDATION=1 -DENABLE_JIT_OPERATION_DISASSEMBLY=1' \
OTHER_CPLUSPLUSFLAGS='$(inherited) -Wno-error -Wno-error=deprecated-declarations -DENABLE_JIT_OPERATION_VALIDATION=1 -DENABLE_JIT_OPERATION_DISASSEMBLY=1'
```

## 关于 `--only-webkit`（强约束）

- `--only-webkit` 不应使用。
- 该参数具备迷惑性，容易破坏依赖顺序并触发不完整产物问题（例如统一源生成依赖未铺好）。
- 结论：任何情况都不应考虑 `--only-webkit`。

## 忽略警告相关环境变量

```bash
GCC_TREAT_WARNINGS_AS_ERRORS=NO
OTHER_CFLAGS='$(inherited) -Wno-error -Wno-error=strict-prototypes -Wno-strict-prototypes -Wno-error=deprecated-declarations'
OTHER_CPLUSPLUSFLAGS='$(inherited) -Wno-error -Wno-error=deprecated-declarations'
```

## 推荐的完整命令（含忽略警告）

```bash
Tools/Scripts/build-webkit --ios-simulator --release --use-ccache \
WK_USE_CCACHE=YES \
GCC_TREAT_WARNINGS_AS_ERRORS=NO \
OTHER_CFLAGS='$(inherited) -Wno-error -Wno-error=strict-prototypes -Wno-strict-prototypes -Wno-error=deprecated-declarations' \
OTHER_CPLUSPLUSFLAGS='$(inherited) -Wno-error -Wno-error=deprecated-declarations'
```

## 备注

- `OTHER_CFLAGS` / `OTHER_CPLUSPLUSFLAGS` 必须带 `$(inherited)`，避免覆盖原有必要编译选项。
- 若分支、Xcode SDK、Simulator 版本偏差过大，容易出现构建或链接异常。

## scripts/sim-webkit-env.sh 用法（构建后注入并启动 Safari）

脚本路径：

```bash
/Volumes/OPTANE/WebKitPlayground/scripts/sim-webkit-env.sh
```

基础命令：

```bash
scripts/sim-webkit-env.sh set   <webkit_build_dir> [device_udid_or_booted]
scripts/sim-webkit-env.sh show  [device_udid_or_booted]
scripts/sim-webkit-env.sh clear [device_udid_or_booted]
scripts/sim-webkit-env.sh bounce [device_udid_or_booted]
```

示例：

```bash
# 1) 注入 DYLD 环境变量
/Volumes/OPTANE/WebKitPlayground/scripts/sim-webkit-env.sh set \
/Volumes/OPTANE/WebKitPlayground/WebKit_iOS_16.4/WebKitBuild/Debug-iphonesimulator \
4EB1CA33-F5EC-47E0-8098-9935621B225D

# 2) 重启 backboardd 使主屏启动链路读取新环境
/Volumes/OPTANE/WebKitPlayground/scripts/sim-webkit-env.sh bounce dummy 4EB1CA33-F5EC-47E0-8098-9935621B225D

# 3) 启动 Safari
xcrun simctl launch 4EB1CA33-F5EC-47E0-8098-9935621B225D com.apple.mobilesafari

# 4) 校验当前环境变量
/Volumes/OPTANE/WebKitPlayground/scripts/sim-webkit-env.sh show dummy 4EB1CA33-F5EC-47E0-8098-9935621B225D

# 5) 清理环境变量（可选）
/Volumes/OPTANE/WebKitPlayground/scripts/sim-webkit-env.sh clear dummy 4EB1CA33-F5EC-47E0-8098-9935621B225D
```
