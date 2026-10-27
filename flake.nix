{
  description = "White Noise Linux development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/d3b13ad75cc492690728f9307e443dec9ef9a20e";

  outputs =
    { nixpkgs, ... }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      commonPackages = with pkgs; [
        rustup
        clang
        gnumake
        perl
        pkg-config
        git
        cacert
        just
        curl
        jq
        python3
        coreutils
        findutils
        gnused
        gnugrep
        gnutar
        gzip
        bzip2
        unzip
        zip
        zstd
      ];
      commonProfile = ''
        export RUSTUP_TOOLCHAIN=1.97.1
        export CARGO_TARGET_DIR="''${CARGO_TARGET_DIR:-$PWD/target/nix}"
        export CC=${pkgs.clang}/bin/clang
        export CXX=${pkgs.clang}/bin/clang++
        export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        export CARGO_HTTP_CAINFO="$SSL_CERT_FILE"
        export PATH=${pkgs.rustup}/bin:$PATH
      '';
      commonRunScript = pkgs.writeShellScript "development-shell" ''
        if [ "$#" -eq 0 ]; then
          exec ${pkgs.bashInteractive}/bin/bash --noprofile --norc -i
        fi
        exec "$@"
      '';
      # Odin's emitted linker recipe is replayed by scripts/build.sh using clang.
      llvm = pkgs.llvmPackages_21;
      libraries = with pkgs; [
        sdl3
        libarchive
        mpv-unwrapped
        ffmpeg
        poppler
        cairo
        glib
        curl
        openssl
        freetype
        libwebp
        fontconfig
        webkitgtk_4_1
        gtk3
        libsoup_3
        dbus
        wayland
        libxkbcommon
        libdecor
        libdrm
        libgbm
        libglvnd
        vulkan-loader
        alsa-lib
        libpulseaudio
        pipewire
        # Downloaded sherpa-onnx/ONNX Runtime binaries use libstdc++.so.6.
        stdenv.cc.cc.lib
      ];
      environment = pkgs.buildFHSEnv {
        name = "whitenoise-linux";
        targetPkgs =
          _:
          commonPackages
          ++ libraries
          ++ (with pkgs; [
            odin
            ols
            gdb
            llvm.lldb
            llvm.clang
            llvm.bintools
            llvm.llvm
            llvm.lld
            cmake
            ninja
            inotify-tools
            patch
            which
            procps
            file
            xdg-utils
            dbus
            zenity
            libnotify
            pulseaudio
            libcanberra-gtk3
            sound-theme-freedesktop
            gsettings-desktop-schemas
            gst_all_1.gst-plugins-base
            gst_all_1.gst-plugins-good
            gst_all_1.gst-plugins-bad
            gst_all_1.gst-libav
          ]);
        # FHS does not run stdenv setup hooks. Merge development outputs and their
        # referenced dependencies so transitive .pc files and headers are visible.
        extraOutputsToInstall = [ "dev" ];
        includeClosures = true;
        multiArch = false;
        runScript = commonRunScript;
        # Omarchy's user Compose file includes this host-owned data directory.
        extraBuildCommands = ''
          mkdir -p "$out/usr/share/omarchy"
        '';
        extraBwrapArgs = [
          "--ro-bind-try"
          "/usr/share/omarchy"
          "/usr/share/omarchy"
        ];
        profile = commonProfile + ''
          export PATH="${llvm.clang}/bin:${llvm.bintools}/bin:${llvm.llvm}/bin:$PATH"
          export CC="${llvm.clang}/bin/clang"
          export CXX="${llvm.clang}/bin/clang++"
          export AR="${llvm.bintools}/bin/ar"
          export LIBRARY_PATH="/usr/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
          export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/share/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
          export CMAKE_PREFIX_PATH="/usr''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

          # Keep the host's complete driver set on NixOS. Elsewhere use Nix Mesa,
          # not host /usr/lib drivers built against a different userspace ABI.
          # These are discovery directories, never an individual GPU/vendor/ICD.
          if [ -d /run/opengl-driver/lib ]; then
            wn_driver_root=/run/opengl-driver
          else
            wn_driver_root=${pkgs.mesa}
          fi
          export LD_LIBRARY_PATH="$wn_driver_root/lib:/usr/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          export LIBGL_DRIVERS_PATH="''${LIBGL_DRIVERS_PATH:-$wn_driver_root/lib/dri}"
          export GBM_BACKENDS_PATH="''${GBM_BACKENDS_PATH:-$wn_driver_root/lib/gbm}"
          export __EGL_VENDOR_LIBRARY_DIRS="''${__EGL_VENDOR_LIBRARY_DIRS:-$wn_driver_root/share/glvnd/egl_vendor.d}"
          export XDG_DATA_DIRS="$wn_driver_root/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
          unset wn_driver_root
        '';
      };
    in
    {
      packages.x86_64-linux.default = environment;
      devShells.x86_64-linux.default = environment.env;
      apps.x86_64-linux.default = {
        type = "app";
        program = pkgs.lib.getExe environment;
        meta.description = "Enter the White Noise Linux development environment or run a command";
      };
      formatter.x86_64-linux = pkgs.nixfmt;
    };
}
