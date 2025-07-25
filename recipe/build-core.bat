bazel clean --expunge
bazel shutdown

cd python
echo on
set SKIP_THIRDPARTY_INSTALL=1
set IS_AUTOMATED_BUILD=1
set "BAZEL_SH=%BUILD_PREFIX%\Library\usr\bin\bash.exe"

set SKIP_THIRDPARTY_INSTALL_CONDA_FORGE=1

echo ==========================================================
echo calling pip install
echo ==========================================================

rem avoid multiple jobs causing file-access conflicts
echo build --jobs=1 >> ..\.bazelrc
"%PYTHON%" -m pip install . --no-deps --no-build-isolation
rem remember the return code
set RETCODE=%ERRORLEVEL%

rem Now clean everything up so subsequent builds (for potentially
rem different Python version) do not stumble on some after-effects.
"%PYTHON%" setup.py clean --all

rem setup.py uses D:\bazel-root and D:\b-o since ray 2.10.0.
rem We may have to patch this behavior out since these directories
rem could be conceivably used (and cleaned!) concurrently by unrelated builds
rem Get the drive for SRC_DIR
@for %%G in  ("%SRC_DIR%") DO @SET DRIVE=%%~dG
rem Now shut down Bazel server, otherwise Windows would not allow moving a directory with it
bazel "--output_user_root=%DRIVE%\bazel-root" "--output_base=%DRIVE%\b-o" clean --expunge
bazel "--output_user_root=%DRIVE%\bazel-root" "--output_base=%DRIVE%\b-o" shutdown
rd /s /q "%DRIVE%\b-o" "%DRIVE%\bazel-root"
rem Ignore "bazel shutdown" errors
exit /b %RETCODE%