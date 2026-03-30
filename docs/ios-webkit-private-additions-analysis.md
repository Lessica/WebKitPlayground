# iOS 16.4.1 WebKit 私有 additions / shim 总结

## 背景

本文基于当前项目的 mixed-mode 形态总结 Apple 在 iOS 设备版 WebKit 中“藏私”的方式和点位。

- mixed-mode 指的是: 真机上替换 `WebKit` / `WebCore`，但故意保留系统 `JavaScriptCore`
- 模拟器不是这个组合: `scripts/sim-webkit-env.sh` 直接把整个构建目录挂到 `DYLD_FRAMEWORK_PATH` / `DYLD_LIBRARY_PATH`，因此更接近“整套自编 WebKit 一起加载”
- 真机推送脚本默认排除 `JavaScriptCore.framework`，因此更容易暴露 Apple 私有 additions 带来的跨二进制耦合

相关点位:

- `scripts/sim-webkit-env.sh`
- `scripts/push-webkit-device-artifacts.sh`
- `scripts/check-jsc-abi-compat.sh`
- `scripts/check-webcore-layout-compat.sh`
- `scripts/abi-shims/src/JavaScriptCoreABIShim.cpp`
- `scripts/abi-shims/src/WebKitAdditionsABIShimIOS.mm`
- `scripts/abi-shims/include/System/pthread_machdep.h`
- `WebKit_iOS_16.4.1/Source/WebCore/bindings/js/JSDOMGlobalObject.cpp`
- `WebKit_iOS_16.4.1/Source/JavaScriptCore/runtime/JSGlobalObject.h`
- `WebKit_iOS_16.4.1/Source/WebCore/bindings/scripts/CodeGeneratorJS.pm`

## 结论摘要

当前项目已经证明: “源码分支和固件版本一致” 并不等于 “公开源码二进制能与系统私有二进制完全互换”。

Apple 在 iOS WebKit 里藏私，至少体现在下面几层:

1. 通过 `USE(APPLE_INTERNAL_SDK)` / `ENABLE(IOS_TOUCH_EVENTS)` 这类条件编译把实现藏在内部 SDK 里
2. 通过系统二进制额外导出符号、额外 Objective-C/C++ 入口和 soft-link SPI，把 ABI 面做得比公开源码更宽
3. 通过对象实例布局 additions，把“字段兼容”问题藏成运行时问题，而不是源码级问题
4. 通过私有 mangling、`PtrTag`、`FAST_TLS`、arm64e/PAC 这类细节，把“符号存在”进一步变成“不代表语义兼容”
5. 通过 DOMJIT 这种 fast path，把最危险的耦合放进 JIT snippet、annotation、getter/function metadata 里

换句话说，Apple 的“私货”不只是多几个导出符号，而是把一整套 build-time、ABI、layout、runtime fast path 都做成了系统版本专用组合。

## 当前仓库已经验证到的事实

### 1. 现有 ABI gate 已经通过

在当前工作区里对 `./WebKit_iOS_16.4.1/WebKitBuild/Release-iphoneos` 运行:

```bash
zsh ./scripts/check-jsc-abi-compat.sh --build-dir ./WebKit_iOS_16.4.1/WebKitBuild/Release-iphoneos
```

结果:

- `WebKit.framework/WebKit`: `Undefined(from JavaScriptCore): 571`, `Missing in stock JSC: 0`
- `WebCore.framework/WebCore`: `Undefined(from JavaScriptCore): 1597`, `Missing in stock JSC: 0`
- `WebKitLegacy.framework/WebKitLegacy`: `Undefined(from JavaScriptCore): 165`, `Missing in stock JSC: 0`
- 总结果: `PASS`

这说明当前 build 在“导出符号表面”上已经能和 stock JSC 对上。

### 2. 现有 WebCore layout gate 也已经通过

运行:

```bash
zsh ./scripts/check-webcore-layout-compat.sh --build-dir ./WebKit_iOS_16.4.1/WebKitBuild/Release-iphoneos
```

结果:

