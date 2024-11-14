#!/bin/bash
set -xe

bazel clean --expunge
bazel shutdown

if [[ "${target_platform}" == linux-aarch64 ]]; then
  # Fix -Werror=stringop-overflow error
  echo 'build --per_file_copt="external/upb/upbc/protoc-gen-upbdefs\.cc@-w"' >> .bazelrc
  echo 'build --host_per_file_copt="external/upb/upbc/protoc-gen-upbdefs\.cc@-w"' >> .bazelrc
  # Fix memory error
  echo 'build --jobs=2' >> .bazelrc
fi

if [[ "${target_platform}" == osx-* ]]; then
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
else
  export LDFLAGS="${LDFLAGS} -lrt"
fi

echo build --linkopt=-static-libstdc++ >> .bazelrc
echo build --linkopt=-lm >> .bazelrc

# To debug, uncomment this
echo build --subcommands >> .bazelrc
echo build --verbose_failures >> .bazelrc

# For some weird reason, ar is not picked up on linux-aarch64
if [ $(uname -s) = "Linux" ] && [ ! -f "${BUILD_PREFIX}/bin/ar" ]; then
    ln -s "${BUILD}-ar" "${BUILD_PREFIX}/bin/ar"
    ln -s "$RANLIB" "${BUILD_PREFIX}/bin/ranlib"
    ln -sf "$LD" "${BUILD_PREFIX}/bin/ld"
fi

cd python/
export SKIP_THIRDPARTY_INSTALL=1
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
