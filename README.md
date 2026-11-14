# zenoh-c linkstatic reproduction (BCR PR #11768)

A before/after comparison for https://github.com/bazelbuild/bazel-central-registry/pull/11768.
Tested at PR head `c49a79039afeae19bf97166cc8c6d2f2a2865c12`. `after/.bazelrc` points at the
branch name, so its content changes whenever the branch moves.

| dir       | zenoh-c        | registry                                                         |
|-----------|----------------|------------------------------------------------------------------|
| `before/` | `1.10.1`       | BCR only                                                         |
| `after/`  | `1.10.1.bcr.1` | PR branch (`asymingt/fix-zenoh-dynamic-linking`), then BCR       |

The two directories differ only in the zenoh-c version and the registry. To see the difference:
`diff -r -x 'bazel-*' -x MODULE.bazel.lock before after`.
Only the 1.10.1 → 1.10.1.bcr.1 pair was tested; the 1.8.0.x `select()` approach was not.
The consumer `MODULE.bazel` is set up like zenoh-c's `overlay/tests/MODULE.bazel`. zenoh-c
registers its Rust and LLVM toolchains as `dev_dependency`, so the root module has to register
them itself.
`.bazelversion` pins Bazel to 9.3.2.

## Targets (same `BUILD.bazel` in both directories)

Every target depends on `@zenoh-c//:zenoh-c` and calls `z_config_default()`. Without a call,
nothing would be pulled from the `.a`, and the comparison would prove nothing.

| target               | kind                              | linkstatic                 |
|----------------------|-----------------------------------|----------------------------|
| `cc_bin`             | `cc_binary`                       | True (default)             |
| `cc_test_linkstatic` | `cc_test` (the case in the PR title) | True                    |
| `cc_test_default`    | `cc_test` (control)               | False (default)            |
| `go_bin`             | `go_binary` + `cgo` + `cdeps`     | the Go linker always links cdeps statically |

## Commands (run from the repo root)

```sh
diff -r -x 'bazel-*' -x MODULE.bazel.lock before after   # only the version and registry differ

./compare.sh                        # @llvm hermetic toolchain (same as the PR's test module)
./compare.sh --local-cc             # auto-detected host toolchain (/usr/bin/gcc here)
./compare.sh --dynamic_mode=off     # optional: other flags are passed to bazel as-is
```

`compare.sh` builds both directories and reports the following for each target:
- `NEEDED` entries from `readelf -d` that mention zenohc.
- How `nm` sees `z_config_default`. `T` means it is defined in the binary; `U` means it is
  resolved from the `.so`. rules_go strips `.symtab`, so only `.dynsym` is visible for some
  Go binaries; a static one then shows `(stripped, not imported)`.
- The binary size.
- The zenohc `.a` / `.so` passed on the link command line, from `bazel aquery` (CppLink / GoLink).
- The result of running the binary after copying it out of `bazel-bin`, with no rpath target or
  runfiles.

To check a single target by hand:

```sh
cd after
bazel build //:cc_bin
readelf -d bazel-bin/cc_bin | grep NEEDED
bazel aquery --include_param_files "mnemonic('CppLink', //:cc_bin)" | grep -o '[^ ]*zenohc[^ ]*\.\(a\|so\)'
```

## Results (2026-11-15, Linux x86_64, Bazel 9.3.2)

### `./compare.sh` (@llvm toolchain)

| target               | before         | after                  |
|----------------------|----------------|------------------------|
| `cc_bin`             | `libzenohc.so` | `libzenohc_static.a` ✅ |
| `cc_test_linkstatic` | `libzenohc.so` | `libzenohc_static.a` ✅ |
| `cc_test_default`    | `libzenohc.so` | `libzenohc_static.a` ⚠️ |
| `go_bin`             | `libzenohc.so` | `libzenohc_static.a` ✅ |

### `./compare.sh --local-cc` (auto-detected host toolchain = /usr/bin/gcc)

| target               | before         | after                  |
|----------------------|----------------|------------------------|
| `cc_bin`             | `libzenohc.so` | `libzenohc_static.a` ✅ |
| `cc_test_linkstatic` | `libzenohc.so` | `libzenohc_static.a` ✅ |
| `cc_test_default`    | `libzenohc.so` | `libzenohc.so` ✅       |
| `go_bin`             | `libzenohc.so` | `libzenohc_static.a` ✅ |

### `./compare.sh --local-cc --dynamic_mode=off`

| target               | before         | after                  |
|----------------------|----------------|------------------------|
| `cc_bin`             | `libzenohc.so` | `libzenohc_static.a` ✅ |
| `cc_test_linkstatic` | `libzenohc.so` | `libzenohc_static.a` ✅ |
| `cc_test_default`    | `libzenohc.so` | `libzenohc_static.a` ✅ |
| `go_bin`             | `libzenohc.so` | `libzenohc_static.a` ✅ |

`./compare.sh --dynamic_mode=off` (the @llvm toolchain with `--dynamic_mode=off`) was not run.

In `before`, every linkstatic target has `NEEDED libzenohc.so`, and outside `bazel-bin` it fails
to start with `libzenohc.so: cannot open shared object file`. In `after`, the `NEEDED` entry is
gone, `z_config_default` is defined in the binary, and both the C and Go binaries run standalone.

## Findings

1. **The bug reproduces.** In 1.10.1 with the default `--dynamic_mode`, `cc_binary`,
   `cc_test(linkstatic = True)` and `go_binary` `cdeps` all link `libzenohc.so` dynamically.
   With `--dynamic_mode=off` they still link the `.so`, because 1.10.1 has no static library.
2. **With the PR, linkstatic consumers link statically.** They get `libzenohc_static.a` on both
   toolchains.
3. **Whether a non-linkstatic `cc_test` keeps `libzenohc.so` depends on the toolchain.**
   With the host toolchain (gcc), it keeps the `.so`, as the PR description says. With the
   `@llvm` (0.8.9) toolchain, it links the `.a`. The reason:
   - The `@llvm` toolchain does not declare
     `@rules_cc//cc/toolchains/capabilities:supports_dynamic_linker`.
   - rules_cc (0.2.22 was resolved here) computes
     `prefer_static_libs = linking_mode == STATIC or not supports_dynamic_linker`
     in `cc/private/link/finalize_link_action.bzl`, which is then True.
   - So when a `cc_import` has a static library, that one is chosen.

   The test module was not run. Still, `z_build_shared` in the PR's `tests/BUILD.bazel`
   (`linkstatic = False`, `ZENOHC_DYN_LIB`) has the same setup as `cc_test_default` here on
   Linux with `@llvm` registered. It is therefore probably linked statically.
4. Run standalone with the `@llvm` toolchain, `after`'s `cc_test_default` fails because
   `libc++.so.1` cannot be found. This comes from the toolchain's C++ runtime being linked
   dynamically and is unrelated to zenoh-c.

## Notes

- `MODULE.bazel.lock` is in `.gitignore`, because the registry content changes with the branch.
- The first build of each directory takes a few minutes because zenoh is built from Rust source.
- Every run writes to the same output paths, so you see the results of the last flags used.