- 检查函数: `WebCore::ContentSecurityPolicy::didCreateWindowProxy(WebCore::JSWindowProxy&) const`
- built 和 stock 观察到的 `x20` 偏移都是: `0xbd9`, `0xbda`, `0xbe0`, `0xbe8`
- 总结果: `PASS`

这说明当前 build 至少在一个代表性的 `JSGlobalObject/JSDOMGlobalObject` 相关访问路径上，没有明显布局漂移。

### 3. 即便如此，DOMJIT 仍然能在真机 mixed-mode 下炸

三份 crash log 指向的是:

- `JavaScriptCore::GetterSetterAccessCase::emitDOMJITGetter`
- `WebCore::compileDocumentBodyAttribute`
- `WebCore::compileNodeNodeTypeAttribute`
- `JSC::AssemblerBuffer::putIntegralUnchecked<int>`

而从 `samples/device-dsc-split` 逆出来的 stock 二进制可以确认:

- stock `WebCore` 明确带有 `compileDocumentBodyAttribute` / `compileNodeNodeTypeAttribute`
- stock `WebCore` 明确带有 `DOMJITAttributeForDocumentBody` / `DOMJITAttributeForNodeNodeType`
- stock `WebCore` 明确带有 `DOMJITSignatureForDocumentGetElementById` / `ElementHasAttributes` / `ElementGetAttribute` / `ElementGetAttributeNode` / `ElementGetElementsByTagName`
- stock `JavaScriptCore` 明确带有 `GetterSetterAccessCase::emitDOMJITGetter` 和其他 DOMJIT 入口

所以结论不是“固件没开 DOMJIT”，而是“固件开了 DOMJIT，但公开源码和系统私有实现之间还有更深的 DOMJIT 耦合”。

## Apple 藏私的主要方式

## 1. 用 Internal SDK 条件编译把实现藏起来

这是最直接的一层。

证据:

- `JavaScriptCore/runtime/JSGlobalObject.h` 在 `USE(APPLE_INTERNAL_SDK)` 时会引入 `WebKitAdditions/JSGlobalObjectAdditions.h`
- `scripts/abi-shims/src/WebKitAdditionsABIShimIOS.mm` 只在 `PLATFORM(IOS_FAMILY) && (!ENABLE(IOS_TOUCH_EVENTS) || !USE(APPLE_INTERNAL_SDK))` 下编进来

这说明 Apple 在公开源码树里保留了“插槽”，但真正的字段、方法、实现可能来自内部 SDK，而不是开源目录本身。

影响:

- 版本号对齐不代表二进制形态对齐
- 公开源码缺的东西，未必是“源码落后”，而可能是 Apple 故意只把扩展留在内部 SDK

## 2. 用额外符号和 ABI 面扩展系统二进制

当前项目里的 shim 已经暴露出多个系统 ABI 面扩展点:

- `WTFSignpostLogHandle`
- `WebCore::EventHandler::touchEvent(WebEvent*)`
- `WebCore::Document::getTouchRects(...)`
- `WebCore::EventHandler::handleTouchEvent(const PlatformTouchEvent&)`
- `WebCore::createAV1VTBDecoder(...)`
- `PAL::softLinkVideoToolboxVTRestrictVideoDecoders`
- `PAL::canLoad_VideoToolbox_VTRestrictVideoDecoders()`

这些都不是“网页 API 层”的东西，而是系统二进制对 framework provider 的 ABI 期待。

`scripts/analyze_config_gaps.py` 也把这类历史 gap 明确分成几类:

- `IOS_TOUCH_EVENTS path`
- `JIT_OPERATION_VALIDATION / JIT_OPERATION_DISASSEMBLY path`
- `VideoToolbox/AV1 related path`
- `WTF signpost / os_signpost path`

这说明 Apple 的“私货”并不是集中在某一个模块，而是横跨事件、媒体、JIT 调试/校验、系统 tracing。

## 3. 用对象布局 additions 把问题藏成 runtime layout mismatch

这一层最典型的是 `JSGlobalObject`。

当前项目在 `JavaScriptCore/runtime/JSGlobalObject.h` 里显式补了:

```cpp
#define JS_GLOBAL_OBJECT_ADDITIONS_1 void* m_externalSDKABICompatPadding { nullptr }
```

