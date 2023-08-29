#!/bin/bash
set -xe

# bazel clean --expunge
# bazel shutdown

if [[ "${target_platform}" == osx-* ]]; then
  export LDFLAGS="${LDFLAGS} -lz -framework CoreFoundation -Xlinker -undefined -Xlinker dynamic_lookup"
else
  export LDFLAGS="${LDFLAGS} -lrt"
fi

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

# # now clean everything up so subsequent builds (for potentially
# # different Python version) do not stumble on some after-effects
# "${PYTHON}" setup.py clean --all
# bazel "--output_user_root=$SRC_DIR/../bazel-root" "--output_base=$SRC_DIR/../b-o" clean --expunge
# bazel "--output_user_root=$SRC_DIR/../bazel-root" "--output_base=$SRC_DIR/../b-o" shutdown
# rm -rf "$SRC_DIR/../b-o" "$SRC_DIR/../bazel-root"
# # this is needed because on many build systems the cache is actually under /root.
# # but this may not always be true/allowed, hence the or operation.
# rm -rf /root/.cache/bazel || true

# Remove RUNPATH and set RPATH
# if [[ "$target_platform" == "linux-"* ]]; then
#   for f in "ray/_raylet.so" "ray/core/src/ray/raylet/raylet" "ray/core/src/ray/gcs/gcs_server"; do
#     patchelf --remove-rpath $SP_DIR/$f
#     patchelf --force-rpath --add-rpath $PREFIX/lib $SP_DIR/$f
#   done
# fi
