#!/bin/bash
set -xe

bazel clean --expunge
bazel shutdown

# Fix: Bazel linux-sandbox restricts PATH to /bin:/usr/bin:/usr/local/bin
# This means it can't find python3 or other conda-env tools during builds (e.g.
# rules_pkg's build_zip for ray_redis.zip). Propagate the full conda PATH into
# every Bazel action via action_env.
# host_action_env is required for exec-configuration actions (e.g. rules_foreign_cc
# BootstrapGNUMake); without it "C compiler cannot create executables" on linux-64.
if [[ "${target_platform}" == linux-64 ]] || [[ "${target_platform}" == linux-aarch64 ]]; then
  echo "build --action_env=PATH=${PATH}" >> .bazelrc
  echo "build --action_env=PYTHONPATH=${PYTHONPATH:-}" >> .bazelrc
  echo "build --host_action_env=PATH=${PATH}" >> .bazelrc
  echo "build --host_action_env=PYTHONPATH=${PYTHONPATH:-}" >> .bazelrc
fi

if [[ "${target_platform}" == linux-aarch64 ]]; then
  # Fix -Werror=stringop-overflow error
  echo 'build --per_file_copt="external/upb/upbc/protoc-gen-upbdefs\.cc@-w"' >> .bazelrc
  echo 'build --host_per_file_copt="external/upb/upbc/protoc-gen-upbdefs\.cc@-w"' >> .bazelrc
  # Fix memory error. Stick with 2 cores for now.
  # Evaluate as the build system changes. 
  echo 'build --local_cpu_resources=2' >> .bazelrc
fi

if [[ "${target_platform}" == osx-* ]]; then
  # Force Bazel to use the conda C++ toolchain instead of Bazel’s Apple toolchain.
  export BAZEL_NO_APPLE_CPP_TOOLCHAIN=1
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  export SDKROOT=${CONDA_BUILD_SYSROOT}

  # Pass down some environment variables. This is needed for https://github.com/ray-project/ray/blob/ray-2.3.0/bazel/BUILD.redis#L51.
  echo build --action_env=AR >> .bazelrc
  echo build --action_env=CC_FOR_BUILD >> .bazelrc
  echo build --action_env=CONDA_BUILD_SYSROOT >> .bazelrc
  echo build --action_env=macos_min_version >> .bazelrc

  # Set the macOSK to use and the minimum macOS version.
  echo build --copt=-isysroot${CONDA_BUILD_SYSROOT} >> .bazelrc
  echo build --copt=-mmacosx-version-min=${macos_min_version} >> .bazelrc
  echo build --copt=-D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION >> .bazelrc

  echo build --host_copt=-isysroot${CONDA_BUILD_SYSROOT} >> .bazelrc
  echo build --host_copt=-mmacosx-version-min=${macos_min_version} >> .bazelrc
  echo build --host_copt=-D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION >> .bazelrc

  echo build --linkopt=-isysroot${CONDA_BUILD_SYSROOT} >> .bazelrc
  echo build --linkopt=-mmacosx-version-min=${macos_min_version} >> .bazelrc

  echo build --host_linkopt=-isysroot${CONDA_BUILD_SYSROOT} >> .bazelrc
  echo build --host_linkopt=-mmacosx-version-min=${macos_min_version} >> .bazelrc

  # We get come warnings that are transformed to errors. Downgrade them to warnings.
  echo 'build --per_file_copt="spdlog/.*@-w"' >> .bazelrc
  echo 'build --per_file_copt="src/ray/.*$@-w"' >> .bazelrc

  # Abseil 20240722 enables header_modules/parse_headers; with the conda toolchain on
  # darwin_arm64 this leads to "missing dependency declarations" for .cppmap files
  # (e.g. usage_internal, bad_optional_access). Disable via features and force compiler
  # to ignore modules so the build succeeds regardless of toolchain defaults.
  echo 'build --features=-header_modules,-parse_headers,-layering_check' >> .bazelrc
  echo 'build --host_features=-header_modules,-parse_headers,-layering_check' >> .bazelrc
  echo 'build --copt=-fno-cxx-modules' >> .bazelrc
  echo 'build --host_copt=-fno-cxx-modules' >> .bazelrc
else
  export LDFLAGS="${LDFLAGS} -lrt"
  if [[ "${target_platform}" == linux-64 ]]; then
    echo "build --host_linkopt=-ldl" >> .bazelrc
  fi
fi

echo build --linkopt=-static-libstdc++ >> .bazelrc
echo build --linkopt=-lm >> .bazelrc
# echo build --linkopt=-ldl >> .bazelrc

# To debug, uncomment this
echo build --sandbox_debug >> .bazelrc
echo build --subcommands >> .bazelrc
echo build --verbose_failures >> .bazelrc
echo build --spawn_strategy=standalone >> .bazelrc

