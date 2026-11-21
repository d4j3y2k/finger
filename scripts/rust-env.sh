# Sourced by build and test scripts from the repository root.
# The optional project-local toolchain keeps a clean Mac's other projects untouched.
if ! command -v cargo >/dev/null 2>&1 && [[ -x "$PWD/build/toolchain/cargo/bin/cargo" ]]; then
    export CARGO_HOME="$PWD/build/toolchain/cargo"
    export RUSTUP_HOME="$PWD/build/toolchain/rustup"
    export PATH="$CARGO_HOME/bin:$PATH"
elif ! command -v cargo >/dev/null 2>&1 && [[ -x "$HOME/.cargo/bin/cargo" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi
