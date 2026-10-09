{
  description = "moonlight-android: Java + ndk-build development on ARM64 and x86-64 Linux";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "aarch64-linux" "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      environments = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          # Same ARM/QEMU-aware SDK as streamer; NDK bumped to Moonlight's pin.
          x86 = import nixpkgs { system = "x86_64-linux"; };
          android = import ./nix/android.nix { inherit pkgs x86 nixpkgs; };

          # Moonlight has root/nonRoot flavors; root is maxSdk 25, so nonRoot.
          variant = "NonRootDebug";
          apkDir = "app/build/outputs/apk/nonRoot/debug";

          androidGradle = pkgs.writeShellApplication {
            name = "android-gradle";
            # ndk-build shells out to python3 for compile_commands.json.
            runtimeInputs = [ pkgs.bash pkgs.jdk21 pkgs.python3 ];
            text = ''
              if [[ ! -f ./gradlew ]]; then
                echo "Run this from the moonlight-android root (containing gradlew)." >&2
                exit 1
              fi
              # moonlight-common-c and its nested enet/nanors are submodules.
              core=app/src/main/jni/moonlight-core/moonlight-common-c
              for f in src/Limelight.h enet/host.c nanors/rs.c; do
                if [[ ! -e "$core/$f" ]]; then
                  echo "Missing $core/$f; run: git submodule update --init --recursive" >&2
                  exit 1
                fi
              done
              export JAVA_HOME=${pkgs.jdk21}
              export ANDROID_HOME=${android.sdk}
              export ANDROID_SDK_ROOT=${android.sdk}
              exec bash ./gradlew \
                -Pandroid.aapt2FromMavenOverride=${android.buildTools}/aapt2 "$@"
            '';
          };
          androidBuild = pkgs.writeShellApplication {
            name = "android-build";
            runtimeInputs = [ androidGradle ];
            text = ''
              exec android-gradle assemble${variant} "$@"
            '';
          };
          androidInstall = pkgs.writeShellApplication {
            name = "android-install";
            runtimeInputs = [ pkgs.android-tools pkgs.jq pkgs.coreutils ];
            text = ''
              # USB or an already-connected wireless ADB device.
              # Set ANDROID_SERIAL when more than one device is connected.
              launch=1
              for arg in "$@"; do
                case "$arg" in
                  --no-launch) launch=0 ;;
                  -h | --help)
                    echo "Usage: android-install [--no-launch]"
                    exit 0
                    ;;
                  *) echo "Unknown argument: $arg" >&2; exit 2 ;;
                esac
              done
              apk_dir=${apkDir}
              metadata="$apk_dir/output-metadata.json"
              if [[ ! -f "$metadata" ]]; then
                echo "No debug APK in $apk_dir; run android-build first." >&2
                exit 1
              fi
              # Fail explicitly for split APKs rather than installing only one.
              if [[ "$(jq -r '.elements | length' "$metadata")" != 1 ]]; then
                echo "Expected one debug APK. Use android-gradle install${variant} for split APKs." >&2
                exit 1
              fi
              app_id=$(jq -er '.applicationId | select(length > 0)' "$metadata")
              apk="$apk_dir/$(jq -er '.elements[0].outputFile | select(length > 0)' "$metadata")"
              if [[ ! -f "$apk" ]]; then
                echo "APK not found: $apk" >&2
                exit 1
              fi
              if ! adb get-state > /dev/null 2>&1; then
                echo "No selected authorized device; check adb devices and ANDROID_SERIAL." >&2
                exit 1
              fi
              echo "Installing $apk as $app_id"
              adb install -r "$apk"
              if [[ "$launch" == 1 ]]; then
                component=$(adb shell cmd package resolve-activity --brief \
                  -c android.intent.category.LAUNCHER "$app_id" | tail -n 1 | tr -d '\r')
                if [[ "$component" != */* ]]; then
                  echo "Could not resolve launcher activity for $app_id: $component" >&2
                  exit 1
                fi
                adb shell am start -W -n "$component"
              fi
            '';
          };
          androidRun = pkgs.writeShellApplication {
            name = "android-run";
            runtimeInputs = [ androidBuild androidInstall pkgs.android-tools pkgs.jq pkgs.coreutils ];
            text = ''
              logcat=0
              for arg in "$@"; do
                case "$arg" in
                  --logcat) logcat=1 ;;
                  -h | --help)
                    echo "Usage: android-run [--logcat]"
                    exit 0
                    ;;
                  *) echo "Unknown argument: $arg" >&2; exit 2 ;;
                esac
              done
              android-build
              android-install
              if [[ "$logcat" == 1 ]]; then
                app_id=$(jq -er '.applicationId' ${apkDir}/output-metadata.json)
                pid=$(adb shell pidof -s "$app_id" 2> /dev/null | tr -d '\r' || true)
                if [[ -z "$pid" ]]; then
                  echo "$app_id is not running; check adb logcat for a startup crash." >&2
                  exit 1
                fi
                echo "Following logcat for $app_id (pid $pid); Ctrl-C to stop."
                exec adb logcat --pid="$pid"
              fi
            '';
          };
          doctor = pkgs.writeShellApplication {
            name = "android-doctor";
            runtimeInputs = [ pkgs.jdk21 pkgs.android-tools ];
            text = ''
              echo "Host: ${system}"
              echo "SDK: ${android.sdk}"
              echo "NDK: ${android.ndk} (${android.ndkVersion})"
              echo "Google native tools: ${if pkgs.stdenv.hostPlatform.isAarch64 then "QEMU x86-64 wrappers" else "native x86-64"}"
              java -version
              adb version
              ${android.buildTools}/aapt2 version
              ${android.ndk}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang --version
              make=${android.ndk}/prebuilt/linux-x86_64/bin/make
              if [[ -x "$make" ]]; then "$make" --version | head -n 1; else echo "No NDK prebuilt make" >&2; exit 1; fi
              echo "Tool launch checks passed; an APK build has not been tested."
            '';
          };
        in {
          inherit pkgs android doctor;
          shell = pkgs.mkShell {
            name = "moonlight-android";
            packages = [
              pkgs.jdk21
              # Use the project's ./gradlew, not a separately pinned Gradle.
              pkgs.git
              pkgs.ripgrep
              pkgs.jq
              pkgs.curl
              pkgs.cacert
              pkgs.unzip
              pkgs.python3
              pkgs.android-tools
              pkgs.nixfmt
              pkgs.shellcheck
              android.sdk
              androidGradle
              androidBuild
              androidInstall
              androidRun
              doctor
            ];

            JAVA_HOME = "${pkgs.jdk21}";
            ANDROID_HOME = "${android.sdk}";
            ANDROID_SDK_ROOT = "${android.sdk}";
            ANDROID_AAPT2 = "${android.buildTools}/aapt2";
            # Preserve the override for plain ./gradlew as well as android-gradle.
            GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${android.buildTools}/aapt2";

            shellHook = ''
              # Enter nix develop from the moonlight-android root.
              export GRADLE_USER_HOME="$PWD/.gradle-user-home"
              export ANDROID_USER_HOME="$PWD/.android-user-home"
              mkdir -p "$GRADLE_USER_HOME" "$ANDROID_USER_HOME"
              echo "moonlight-android dev shell (${system})"
              echo "Run android-doctor, then android-run [--logcat]."
            '';
          };
        });
    in {
      devShells = forAllSystems (system: {
        default = environments.${system}.shell;
        android = environments.${system}.shell;
      });
      packages = forAllSystems (system: {
        android-sdk = environments.${system}.android.sdk;
        android-ndk = environments.${system}.android.ndk;
        android-build-tools = environments.${system}.android.buildTools;
        android-doctor = environments.${system}.doctor;
      });
      apps = forAllSystems (system: {
        doctor = {
          type = "app";
          meta.description = "Check Android tool launches";
          program = "${environments.${system}.doctor}/bin/android-doctor";
        };
      });
      formatter = forAllSystems (system: environments.${system}.pkgs.nixfmt);
    };
}
