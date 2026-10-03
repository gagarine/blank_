# blank_

**Made using AI (OpenAI Codex). Open source under the [MIT license](LICENSE).**

A quiet native Rust app for writing in Typst. Write, edit source, and preview typeset pages; documents stay ordinary local `.typ` files. This branch uses egui/eframe without a webview, JavaScript or Qt.

The Rust implementation is a prototype. It includes a structured, source-preserving editor, shared undo, macOS menus, a contents sidebar, inline `/` commands, Cmd-K, syntax-colored source editing, and PDF preview/export. Some features of the earlier application still need porting; see [current validation and boundaries](docs/acceptance.md).

## Build and run

Requires Rust 1.98 or newer. On macOS, install Xcode Command Line Tools. No Go, Node.js, Python, or separate Typst installation is needed. `rust-toolchain.toml` selects the Rust toolchain and includes rustfmt and Clippy.

If Rust is not installed, run `bash scripts/bootstrap.sh` and then `source scripts/env.sh` in Bash or Zsh to use the isolated local toolchain. With a normal Rust installation, Cargo works directly.

```sh
cargo build --release -p writer-helper  # optimized background compiler
cargo run -- --demo                     # debug app with the original tutorial
cargo run -- path/to/document.typ
cargo test --workspace --locked
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
```

Cargo puts compiled executables and generated artifacts in `target/`. The app executable is `blank_`; `writer-helper` is the separate Rust Typst compiler process. Build the optimized helper before previewing. `BLANK_HELPER` can specify an explicit helper executable.

Convenience scripts handle setup, development, checks and packaging:

```sh
bash scripts/bootstrap.sh       # install/fetch development dependencies if needed
bash scripts/dev.sh --demo       # build optimized helper, run debug app
bash scripts/build.sh            # release macOS app bundle
bash scripts/build.sh --debug    # bundle a debug app with the optimized helper
bash scripts/check.sh            # formatting, Clippy and Rust tests
```

On macOS, open `target/release/bundle/blank_.app` (`target/debug/bundle/blank_.app` with `--debug`). The bundle contains both executables. On other platforms, the build script builds executables in `target/release/` (or the app in `target/debug/` with `--debug`). macOS is the platform currently exercised. An isolated development toolchain may live in the ignored `.tools/` directory; it is not part of the source or app bundle.

Use ⌘1 / ⌘2 / ⌘3 for Write / Source / Preview and ⌘K for commands. Tutorial in the native Help menu opens an editable copy of [the original tutorial](examples/Tutorial.typ). The tutorial is preserved exactly and includes instructions for features still awaiting a Rust port.

## Project structure

| Path | Purpose |
|---|---|
| `src/` | Native desktop UI, rich editor adapter, menus, typography and preview worker |
| `crates/document/` | GUI-independent Typst source model and editing transactions |
| `crates/typst-helper/src/` | Background Typst compiler, PDF/PNG rendering and source maps |
| `crates/typst-helper/tests/` | Cargo integration test of the real compiler process, PDF/PNG output and diagnostics |
| `crates/typst-helper/examples/` | Rust commands for generating a large document fixture and benchmarking compilation |
| `examples/` | Original tutorial and sample document assets |
| `crates/library-assessment/` | Isolated alternative editor-model evaluation, excluded from the application workspace |
| `scripts/` | Small shell wrappers for toolchain setup, checks, packaging and releases |
| `docs/` | Usage, validation and GUI/editor library assessment |
| `target/` | Ignored Cargo builds and generated benchmark fixtures |

One root Cargo workspace, lockfile and toolchain configuration cover the application and compiler. Go/Wails, the web frontend, and their build/test configuration are removed from this branch; the previous implementation is preserved on `codex/legacy-go` and in Git history.

## Development checks and benchmarks

`cargo test --workspace` includes the compiler protocol integration test. Cargo builds its helper executable automatically; no Python test runner is required. `cargo test -p blank_ -p blank-document` runs just the UI/model tests for faster editor iteration.

The development utilities are Rust Cargo examples. The fixture creates a synthetic 20-chapter document under `target/fixtures/thesis/`; the benchmark measures cold/warm compilation and chapter parsing without modifying those files:

```sh
cargo run -p writer-helper --example thesis_fixture
cargo build --release -p writer-helper
cargo run -p writer-helper --example benchmark
cargo run --release -p blank-document --example measure -- 1000
cargo test --manifest-path crates/library-assessment/Cargo.toml --locked
```

Read [the guide](docs/guide.md) and [library assessment](docs/native-assessment.md). Contributions are welcome; run `bash scripts/check.sh` before submitting changes. Dependencies retain their own licenses.
