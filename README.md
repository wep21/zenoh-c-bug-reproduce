# zenoh-c linkstatic reproduction (BCR PR #11768)

https://github.com/bazelbuild/bazel-central-registry/pull/11768 の before / after 比較。
検証した PR head: `c49a79039afeae19bf97166cc8c6d2f2a2865c12`
(`after/.bazelrc` はブランチ名で参照しているので、ブランチが進むと内容も変わる)

| dir       | zenoh-c        | registry                                                       |
|-----------|----------------|----------------------------------------------------------------|
| `before/` | `1.10.1`       | BCR のみ                                                       |
| `after/`  | `1.10.1.bcr.1` | PR ブランチ (`asymingt/fix-zenoh-dynamic-linking`) → BCR の順  |

2つのディレクトリの差分は zenoh-c のバージョンと registry だけ
(`diff -r -x 'bazel-*' -x MODULE.bazel.lock before after`)。
検証したのは 1.10.1 → 1.10.1.bcr.1 の組だけで、1.8.0 系の `select()` 方式は試していない。
consumer 側の MODULE.bazel は zenoh-c の `overlay/tests/MODULE.bazel` と同じ構成
(zenoh-c は Rust / LLVM toolchain を `dev_dependency` で登録するので root で登録が必要)。
Bazel は `.bazelversion` で 9.3.2 に固定。

## ターゲット (両ディレクトリ共通の `BUILD.bazel`)

すべて `@zenoh-c//:zenoh-c` に依存し、`z_config_default()` を実際に呼ぶ
(呼ばないと `.a` から何も取り込まれず、比較の意味がなくなるため)。

| target               | 種類                           | linkstatic       |
|----------------------|--------------------------------|------------------|
| `cc_bin`             | `cc_binary`                    | True (default)   |
| `cc_test_linkstatic` | `cc_test` (PR タイトルのケース) | True             |
| `cc_test_default`    | `cc_test` (対照)               | False (default)  |
| `go_bin`             | `go_binary` + `cgo` + `cdeps`  | Go linker は常に static |

## コマンド (repo root で実行)

```sh
diff -r -x 'bazel-*' -x MODULE.bazel.lock before after   # 差分は version と registry だけ

./compare.sh                        # @llvm hermetic toolchain (PR の test module と同じ)
./compare.sh --local-cc             # 自動検出のホスト toolchain (この環境では /usr/bin/gcc)
./compare.sh --dynamic_mode=off     # 任意: 追加フラグはそのまま bazel に渡る
```

`compare.sh` は両ディレクトリで build し、各ターゲットについて次を表示する。
- `readelf -d` の `NEEDED` のうち zenohc を含むもの
- `nm` で見た `z_config_default` (`T` ならバイナリ内に定義、`U` なら .so から解決。
  rules_go が `.symtab` を strip したバイナリでは `.dynsym` しか見えないので、static だと
  `(stripped, not imported)` と表示される)
- バイナリサイズ
- `bazel aquery` (CppLink / GoLink) のリンクコマンドに渡された zenohc の `.a` / `.so`
- バイナリを bazel-bin の外にコピーして実行した結果 (rpath / runfiles なし)

1 ターゲットだけ手で見る場合:

```sh
cd after
bazel build //:cc_bin
readelf -d bazel-bin/cc_bin | grep NEEDED
bazel aquery --include_param_files "mnemonic('CppLink', //:cc_bin)" | grep -o '[^ ]*zenohc[^ ]*\.\(a\|so\)'
```

## 結果 (2026-11-15, Linux x86_64, Bazel 9.3.2)

### `./compare.sh` (@llvm toolchain)

| target               | before         | after                  |
|----------------------|----------------|------------------------|
| `cc_bin`             | `libzenohc.so` | `libzenohc_static.a` ✅ |
| `cc_test_linkstatic` | `libzenohc.so` | `libzenohc_static.a` ✅ |
| `cc_test_default`    | `libzenohc.so` | `libzenohc_static.a` ⚠️ |
| `go_bin`             | `libzenohc.so` | `libzenohc_static.a` ✅ |

### `./compare.sh --local-cc` (自動検出のホスト toolchain = /usr/bin/gcc)

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

(`./compare.sh --dynamic_mode=off`、つまり @llvm + off の組み合わせは未実行)

before の linkstatic なターゲットはすべて `NEEDED libzenohc.so` を持ち、bazel-bin の外では
`libzenohc.so: cannot open shared object file` で起動できない。after では `NEEDED` が消え、
`z_config_default` がバイナリ内に定義され、単体で実行できる (cc/go とも)。

## 気づいたこと

1. **バグは再現する。** 1.10.1 では `--dynamic_mode` がデフォルトのままだと、`cc_binary`、
   `cc_test(linkstatic = True)`、`go_binary` の `cdeps` のすべてが `libzenohc.so` を動的リンクする。
   `--dynamic_mode=off` にしても `.so` のまま (static 版が存在しないため)。
2. **PR で linkstatic な consumer は static になる。** ツールチェーンに関係なく
   `libzenohc_static.a` がリンクされる。
3. **「linkstatic でない `cc_test` は `.so` のまま」はツールチェーン次第。**
   ホスト toolchain (gcc) では PR の説明どおり `.so` のまま。`@llvm` (0.8.9) toolchain では
   `.a` になる。`@llvm` の toolchain は
   `@rules_cc//cc/toolchains/capabilities:supports_dynamic_linker` を宣言していないため、
   rules_cc (解決版 0.2.22) の
   `cc/private/link/finalize_link_action.bzl` の
   `prefer_static_libs = linking_mode == STATIC or not supports_dynamic_linker`
   が True になり、`cc_import` に static があればそちらが選ばれる。
   PR の `tests/BUILD.bazel` にある `z_build_shared` (`linkstatic = False`,
   `ZENOHC_DYN_LIB`) も、Linux で `@llvm` を登録した test module では、ここでの
   `cc_test_default` と同じ条件になる。つまり実際には static リンクされている可能性が高い
   (test module 自体は未実行)。
4. after の `cc_test_default` を `@llvm` toolchain で単体実行すると `libc++.so.1` が
   見つからずに失敗する。これは toolchain の C++ runtime が動的リンクされているためで、
   zenoh-c とは無関係。

## メモ

- `MODULE.bazel.lock` は `.gitignore` に入れている (registry の内容がブランチと共に変わるため)。
- 初回ビルドは zenoh の Rust ビルドがあるので各ディレクトリ数分かかる。
- 同じ output path に上書きされるので、表示されるのは最後に実行したフラグでの結果。
