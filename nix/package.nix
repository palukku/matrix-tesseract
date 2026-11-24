# Nix derivation for Tesseract, written in nixpkgs style so it can be copied to
# pkgs/by-name/te/tesseract-matrix/package.nix in nixpkgs unchanged (see
# nix/README.md). The repository's flake.nix overrides `src` and `cargoDeps`
# to build the local checkout instead of a release tag.
{
  lib,
  clangStdenv,
  fetchFromGitHub,
  fetchzip,
  rustPlatform,
  cargo,
  rustc,
  cmake,
  ninja,
  pkg-config,
  gettext,
  aws-lc,
  rust-jemalloc-sys-unprefixed,
  sysprof,
  sqlite,
  qt6,
  wrapGAppsHook4,
  glib,
  gtk4,
  gdk-pixbuf,
  cairo,
  pango,
  gst_all_1,
  libopus,
  libsecret,
  wayland,
  libx11,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxrandr,
  libxtst,
  libdrm,
  libgbm,
  ffmpeg,
  # "qt6" (default, the variant Arch/Flatpak ship) or "gtk".
  ui ? "qt6",
}:

assert lib.assertOneOf "ui" ui [
  "qt6"
  "gtk"
];

let
  useQt = ui == "qt6";

  # Prebuilt libwebrtc that webrtc-sys links statically. Its build script would
  # otherwise download it at build time; LK_CUSTOM_WEBRTC points it here. The
  # tag is WEBRTC_TAG of the webrtc-sys-build crate that Cargo.lock pins and
  # must move in lockstep with sdk/Cargo.toml's `webrtc-sys` pin (the Flatpak
  # manifest pins the same archive).
  webrtcTag = "webrtc-a545de4";
  webrtcArch =
    {
      x86_64-linux = {
        name = "x64";
        hash = "sha256-vPpThrBeJVzcnRWxAqZTWBPz3wOAzaZZJFG6bvKPN64=";
      };
      aarch64-linux = {
        name = "arm64";
        hash = "sha256-PVbV9skF5oNyIMsQss31agHF6GGDHEsRkLPpO6UR5v0=";
      };
    }
    .${clangStdenv.hostPlatform.system}
      or (throw "tesseract-matrix: no prebuilt libwebrtc for ${clangStdenv.hostPlatform.system}");
  libwebrtc = fetchzip {
    url = "https://github.com/livekit/rust-sdks/releases/download/${webrtcTag}/webrtc-linux-${webrtcArch.name}-release.zip";
    inherit (webrtcArch) hash;
  };

  # Libraries dlopen()ed at runtime: libwebrtc lazy-loads the X11/DRM ones for
  # screen capture, gst_hw_probe.cpp loads libavutil to quiet gst-libav.
  runtimeLibs = [
    libdrm
    libgbm
    libx11
    libxfixes
    libxdamage
    libxrandr
    libxcomposite
    libxext
    ffmpeg.lib
  ];
in
# webrtc-sys must compile against libwebrtc's hermetic libc++ with clang (>= 21);
# GCC silently miscompiles calls across that ABI. The whole build uses clang.
clangStdenv.mkDerivation (finalAttrs: {
  pname = "tesseract-matrix";
  version = "0.9.11";

  src = fetchFromGitHub {
    owner = "surakin";
    repo = "tesseract";
    tag = "v${finalAttrs.version}";
    hash = lib.fakeHash;
  };

  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) pname version src;
    hash = lib.fakeHash;
  };

  strictDeps = true;

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    gettext # msgfmt compiles the i18n catalogs
    rustPlatform.cargoSetupHook
    cargo
    rustc
    wrapGAppsHook4 # GStreamer plugin paths and GSettings schemas
  ]
  ++ lib.optionals useQt [ qt6.wrapQtAppsHook ];

  buildInputs = [
    # nixpkgs' cargo hook sets AWS_LC_SYS_USE_SYSTEM=1, so aws-lc-sys links this
    # instead of building its bundled copy.
    aws-lc
    # Likewise for tikv-jemalloc-sys (the process allocator, unprefixed malloc).
    rust-jemalloc-sys-unprefixed
    sqlite # and libsqlite3-sys (LIBSQLITE3_SYS_USE_PKG_CONFIG=1)
    glib
    sysprof # glib's pkg-config file requires sysprof-capture-4
    libopus
    libsecret
    wayland
    libxtst
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-libav
  ]
  ++ lib.optionals useQt [
    qt6.qtbase
    qt6.qtmultimedia
    qt6.qtwayland
  ]
  ++ lib.optionals (!useQt) [
    gtk4
    gdk-pixbuf
    cairo
    pango
  ];

  cmakeFlags = [
    (lib.cmakeFeature "TESSERACT_UI" ui)
    # Catch2 is FetchContent'd from GitHub at configure time.
    (lib.cmakeBool "TESSERACT_BUILD_TESTS" false)
    # The Nix cc-wrapper injects its own hardening flags; the project's
    # -D_FORTIFY_SOURCE=2 would clash with them under -Werror.
    (lib.cmakeBool "TESSERACT_ENABLE_HARDENING" false)
  ];

  # Corrosion needs a cxxbridge binary of exactly the `cxx` version in
  # Cargo.lock and would otherwise `cargo install` it from the network.
  # cxxbridge-cmd is in Cargo.lock, so build it from the vendored crates.
  preConfigure = ''
    # Build from a copy: inside the vendor directory cargo would pick up its
    # relative .cargo/config.toml instead of the one cargoSetupHook wrote.
    cp -r --no-preserve=mode "$NIX_BUILD_TOP/$(stripHash "$cargoDeps")"/cxxbridge-cmd-* \
      "$NIX_BUILD_TOP/cxxbridge-src"
    cargo install --offline \
      --path "$NIX_BUILD_TOP/cxxbridge-src" \
      --target-dir "$NIX_BUILD_TOP/cxxbridge-target" \
      --root "$NIX_BUILD_TOP/cxxbridge"
    export PATH="$NIX_BUILD_TOP/cxxbridge/bin:$PATH"

    # Those system libraries are reported by the -sys crates' build scripts,
    # but Corrosion does not forward build-script link libraries to the CMake
    # link of the Rust staticlib. Append them to every C++ link line so they
    # follow libtesseract_sdk_ffi.a.
    cmakeFlagsArray+=("-DCMAKE_CXX_STANDARD_LIBRARIES=-lcrypto-awslc -lsqlite3 -ljemalloc")
  '';

  env = {
    LK_CUSTOM_WEBRTC = "${libwebrtc}";
    CARGO_NET_OFFLINE = "true";
  };

  preFixup = ''
    gappsWrapperArgs+=(--prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath runtimeLibs})
  ''
  # The Qt build has both wrapper hooks; wrap once with both sets of arguments
  # instead of wrapping the binary twice.
  + lib.optionalString useQt ''
    qtWrapperArgs+=("''${gappsWrapperArgs[@]}")
  '';
  dontWrapGApps = useQt;

  meta = {
    description = "Cross-platform Matrix chat client";
    homepage = "https://github.com/surakin/tesseract";
    changelog = "https://github.com/surakin/tesseract/blob/v${finalAttrs.version}/CHANGES.md";
    license = lib.licenses.gpl3Only;
    sourceProvenance = with lib.sourceTypes; [
      fromSource
      binaryNativeCode # prebuilt libwebrtc
    ];
    mainProgram = "tesseract-matrix";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    maintainers = [ ];
  };
})
