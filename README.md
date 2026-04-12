# WebKit Playground

Build an open-source version of WebKit and replace it system-wide on iOS jailbroken devices.

- [x] Mobile Safari
- [x] 3rd-party browsers (e.g. Chrome, Firefox, Edge)
- [x] `WKWebView`
- [x] `UIWebView` (i.e. `WebKitLegacy`)

## Compatibility

<table>
    <tr>
        <th>WebKit Tag</th>
        <th>Tested on iOS</th>
        <th>Xcode Version</th>
        <th>iOS SDK Version</th>
        <th>Patch File</th>
    </tr>
    <tr>
        <td rowspan="3"><a href="https://github.com/WebKit/WebKit/releases/tag/releases/Apple/Safari-16.1-iOS-16.1">releases/Apple/Safari-16.1-iOS-16.1</a> (cherry-picks required)</td>
        <td>16.1</td>
        <td rowspan="3">14.1</td>
        <td rowspan="3">16.1</td>
        <td rowspan="5">webkit_iOS_16.3.1-worktree-20260412-004539.patch</td>
    </tr>
    <tr>
        <td>16.1.1</td>
    </tr>
    <tr>
        <td>16.1.2</td>
    </tr>
    <tr>
        <td><a href="https://github.com/WebKit/WebKit/releases/tag/releases/Apple/Safari-16.2-iOS-16.2">releases/Apple/Safari-16.2-iOS-16.2</a></td>
        <td>16.2</td>
        <td rowspan="2">14.2</td>
        <td rowspan="2">16.2</td>
    </tr>
    <tr>
        <td><a href="https://github.com/WebKit/WebKit/releases/tag/releases/Apple/Safari-16.3-iOS-16.3.1">releases/Apple/Safari-16.3-iOS-16.3.1</a></td>
        <td>16.3.1</td>
    </tr>
    <tr>
        <td><a href="https://github.com/WebKit/WebKit/releases/tag/releases/Apple/Safari-16.4-iOS-16.4.1">releases/Apple/Safari-16.4-iOS-16.4.1</a></td>
        <td>16.4.1</td>
        <td rowspan="3">14.3.1</td>
        <td rowspan="3">16.4</td>
        <td rowspan="3">webkit_iOS_16.4.1-worktree-20260411-143740.patch</td>
    </tr>
    <tr>
        <td rowspan="2"><a href="https://github.com/WebKit/WebKit/releases/tag/releases/Apple/Safari-16.5-iOS-16.5">releases/Apple/Safari-16.5-iOS-16.5</a></td>
        <td>16.5</td>
    </tr>
    <tr>
        <td>16.5.1</td>
    </tr>
</table>

## How to use

1. We need to [patch dyld](https://github.com/Lessica/Dopamine/blob/rh2.x_modify_white/BaseBin/dyldhook/src/roothider.c) to allow `DYLD_FRAMEWORK_PATH` to work on top of DSC
2. Check out source code of WebKit and **apply patches**
3. Compile WebKit with the following command:

```shell
Tools/Scripts/build-webkit --ios-device --release --use-ccache WK_USE_CCACHE=YES ARCHS='arm64 arm64e' GCC_TREAT_WARNINGS_AS_ERRORS=NO OTHER_CFLAGS='$(inherited) -Wno-error' OTHER_CPLUSPLUSFLAGS='$(inherited) -Wno-error'
```

4. Push compiled frameworks to `/Library/Frameworks` or `$JBROOT/Library/Frameworks` (RootHide).

## Troubleshooting

### iOS 16.1 required cherry-picks

When building `releases/Apple/Safari-16.1-iOS-16.1` for iOS device, apply these 4 commits first:

```bash
git cherry-pick --no-gpg-sign \
21349d858b6b \
60cfd7b1e096 \
b594a5e7e91a \
d09b8b302cad
```

### Patch Xcode SDK

If build fails with `'objc/objc-runtime.h' file not found`, run:

```bash
sudo Tools/Scripts/configure-xcode-for-embedded-development
```

### Build parallelism

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