这个补丁本身就是证据: stock iOS JSC 的实例布局和公开源码默认布局并不完全一样，至少在 mixed-mode 里需要额外 padding 才能靠近 stock。

`scripts/check-webcore-layout-compat.sh` 进一步把这个问题做成 gate，专门比对:

- `ContentSecurityPolicy::didCreateWindowProxy(JSWindowProxy&) const`
- 同一函数里通过 `x20` 访问的字段偏移

重要的是:

- 这个 gate 通过，只能证明“已检查路径没有明显漂移”
- 它不能证明所有 DOMJIT metadata、annotation、class info、hidden field 都完全一致

也就是说，layout 问题可能已经从“粗粒度对象偏移错位”收敛成“只在某些 fast path 上才爆炸”的细粒度问题。

## 4. 用私有 mangling 和运行时 `dlsym` 绑定隐藏真实 ABI

`WebCore/bindings/js/JSDOMGlobalObject.cpp` 当前没有直接静态调用公开头里的 `JSCustomGetterFunction::create` / `JSCustomSetterFunction::create`，而是改成:

- 引入 `DOMAnnotation.h`
- 对精确 mangled name 做 `dlsym(RTLD_DEFAULT, "...")`
- 成功时再走 runtime 绑定

这说明两件事:

1. 这些工厂函数的真实 ABI 不能完全信任公开源码编译期声明
2. Apple 在系统 JSC 里实际使用的签名，至少在 mangling 层面足够敏感，值得绕开静态绑定

这是非常典型的“源码看起来有接口，但二进制兼容性要靠运行时探测”的私有扩展模式。

## 5. 用 FAST_TLS / 预留 PTK slot / `PtrTag` 把兼容性埋进 arm64e 细节

这一层不会直接反映成“缺函数”，但对 mixed-mode 非常致命。

证据:

- `scripts/abi-shims/include/System/pthread_machdep.h` 明确写了 iOS 16.4 device DSC 里 JavaScriptCore 使用连续保留 PTK slot `90..94`
- `WTF/wtf/posix/ThreadingPOSIX.cpp` 和 `bmalloc/bmalloc/PerThread.h` 都把 `pthread_key_init_np()` 和 `_pthread_setspecific_direct()` 的顺序改成先 init 再 set
- `scripts/check-jsc-abi-compat.sh` 的 hint 里专门检查 `Thread5s_keyE` 和 `PtrTagE...`，分别提示 `FAST_TLS mismatch` 和 `PtrTag discriminator mismatch`

这说明 Apple 把一部分兼容性要求放在:

- 线程局部存储槽位编号
- 直接 pthread 私有入口
- C++ 模板 mangling
- arm64e code pointer tagging / PAC

这类东西即便“符号名一样”，也可能因为 tag、slot、calling convention 或编译期开关不同而在运行时炸掉。

## 6. 用 DOMJIT 把最危险的私有耦合放进 fast path

DOMJIT 是当前项目里最关键的例子。

已经确认的事实:

- stock 16.4.1 的 `WebCore` 和 `JavaScriptCore` 都开着 DOMJIT
- stock `WebCore` 里至少有这些 DOMJIT 点位:
  - `Document.body`
  - `Node.nodeType`
  - `Node.parentNode`
  - `Node.firstChild`
  - `Node.lastChild`
  - `Node.nextSibling`
  - `Node.previousSibling`
  - `Node.ownerDocument`
  - `Document.getElementById`
  - `Element.hasAttributes`
  - `Element.getAttribute`
  - `Element.getAttributeNode`
  - `Element.getElementsByTagName`
- 当前 build 的 JSC ABI gate 和 WebCore layout gate 都过了，但 mixed-mode 真机仍在 DOMJIT getter emission 上崩溃

因此更合理的解释是:

- DOMJIT 依赖的不是单纯“是否有这个符号”
- DOMJIT 依赖的是更深层的私有 metadata、annotation、snippet generator 契约、类型过滤器、对象布局或 PAC-safe codegen 约束
- 这些契约并没有完整体现在公开源码头文件和公开构建形态里

