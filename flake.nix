{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        zig = pkgs.zig_0_16;

        tmux-claude-links = pkgs.stdenv.mkDerivation {
          pname = "tmux-claude-links";
          version = "0.1.0";
          src = self;
          nativeBuildInputs = [ zig.hook pkgs.makeWrapper ];
          doCheck = true;
          postFixup = ''
            wrapProgram $out/bin/tmux-claude-links \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.fzf ]} \
              --suffix PATH : ${pkgs.lib.makeBinPath [ pkgs.xdg-utils ]}
          '';
          meta.mainProgram = "tmux-claude-links";
        };

        plugin = pkgs.tmuxPlugins.mkTmuxPlugin {
          pluginName = "claude-links";
          rtpFilePath = "tmux-claude-links.tmux";
          version = "0.1.0";
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = ./tmux-claude-links.tmux;
          };
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postInstall = ''
            wrapProgram $target/tmux-claude-links.tmux \
              --prefix PATH : ${pkgs.lib.makeBinPath [ tmux-claude-links ]}
          '';
        };
      in
      {
        packages = {
          default = tmux-claude-links;
          inherit tmux-claude-links plugin;
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.just
            zig
            pkgs.fzf
            pkgs.tmux
            pkgs.shellcheck
          ];
        };
      }
    );
}
