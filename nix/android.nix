{
  pkgs,
  x86,
  nixpkgs,
  emulate ? pkgs.stdenv.hostPlatform.isAarch64,
}:
let
  inherit (pkgs) lib;
  repo = builtins.fromJSON (
    builtins.readFile (nixpkgs + "/pkgs/development/mobile/androidenv/repo.json")
  );
  # Must match ndkVersion in moonlight-android's app/build.gradle.
  ndkVersion = "29.0.14206865";
  # Moonlight doesn't set buildToolsVersion, so AGP 9.4 uses its default,
  # 36.0.0. Anything else makes AGP try to install into the read-only SDK.
  buildToolsVersion = "36.0.0";
  cmdlineVersion = "22.0";
  # Minor-versioned repo.json key; AGP expects platforms/android-37.0.
  platformVersion = "37.0";

  # Official Google archives, with hashes from the locked nixpkgs revision.
  archive =
    kind: version:
    let
      info = repo.packages.${kind}.${version};
      src = lib.findFirst (
        a:
        builtins.elem (a.os or "all") [
          "linux"
          "all"
        ]
      ) (throw "No Linux archive for ${kind} ${version}") info.archives;
    in
    pkgs.fetchurl { inherit (src) url sha1; };

  # These runtime libraries are x86-64 on both hosts. Do not patch Google's
  # x86-64 binaries against ARM64 glibc/libstdc++.
  hostLibraries = lib.makeLibraryPath [
    x86.glibc
    x86.stdenv.cc.cc.lib
    x86.zlib
    x86.libxml2
    x86.ncurses5
    x86.libcxx
    x86.openssl
  ];
  loader = "${x86.glibc}/lib/ld-linux-x86-64.so.2";
  qemu = if emulate then "${pkgs.qemu-user}/bin/qemu-x86_64" else "";
  patchHostTools = path: ''
    python3 ${./patch-host-tools.py} ${lib.escapeShellArg path} \
      ${lib.escapeShellArg loader} ${lib.escapeShellArg hostLibraries} \
      ${lib.escapeShellArg qemu} ${pkgs.runtimeShell}
  '';
  unpackOne = source: destination: ''
    mkdir unpack
    unzip -q ${source} -d unpack
    entries=(unpack/*)
    test "''${#entries[@]}" = 1
    mv "''${entries[0]}" ${destination}
    chmod -R u+w ${destination}
    rmdir unpack
  '';
  nativeBuildInputs = [
    pkgs.unzip
    pkgs.python3
    pkgs.patchelf
  ];

  buildTools =
    pkgs.runCommand "android-build-tools-${buildToolsVersion}"
      {
        inherit nativeBuildInputs;
      }
      ''
        ${unpackOne (archive "build-tools" buildToolsVersion) "$out"}
        ${patchHostTools "$out"}
        patchShebangs "$out"
      '';

  ndk =
    pkgs.runCommand "android-ndk-${ndkVersion}"
      {
        inherit nativeBuildInputs;
      }
      ''
        ${unpackOne (archive "ndk" ndkVersion) "$out"}
        # Never patch Android target libraries in sysroot or lib/clang.
        ${patchHostTools "$out/toolchains/llvm/prebuilt/linux-x86_64"}
        if [ -d "$out/prebuilt/linux-x86_64" ]; then
          ${patchHostTools "$out/prebuilt/linux-x86_64"}
        fi
        patchShebangs "$out/ndk-build" "$out/build" \
          "$out/toolchains/llvm/prebuilt/linux-x86_64/bin"
        # Some tools derive this directory from uname (linux-aarch64); CMake's
        # Android platform module uses linux-arm64. All names select the same
        # explicitly wrapped host tools. The target sysroot is untouched.
        ln -s linux-x86_64 "$out/toolchains/llvm/prebuilt/linux-aarch64"
        ln -s linux-x86_64 "$out/toolchains/llvm/prebuilt/linux-arm64"
        # ndk-build (Moonlight's native build) resolves its host tag in
        # build/tools/ndk_bin_common.sh, which only accepts arm64 (macOS) or
        # x86_64 from uname -m and exits on Linux aarch64. Map aarch64 to the
        # wrapped x86-64 tools; a no-op on x86-64 hosts.
        substituteInPlace "$out/build/tools/ndk_bin_common.sh" \
          --replace-fail 'HOST_ARCH=$(uname -m)' \
            'HOST_ARCH=$(uname -m); [ "$HOST_ARCH" = aarch64 ] && HOST_ARCH=x86_64'
        # Same aliases for prebuilt make and friends.
        if [ -d "$out/prebuilt/linux-x86_64" ]; then
          ln -s linux-x86_64 "$out/prebuilt/linux-aarch64"
          ln -s linux-x86_64 "$out/prebuilt/linux-arm64"
        fi
      '';

  platform =
    pkgs.runCommand "android-platform-${platformVersion}"
      {
        nativeBuildInputs = [ pkgs.unzip ];
      }
      ''
        ${unpackOne (archive "platforms" platformVersion) "$out"}
        # sdkmanager writes package.xml on install. AGP does not recognise a
        # minor-versioned platform (ApiLevel=37.0) from source.properties
        # alone and would try to install it into the read-only SDK.
        prop() { sed -n "s/^$1=//p" "$out/source.properties"; }
        cat > "$out/package.xml" <<EOF
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02" xmlns:ns6="http://schemas.android.com/sdk/android/repo/repository2/04">
          <localPackage path="platforms;android-${platformVersion}" obsolete="false">
            <type-details xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="ns6:platformDetailsType">
              <api-level>$(prop AndroidVersion.ApiLevel)</api-level>
              <codename>$(prop AndroidVersion.CodeName)</codename>
              <extension-level>$(prop AndroidVersion.ExtensionLevel)</extension-level>
              <base-extension>$(prop AndroidVersion.IsBaseSdk)</base-extension>
              <layoutlib api="$(prop Layoutlib.Api)"/>
            </type-details>
            <revision><major>$(prop Pkg.Revision)</major></revision>
            <display-name>Android SDK Platform ${platformVersion}</display-name>
          </localPackage>
        </ns2:repository>
        EOF
      '';

  commandLine =
    pkgs.runCommand "android-commandline-tools-${cmdlineVersion}"
      {
        nativeBuildInputs = [
          pkgs.unzip
          pkgs.makeWrapper
        ];
      }
      ''
        ${unpackOne (archive "cmdline-tools" cmdlineVersion) "$out"}
        patchShebangs "$out/bin"
        for tool in "$out/bin/"*; do
          wrapProgram "$tool" --set JAVA_HOME ${pkgs.jdk21}
        done
      '';

  licenseHashes = lib.concatStringsSep "\n" (
    map (text: builtins.hashString "sha1" text) repo.licenses.android-sdk-license
  );

  sdk = pkgs.runCommand "moonlight-android-sdk" { } ''
    mkdir -p "$out"/{bin,build-tools,platforms,cmdline-tools,ndk,licenses,platform-tools}
    ln -s ${buildTools} "$out/build-tools/${buildToolsVersion}"
    ln -s ${platform} "$out/platforms/android-${platformVersion}"
    ln -s ${commandLine} "$out/cmdline-tools/${cmdlineVersion}"
    ln -s ${cmdlineVersion} "$out/cmdline-tools/latest"
    ln -s ${ndk} "$out/ndk/${ndkVersion}"
    ln -s ${ndk} "$out/ndk-bundle"
    # ADB runs natively and keeps using the user's usual ~/.android/adbkey.
    ln -s ${pkgs.android-tools}/bin/adb "$out/platform-tools/adb"
    ln -s ${pkgs.android-tools}/bin/fastboot "$out/platform-tools/fastboot"
    cat > "$out/platform-tools/source.properties" <<EOF
    Pkg.Desc=Native Android platform tools (Nix)
    Pkg.Revision=${pkgs.android-tools.version}
    EOF
    for name in adb fastboot; do
      ln -s "$out/platform-tools/$name" "$out/bin/$name"
    done
    for name in aapt aapt2 aidl zipalign apksigner d8 dexdump; do
      if [ -e "${buildTools}/$name" ]; then
        ln -s "${buildTools}/$name" "$out/bin/$name"
      fi
    done
    ln -s ${commandLine}/bin/sdkmanager "$out/bin/sdkmanager"
    cp ${pkgs.writeText "android-sdk-license" (licenseHashes + "\n")} \
      "$out/licenses/android-sdk-license"
  '';
in
{
  inherit
    sdk
    ndk
    buildTools
    ndkVersion
    ;
}
