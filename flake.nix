{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        tmux-claude-links = pkgs.stdenv.mkDerivation {
          pname = "tmux-claude-links";
          version = "0.1.0";
          src = self;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          dontConfigure = true;
          dontBuild = true;
          installPhase = ''
            mkdir -p $out/share/tmux-claude-links $out/bin
            cp main.ts links.ts deno.json $out/share/tmux-claude-links/
            makeWrapper ${pkgs.lib.getExe pkgs.deno} $out/bin/tmux-claude-links \
              --add-flags "run --allow-run --allow-read --allow-env" \
              --add-flags "$out/share/tmux-claude-links/main.ts"
          '';
          meta.mainProgram = "tmux-claude-links";
        };

        plugin = pkgs.tmuxPlugins.mkTmuxPlugin {
          pluginName = "claude-links";
          version = "0.1.0";
          src = self;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postInstall = ''
            wrapProgram $target/tmux-claude-links.tmux \
              --prefix PATH : ${pkgs.lib.makeBinPath [ tmux-claude-links pkgs.fzf ]}
          '';
        };
      in
      {
        packages = {
          default = tmux-claude-links;
          inherit tmux-claude-links plugin;
        };

        devShells.default = with pkgs; mkShell {
          buildInputs = [
            just
            deno
            fzf
            tmux
          ];
        };
      }
    );
}
