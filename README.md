# tmux-claude-links

Open any link in a tmux pane from the keyboard. Tuned for panes running Claude
Code, whose statusline link is filtered out. Finds OSC 8 hyperlinks (shown by
their label, not their URL), bare URLs, and file paths that exist on disk.

## Install with nix

Add the flake as an input, then put the plugin in your tmux config:

```nix
programs.tmux.plugins = [ inputs.tmux-claude-links.packages.${pkgs.system}.plugin ];
```

It carries its own `deno` and `fzf`, so nothing else is needed.

## Install anywhere else

Bind `main.ts` directly, with `deno` and `fzf` on `$PATH`:

```
bind-key o run-shell -b "/path/to/main.ts '#{pane_id}'"
```

## Use it

1. `prefix o` opens a popup of every link in the pane's scrollback, newest
   first. Set `@claude-links-bind` to change the key.
2. Enter opens URLs in the browser and text in `$EDITOR`. Anything else goes to
   the desktop handler. The icon column tells you which.

## Develop

```sh
just test
just static-qa
```
