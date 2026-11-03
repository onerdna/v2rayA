{
  description = "v2rayA: web client for its own Xray-based core";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      packages = forAllSystems (pkgs:
        let
          inherit (pkgs) lib;
          src = lib.cleanSource ./.;
          version = self.shortRev or self.dirtyShortRev or "dev";

          # go.mod requires Go >= 1.27, newer than the default Go in nixpkgs
          buildGoModule = pkgs.buildGoModule.override { go = pkgs.go_1_27; };

          # 1. GUI: yarn build writes to ../web (build.sh copies from $root/web)
          gui = pkgs.stdenv.mkDerivation {
            pname = "v2raya-gui";
            inherit version src;
            sourceRoot = "source/gui";

            # vite writes to ../web, so the parent of sourceRoot must be writable
            postUnpack = ''
              chmod u+w source
            '';

            yarnOfflineCache = pkgs.fetchYarnDeps {
              yarnLock = ./gui/yarn.lock;
              hash = "sha256-pR1weNAD8usk1+c9DlZSSLhnamQaCIGTBmcfTt8Tkfw=";
            };

            nativeBuildInputs = with pkgs; [ yarnConfigHook yarnBuildHook nodejs ];

            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -a ../web/. $out/
              runHook postInstall
            '';
          };

          # 2. core (separate Go module under core/, package ./main)
          core = buildGoModule {
            pname = "v2raya-core";
            inherit version src;
            modRoot = "core";
            subPackages = [ "main" ];
            vendorHash = "sha256-0jMl0unNB5Atau+yKO7n4bR/Y1qzOKSG16S0Cu4lDz8="; # replace after first build
            env.CGO_ENABLED = 0;
            ldflags = [ "-s" "-w" "-X main.Version=${version}" ];
            postInstall = "mv $out/bin/main $out/bin/v2raya_core";
            doCheck = false;
          };

          # 3. service (Go module under service/, embeds the web dir)
          service = buildGoModule {
            pname = "v2raya";
            inherit version src;
            modRoot = "service";
            vendorHash = "sha256-mtdhme2yzmXKywr4e7YReOpLl8dnpjjCFzjlKZxws1s="; # replace after first build
            env.CGO_ENABLED = 0;
            ldflags = [
              "-s" "-w"
              "-X github.com/v2rayA/v2rayA/conf.Version=${version}"
            ];
            preBuild = ''
              rm -rf server/router/web
              mkdir -p server/router/web
              cp -a ${gui}/. server/router/web/
              chmod -R u+w server/router/web
            '';
            # binary is named after the module's last path element
            postInstall = ''
              if [ -e $out/bin/v2rayA ]; then mv $out/bin/v2rayA $out/bin/v2raya; fi
              if [ -e $out/bin/service ]; then mv $out/bin/service $out/bin/v2raya; fi
            '';
            doCheck = false;
          };

          # v2raya looks for v2raya_core next to itself or in PATH, so copy
          # (not symlink) both binaries into one bin dir.
          v2raya = pkgs.runCommand "v2raya-${version}" { meta.mainProgram = "v2raya"; } ''
            mkdir -p $out/bin $out/share/v2raya
            cp ${service}/bin/v2raya $out/bin/
            cp ${core}/bin/v2raya_core $out/bin/
            ln -s ${pkgs.v2ray-geoip}/share/v2ray/geoip.dat $out/share/v2raya/geoip.dat
            ln -s ${pkgs.v2ray-domain-list-community}/share/v2ray/geosite.dat $out/share/v2raya/geosite.dat
          '';
        in
        {
          inherit gui core service v2raya;
          default = v2raya;
        });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ go_1_27 nodejs yarn git ];
        };
      });
    };
}
