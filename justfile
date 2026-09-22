default:
    @just --list

# ── build ───────────────────────────────────────────────────────────────────

build:
    zig build --release=safe

# ── quality ─────────────────────────────────────────────────────────────────

static-qa:
    zig fmt --check build.zig src
    shellcheck tmux-claude-links.tmux

static-fix:
    zig fmt build.zig src

check:
    nix flake check

# ── test ────────────────────────────────────────────────────────────────────

test *args:
    zig build test {{args}}
