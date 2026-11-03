{
  description = "v2rayA: web client for its own Xray-based core";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});

      mkPackages = pkgs:
        let
          inherit (pkgs) lib;
          src = lib.cleanSource ./.;
          version = self.shortRev or self.dirtyShortRev or "dev";

          # go.mod requires Go >= 1.27, newer than the default Go in nixpkgs
          buildGoModule = pkgs.buildGoModule.override { go = pkgs.go_1_27; };

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

          core = buildGoModule {
            pname = "v2raya-core";
            inherit version src;
            modRoot = "core";
            subPackages = [ "main" ];
            vendorHash = "sha256-0jMl0unNB5Atau+yKO7n4bR/Y1qzOKSG16S0Cu4lDz8=";
            env.CGO_ENABLED = 0;
            ldflags = [ "-s" "-w" "-X main.Version=${version}" ];
            postInstall = "mv $out/bin/main $out/bin/v2raya_core";
            doCheck = false;
          };

          service = buildGoModule {
            pname = "v2raya";
            inherit version src;
            modRoot = "service";
            vendorHash = "sha256-mtdhme2yzmXKywr4e7YReOpLl8dnpjjCFzjlKZxws1s=";
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
        };
    in
    {
      packages = forAllSystems mkPackages;

      overlays.default = final: prev: {
        v2raya = (mkPackages final).v2raya;
      };

      nixosModules.default = { config, lib, pkgs, ... }:
        let cfg = config.services.v2raya; in
        {
          disabledModules = [ "${modulesPath}/services/networking/v2raya.nix" ];

          options.services.v2raya = {
            enable = lib.mkEnableOption "v2rayA";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              defaultText = lib.literalExpression "v2raya.packages.<system>.default";
              description = "The v2raya package to run.";
            };
            address = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1:2017";
              description = "Web UI listen address. The upstream default is 0.0.0.0:2017.";
            };
            openFirewall = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Open the web UI port in the firewall.";
            };
          };

          config = lib.mkIf cfg.enable {
            systemd.services.v2raya = {
              description = "v2rayA";
              after = [ "network.target" "nss-lookup.target" ];
              wantedBy = [ "multi-user.target" ];
              # tools used for transparent proxy
              path = with pkgs; [ iptables nftables iproute2 bash ];
              environment.V2RAYA_V2RAY_ASSETSDIR = "${cfg.package}/share/v2raya";
              serviceConfig = {
                ExecStart = "${lib.getExe cfg.package} --config /var/lib/v2raya --address ${cfg.address}";
                StateDirectory = "v2raya"; # config + hwid.json live in /var/lib/v2raya
                Restart = "on-failure";
                LimitNOFILE = 1048576;
                LimitNPROC = 512;
              };
            };

            networking.firewall.allowedTCPPorts =
              lib.mkIf cfg.openFirewall [ (lib.toInt (lib.last (lib.splitString ":" cfg.address))) ];
          };
        };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ go_1_27 nodejs yarn git ];
        };
      });
    };
}
