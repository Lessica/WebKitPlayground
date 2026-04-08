#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 ]]; then
  cat <<'EOF'
Usage:
  sim-webkit-env.sh set   <webkit_build_dir> [device_udid_or_booted]
  sim-webkit-env.sh show  [device_udid_or_booted]
  sim-webkit-env.sh clear [device_udid_or_booted]
  sim-webkit-env.sh bounce [device_udid_or_booted]

Examples:
  scripts/sim-webkit-env.sh set /Volumes/OPTANE/WebKitPlayground/WebKitPlayer-WebKit/WebKitBuild/Debug-iphonesimulator
  scripts/sim-webkit-env.sh show
  scripts/sim-webkit-env.sh bounce
EOF
  exit 1
fi

cmd="$1"
target="${3:-booted}"

set_env() {
  local value="$1"
  xcrun simctl spawn "$target" launchctl setenv DYLD_FRAMEWORK_PATH "$value"
  xcrun simctl spawn "$target" launchctl setenv DYLD_LIBRARY_PATH "$value"
  xcrun simctl spawn "$target" launchctl setenv __XPC_DYLD_FRAMEWORK_PATH "$value"
  xcrun simctl spawn "$target" launchctl setenv __XPC_DYLD_LIBRARY_PATH "$value"
}

unset_env() {
  xcrun simctl spawn "$target" launchctl unsetenv DYLD_FRAMEWORK_PATH
  xcrun simctl spawn "$target" launchctl unsetenv DYLD_LIBRARY_PATH
  xcrun simctl spawn "$target" launchctl unsetenv __XPC_DYLD_FRAMEWORK_PATH
  xcrun simctl spawn "$target" launchctl unsetenv __XPC_DYLD_LIBRARY_PATH
}

show_env() {
  echo "DYLD_FRAMEWORK_PATH=$(xcrun simctl spawn "$target" launchctl getenv DYLD_FRAMEWORK_PATH || true)"
  echo "DYLD_LIBRARY_PATH=$(xcrun simctl spawn "$target" launchctl getenv DYLD_LIBRARY_PATH || true)"
  echo "__XPC_DYLD_FRAMEWORK_PATH=$(xcrun simctl spawn "$target" launchctl getenv __XPC_DYLD_FRAMEWORK_PATH || true)"
  echo "__XPC_DYLD_LIBRARY_PATH=$(xcrun simctl spawn "$target" launchctl getenv __XPC_DYLD_LIBRARY_PATH || true)"
}

bounce_backboardd() {
  xcrun simctl spawn "$target" launchctl stop com.apple.backboardd || true
}

case "$cmd" in
  set)
    if [[ $# -lt 2 ]]; then
      echo "set requires <webkit_build_dir>"
      exit 2
    fi
    build_dir="$2"
    if [[ ! -d "$build_dir" ]]; then
      echo "build dir not found: $build_dir"
      exit 2
    fi
    set_env "$build_dir"
    show_env
    ;;
  show)
    show_env
    ;;
  clear)
    unset_env
    show_env
    ;;
  bounce)
    bounce_backboardd
    ;;
  *)
    echo "unknown command: $cmd"
    exit 2
    ;;
esac
