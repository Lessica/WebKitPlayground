# WebKit Playground

Build an open-source version of WebKit and replace it system-wide on iOS jailbroken devices.

## Requirements

- WebKit source code: [releases/Apple/Safari-16.4-iOS-16.4.1](https://github.com/WebKit/WebKit/releases/tag/releases/Apple/Safari-16.4-iOS-16.4.1)
- Xcode 14.3.1 + iOS 16.5 SDK
- Test device: iOS 16.4.1 (Dopamine)

## How to use

1. We need to [patch dyld](https://github.com/Lessica/Dopamine/blob/rh2.x_modify_white/BaseBin/dyldhook/src/roothider.c) to allow `DYLD_FRAMEWORK_PATH` to work on top of DSC
2. Check out source code of WebKit and **apply patches**
3. Compile WebKit with the following command:

```
Tools/Scripts/build-webkit --ios-device --release --use-ccache WK_USE_CCACHE=YES ARCHS='arm64 arm64e' GCC_TREAT_WARNINGS_AS_ERRORS=NO OTHER_CFLAGS='$(inherited) -Wno-error -Wno-error=strict-prototypes -Wno-strict-prototypes -Wno-error=deprecated-declarations' OTHER_CPLUSPLUSFLAGS='$(inherited) -Wno-error -Wno-error=deprecated-declarations'
```

4. Push compiled frameworks to `/Library/Frameworks` or `$JBROOT/Library/Frameworks` (RootHide).

## Build parallelism (Xcode defaults)

If you want to increase compile/build parallelism globally in Xcode, run:

```bash
defaults write com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks 48
defaults write com.apple.Xcode PBXNumberOfParallelBuildSubtasks 48
```

What they do:

- `IDEBuildOperationMaxNumberOfConcurrentCompileTasks`: controls the max number of concurrent compile tasks.
- `PBXNumberOfParallelBuildSubtasks`: controls the number of parallel PBX build subtasks in the build graph.

Notes:

- These are global user defaults and affect Xcode-driven builds on this machine.
- Restart Xcode after changing these values.
- To restore defaults:

```bash
defaults delete com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks
defaults delete com.apple.Xcode PBXNumberOfParallelBuildSubtasks
```