# For some weird reason, build tools are not picked up on linux-aarch64
if [[ "${target_platform}" == linux-aarch64 ]]; then
    echo build --action_env=BUILD_PREFIX=${BUILD_PREFIX} >> .bazelrc
    # Fix missing build tools by creating symlinks to generic names
    if [ ! -f "${BUILD_PREFIX}/bin/ar" ]; then ln -s "${AR}" "${BUILD_PREFIX}/bin/ar"; fi
    if [ ! -f "${BUILD_PREFIX}/bin/ranlib" ]; then ln -s "${RANLIB}" "${BUILD_PREFIX}/bin/ranlib"; fi
    if [ ! -f "${BUILD_PREFIX}/bin/ld" ]; then ln -s "${LD}" "${BUILD_PREFIX}/bin/ld"; fi
    if [ ! -f "${BUILD_PREFIX}/bin/gcc" ]; then ln -s "${CC}" "${BUILD_PREFIX}/bin/gcc"; fi
    if [ ! -f "${BUILD_PREFIX}/bin/g++" ]; then ln -s "${CXX}" "${BUILD_PREFIX}/bin/g++"; fi
    if [ ! -f "${BUILD_PREFIX}/bin/strip" ]; then ln -s "${STRIP}" "${BUILD_PREFIX}/bin/strip"; fi
fi

# linux-64: rules_foreign_cc BootstrapGNUMake configure fails with "C compiler cannot
# create executables" unless ld/ld.gold and other tools are found via symlinks, and
# unless host/exec actions see conda LDFLAGS/CFLAGS so the configure link test finds libs.
if [[ "${target_platform}" == linux-64 ]]; then
    echo build --action_env=BUILD_PREFIX=${BUILD_PREFIX} >> .bazelrc
    echo "build --host_action_env=BUILD_PREFIX=${BUILD_PREFIX}" >> .bazelrc
    # Pass conda toolchain flags to exec/host so BootstrapGNUMake configure can link test binaries.
    [[ -n "${LDFLAGS}" ]] && echo "build --host_action_env=LDFLAGS=\"${LDFLAGS}\"" >> .bazelrc
    [[ -n "${CFLAGS}" ]] && echo "build --host_action_env=CFLAGS=\"${CFLAGS}\"" >> .bazelrc
    [[ -n "${LIBRARY_PATH}" ]] && echo "build --host_action_env=LIBRARY_PATH=\"${LIBRARY_PATH}\"" >> .bazelrc
    if [ ! -f "${BUILD_PREFIX}/bin/ar" ]; then ln -s "${AR}" "${BUILD_PREFIX}/bin/ar"; fi
    if [ ! -f "${BUILD_PREFIX}/bin/ranlib" ]; then ln -s "${RANLIB}" "${BUILD_PREFIX}/bin/ranlib"; fi
    if [ ! -f "${BUILD_PREFIX}/bin/ld" ]; then ln -s "${LD}" "${BUILD_PREFIX}/bin/ld"; fi
    # LDFLAGS from toolchain use -fuse-ld=gold; configure needs ld.gold in PATH/-B dir.
    if [ ! -f "${BUILD_PREFIX}/bin/ld.gold" ]; then
      for gold_ld in "${BUILD_PREFIX}/bin"/*-ld.gold; do
        if [ -x "$gold_ld" ]; then
          ln -s "$(basename "$gold_ld")" "${BUILD_PREFIX}/bin/ld.gold"
          break
        fi
      done
      # Fallback: use bfd ld as ld.gold so configure's link test succeeds.
      if [ ! -f "${BUILD_PREFIX}/bin/ld.gold" ] && [ -f "${BUILD_PREFIX}/bin/ld" ]; then
        ln -s ld "${BUILD_PREFIX}/bin/ld.gold"
      fi
    fi
    if [ ! -f "${BUILD_PREFIX}/bin/gcc" ]; then ln -s "${CC}" "${BUILD_PREFIX}/bin/gcc"; fi
    if [ ! -f "${BUILD_PREFIX}/bin/g++" ]; then ln -s "${CXX}" "${BUILD_PREFIX}/bin/g++"; fi
    if [ ! -f "${BUILD_PREFIX}/bin/strip" ]; then ln -s "${STRIP}" "${BUILD_PREFIX}/bin/strip"; fi
fi

cd python/
export SKIP_THIRDPARTY_INSTALL_CONDA_FORGE=1
"${PYTHON}" setup.py build
# bazel by default makes everything read-only,
# which leads to patchelf failing to fix rpath in binaries.
# find all ray binaries and make them writable
grep -lR ELF build/ | xargs chmod +w

# now install the thing so conda could pick it up
${PYTHON} -m pip install . --no-deps --no-build-isolation

# now clean everything up so subsequent builds (for potentially
# different Python version) do not stumble on some after-effects
"${PYTHON}" setup.py clean --all
bazel "--output_user_root=$SRC_DIR/../bazel-root" "--output_base=$SRC_DIR/../b-o" clean --expunge
bazel "--output_user_root=$SRC_DIR/../bazel-root" "--output_base=$SRC_DIR/../b-o" shutdown
rm -rf "$SRC_DIR/../b-o" "$SRC_DIR/../bazel-root"
# this is needed because on many build systems the cache is actually under /root.
# but this may not always be true/allowed, hence the or operation.
rm -rf /root/.cache/bazel || true

# Remove RUNPATH and set RPATH
# if [[ "$target_platform" == "linux-"* ]]; then
#   for f in "ray/_raylet.so" "ray/core/src/ray/raylet/raylet" "ray/core/src/ray/gcs/gcs_server"; do
#     patchelf --remove-rpath $SP_DIR/$f
#     patchelf --force-rpath --add-rpath $PREFIX/lib $SP_DIR/$f
#   done
# fi