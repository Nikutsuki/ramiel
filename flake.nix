{
  description = "Ramiel Development Environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11"; 
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      zig_0_16_0 = pkgs.stdenvNoCC.mkDerivation rec {
        pname = "zig";
        version = "0.16.0";

        src = pkgs.fetchurl {
          url = "https://ziglang.org/download/${version}/zig-x86_64-linux-${version}.tar.xz";
          hash = "sha256-cOSWZKdDdLSLUebz/fv0N/Y5XUJQkFBYi9SavlK6PQA=";
        };

        installPhase = ''
          runHook preInstall

          mkdir -p $out/bin $out/opt/zig
          cp -r . $out/opt/zig
          ln -s $out/opt/zig/zig $out/bin/zig

          runHook postInstall
        '';
      };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = with pkgs; [
          zig_0_16_0
          pkg-config
          shaderc
          vulkan-tools
          wayland-scanner
        ];

        buildInputs = with pkgs; [
          gtk3
          glib
          atk
          pango
          gdk-pixbuf
          gsettings-desktop-schemas

          alsa-lib
          libGL
          vulkan-headers
          vulkan-loader
          wayland
          wayland-protocols
          libxkbcommon
          openssl
          xorg.libX11
          xorg.libXcursor
          xorg.libXi
          xorg.libXinerama
          xorg.libXrandr
        ];

        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
          alsa-lib
          libGL
          vulkan-loader
          wayland
          libxkbcommon
          xorg.libX11
          xorg.libXcursor
          xorg.libXi
          xorg.libXinerama
          xorg.libXrandr
        ]);

        XDG_DATA_DIRS = pkgs.lib.concatStringsSep ":" [
          "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}"
          "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}"
          "${pkgs.hicolor-icon-theme}/share"
          "$XDG_DATA_DIRS"
        ];
      };
    };
}