这也是为什么当前项目把 `CodeGeneratorJS.pm` 改成默认不暴露 public-source DOMJIT metadata，只在显式设置 `WK_ENABLE_PUBLIC_DOMJIT=1` 时才重新打开。

这个补丁的本质不是“功能回退”，而是承认 DOMJIT 已经超出了“仅靠公开源码形态即可与 stock JSC 混跑”的安全边界。

## 7. 用 iOS touch pipeline 和媒体路径藏平台专用实现

`scripts/abi-shims/src/WebKitAdditionsABIShimIOS.mm` 暴露出的另一组点位是:

- `WebEventRegion`
- `EventHandler::touchEvent`
- `Document::getTouchRects`
- `EventHandler::handleTouchEvent`
- `EventDispatcher::touchEvent` / `touchEventWithoutCallback`
- `WebPage::resetPotentialTapSecurityOrigin`
- `createAV1VTBDecoder`
- `VTRestrictVideoDecoders`

这些点位共同说明:

- Apple 在 iOS 设备版 WebKit 里保留了更深的触摸链路和媒体链路
- 公开源码在没有 internal SDK 或相关 feature flag 时，不一定会生成同样的类、方法和 IPC 路径
- mixed-mode 下，为了先保 ABI，不得不把不少路径降成 no-op / false / nullptr fallback

这些 shim 的存在本身就是证据: Apple 的平台版 WebKit 不只是“多开了几个 feature flag”，而是带了额外实现和额外系统协作点。

## 8. 用 tracing / validation / disassembly 等辅助路径扩展二进制语义

`WTFSignpostLogHandle` shim 看起来不起眼，但它说明 Apple 的系统构建还带着:

- tracing
- signpost
- JIT operation validation
- disassembly label registration

这类路径未必直接改变网页行为，但它们会改变:

- 期望存在的符号
- 初始化顺序
- JIT operation table 的构造方式
- 某些代码路径是否参与校验或注册

所以它们虽然不像 DOMJIT 那样直接导致页面崩溃，但同样属于“系统版比公开源码版更宽的二进制语义面”。

## 当前项目可以得出的总体判断

对这个项目来说，Apple 在 iOS WebKit 中“藏私”的核心方式，不是单点补丁，而是以下组合:

1. 在源码里预留 hook，但真正实现放进 internal SDK
2. 在系统二进制里扩大导出面和调用面
3. 在关键对象上加入私有字段或布局 additions
4. 在 arm64e/PAC/FAST_TLS/PtrTag 层面引入额外约束
5. 在 DOMJIT、touch、media、signpost 这些高性能或平台专用路径上使用系统专属实现

这也是为什么:

- 公开源码 build 可以通过 ABI gate
- 公开源码 build 可以通过一个代表性的 layout gate
- 但 mixed-mode 真机仍然会在 DOMJIT 这种更深的 fast path 上崩

换句话说，Apple 把很多“差异”藏在了:

- build-time 看不全
- symbol diff 看不全
- 单点 layout check 也看不全

而只有在真机、arm64e、stock JSC、真实 fast path 被触发时，差异才会显形。

## 对项目的工程建议

如果继续坚持当前 mixed-mode 方案，建议把策略固定为:

1. 把 ABI gate 和 layout gate 当作必要条件，不要当作充分条件
2. 继续保留现有 shim，因为它们已经覆盖了最表层的缺口
3. 对 DOMJIT、internal touch path、媒体 private path 这类高风险 fast path 采取保守策略
4. 默认信任 stock binary 的行为，不要默认信任公开源码的“看起来一样”
5. 模拟器结果只能说明“整套 public build 自洽”，不能说明“与 stock JSC 混跑安全”

如果目标是最终逼近系统版性能和行为，而不是只求 mixed-mode 可跑，那么最终方向基本只剩两条:

1. 连同 `JavaScriptCore.framework` 一起替换，避免跨 provider 私有耦合
2. 继续逆向并补齐 Apple 私有 additions，直到 public build 在 ABI、layout、runtime fast path 三层都足够接近 stock

对当前阶段而言，默认关闭 public-source DOMJIT 是合理折中，因为它承认了一个事实: DOMJIT 已经不是“只要源码版本一致就一定能混跑”的层。
