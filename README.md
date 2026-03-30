# WebKit Playground

Build an open-source version of WebKit and replace it system-wide on iOS jailbroken devices.

## Requirements

- WebKit source code: [releases/Apple/Safari-16.4-iOS-16.4.1](https://github.com/WebKit/WebKit/releases/tag/releases/Apple/Safari-16.4-iOS-16.4.1)
- Xcode 14.3.1 + iOS 16.5 SDK
- Test device: iOS 16.4.1 (Dopamine)

## How to use

1. We need to patch dyld to allow `DYLD_FRAMEWORK_PATH` to work on top of DSC: https://github.com/Lessica/Dopamine/commit/34f45eedfa920479f5ccde78c7c572f61214e354
2. Check out source code of WebKit and **apply patches**
3. Compile WebKit with the following command:

```
Tools/Scripts/build-webkit --ios-device --release --use-ccache WK_USE_CCACHE=YES ARCHS='arm64 arm64e' GCC_TREAT_WARNINGS_AS_ERRORS=NO OTHER_CFLAGS='$(inherited) -Wno-error -Wno-error=strict-prototypes -Wno-strict-prototypes -Wno-error=deprecated-declarations' OTHER_CPLUSPLUSFLAGS='$(inherited) -Wno-error -Wno-error=deprecated-declarations'
```

4. Push compiled frameworks to `/Library/Frameworks` or `$JBROOT/Library/Frameworks` (RootHide).

## Caveats

- JSC is not replaced. The open-source JIT implementation appears to be incompatible with physical iOS devices (not sure).
- DOMJIT is turned off for the same reason.
- I managed to fill in some of the missing symbols, but they don't work as expected, so some features may not function properly.
