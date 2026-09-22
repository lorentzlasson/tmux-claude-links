default:
    @just --list

# ── quality ─────────────────────────────────────────────────────────────────

static-qa:
    deno fmt --check
    deno lint
    deno check

static-fix:
    deno fmt
    deno lint --fix
    deno check

# ── test ────────────────────────────────────────────────────────────────────

test *args:
    deno test {{args}}
