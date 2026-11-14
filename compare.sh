#!/usr/bin/env bash
# Build the same consumer targets against zenoh-c 1.10.1 (before/) and
# 1.10.1.bcr.1 from bazel-central-registry PR #11768 (after/), then show how
# libzenohc ended up linked into each output.
#
# Usage:
#   ./compare.sh                        # @llvm hermetic C++ toolchain (as in zenoh-c's tests/MODULE.bazel)
#   ./compare.sh --local-cc             # auto-detected host C++ toolchain (supports_dynamic_linker)
#   ./compare.sh --dynamic_mode=off     # any other flags go to every bazel call as-is
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGETS=(cc_bin cc_test_linkstatic cc_test_default go_bin)
FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --local-cc) FLAGS+=("--extra_toolchains=@@rules_cc++cc_configure_extension+local_config_cc_toolchains//:all") ;;
    *) FLAGS+=("$arg") ;;
  esac
done
SIDES=(before after)

bz() { local side="$1"; shift; (cd "$ROOT/$side" && bazel "$@"); }

# 1. Build.
for side in "${SIDES[@]}"; do
  echo ">>> [$side] bazel build ${FLAGS[*]} ${TARGETS[*]/#///:}"
  bz "$side" build "${FLAGS[@]}" "${TARGETS[@]/#///:}"
done

# 2. Inspect each output.
output_of() { # side target -> absolute path of the linked binary
  local rel
  rel="$(bz "$1" cquery "${FLAGS[@]}" --output=files "//:$2" 2>/dev/null | head -1)"
  echo "$ROOT/$1/$rel"
}

needed_of() { # DT_NEEDED entries that mention zenohc
  readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | grep -i zenohc | paste -sd, - | grep . || echo "(none)"
}

symbol_of() { # how the binary sees z_config_default
  local t
  t="$(nm "$1" 2>/dev/null | awk '$NF == "z_config_default" { print $(NF-1); exit }')"
  # rules_go strips .symtab; fall back to .dynsym (only shows imports there).
  [[ -n "$t" ]] || t="$(nm -D "$1" 2>/dev/null | awk '$NF == "z_config_default" { print $(NF-1); exit }')"
  case "$t" in
    T | t) echo "T (defined in binary)" ;;
    U) echo "U (resolved from .so)" ;;
    "") echo "(stripped, not imported)" ;;
    *) echo "$t" ;;
  esac
}

size_of() { du -h --apparent-size "$1" | cut -f1; }

linker_input_of() { # zenohc archives/shared objects on the link command line
  bz "$1" aquery "${FLAGS[@]}" --include_param_files \
    "mnemonic('CppLink|GoLink', //:$2)" --output=text 2>/dev/null |
    grep -oE '[A-Za-z0-9_+.-]*zenohc[A-Za-z0-9_+.-]*\.(a|so)' | sed 's/.*_S//' | sort -u | paste -sd, - | grep . || echo "(none)"
}

standalone_run_of() { # copy the binary out of bazel-bin (no runfiles/rpath target) and run it
  local tmp out
  tmp="$(mktemp -d)"
  cp "$1" "$tmp/bin"
  if out="$(cd "$tmp" && env -i ./bin 2>&1)"; then
    echo "OK: ${out}"
  else
    echo "FAIL: $(echo "$out" | head -1 | sed 's/^.*: error while loading shared libraries: //')"
  fi
  rm -rf "$tmp"
}

row() { printf '  %-16s | %-38s | %s\n' "$@"; }

echo
echo "================================================================================"
echo " zenoh-c link comparison   flags: ${FLAGS[*]:-(none)}"
echo "   before = zenoh-c 1.10.1 (BCR)   after = zenoh-c 1.10.1.bcr.1 (PR #11768)"
echo "================================================================================"
for target in "${TARGETS[@]}"; do
  declare -A bin=()
  for side in "${SIDES[@]}"; do bin[$side]="$(output_of "$side" "$target")"; done
  echo
  echo "//:$target"
  row "" "before" "after"
  row "NEEDED (zenohc)" "$(needed_of "${bin[before]}")" "$(needed_of "${bin[after]}")"
  row "z_config_default" "$(symbol_of "${bin[before]}")" "$(symbol_of "${bin[after]}")"
  row "binary size" "$(size_of "${bin[before]}")" "$(size_of "${bin[after]}")"
  row "linker input" "$(linker_input_of before "$target")" "$(linker_input_of after "$target")"
  row "standalone run" "$(standalone_run_of "${bin[before]}")" "$(standalone_run_of "${bin[after]}")"
  unset bin
done
