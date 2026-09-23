#!/bin/sh
# Builds mariadbd (+ storage engine/auth plugins as shared libraries) out-of-tree, for
# linux/mac/windows. Like the other user/scripts/build_*.sh in this repo, nothing is written
# back into the submodule's own tree: everything lands under
# user/release/<platform>/<arch>/<version>/{bin,shared,include}, and scratch/build state
# lives under user/_build (not user/release).
#
# ios/android are refused outright, not attempted: mariadbd is a network daemon (listening
# sockets, forked/threaded connection handling, a filesystem-backed data directory) with no
# officially supported mobile-app-sandbox build, unlike the client libraries
# (openssl/mariadb-connector-c) this same repo does build for those platforms.
#
# Almost no source patch is needed. Every option this script sets -- PLUGIN_<NAME>=NO,
# WITH_WSREP=OFF, WITH_SSL=<path>, CMAKE_COMPILE_WARNING_AS_ERROR=OFF -- is a first-class
# CMake cache option/variable MariaDB's own build already exposes. PLUGIN_ROCKSDB,
# PLUGIN_COLUMNSTORE, PLUGIN_S3 and WITH_WSREP each have their own "not checked out" guard
# in this tree already; PLUGIN_DUCKDB does not (storage/duckdb/CMakeLists.txt has no such
# early-out), but CMake's own MYSQL_ADD_PLUGIN macro (cmake/plugin.cmake) treats any
# PLUGIN_<NAME> cache variable pre-set on the command line as authoritative before the
# plugin's own CMakeLists ever runs, so passing PLUGIN_DUCKDB=NO here skips it the same way
# regardless. None of these six nested submodules (rocksdb, wsrep-lib, wolfssl, libmarias3,
# columnstore, duckdb's third_parties/duckdb) need to be checked out for this build.
#
# One exception, applied via user/patches/*.patch (see apply_patches() below), not a direct
# edit: client/CMakeLists.txt hardcodes `SET(CLIENT_LIB mariadbclient mysys)`, statically
# linking the client protocol code into every one of mariadb/mariadb-admin/mariadb-dump/etc
# individually (confirmed via ldd -- none of them depend on libmariadb.so as built). There is
# no CMake option for this, so 01_client_dynamic_link.patch switches it to the `libmariadb`
# shared target instead, saving the ~7-10MB of duplicated client-library code per tool with
# no runtime cost (these are one-shot CLI tools; static vs dynamic linking doesn't change how
# fast the code runs, only how many copies of it exist on disk).
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
USER_DIR="${ROOT_DIR}/user"
RELEASE_DIR="${USER_DIR}/release"
BUILD_ROOT="${USER_DIR}/_build"
STAGE_ROOT="${BUILD_ROOT}/_stage"
LOG_DIR="${USER_DIR}/logs"

PLATFORM=""
PLATFORM_SET=0
CLEAN=1
VERSION_OVERRIDE=""

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/build-mariadb-server-${TIMESTAMP}.log"

mkdir -p "${LOG_DIR}" "${RELEASE_DIR}" "${BUILD_ROOT}" "${STAGE_ROOT}"
: > "${LOG_FILE}"

log_line() {
    level="$1"
    shift
    line="[${level}] $*"
    printf '%s\n' "${line}"
    printf '%s\n' "${line}" >> "${LOG_FILE}"
}

run_and_log() {
    log_line INFO "RUN: $*"
    tmp_log="${LOG_DIR}/.cmd-$$-$(date +%s).log"
    rc=0
    "$@" > "${tmp_log}" 2>&1 || rc=$?
    cat "${tmp_log}" | tee -a "${LOG_FILE}"
    rm -f "${tmp_log}"
    [ "${rc}" -eq 0 ] && return 0
    log_line ERROR "Command failed (exit=${rc}): $*"
    return "${rc}"
}

usage() {
    cat << 'EOF'
Usage:
  sh user/scripts/build_mariadb_server.sh [options]

Options:
  --platform <linux|mac|windows>   (ios/android are refused -- see this file's header)
  --clean | --no-clean
  --version <value>
  --help

Environment variables:
  OPENSSL_ROOT_DIR    Required. Point it at a submodules/openssl build output dir
                       (.../<platform>/<arch>/<version>), i.e. build that submodule first.
                       Never falls back to a system-installed OpenSSL.
  WINDOWS_TOOLCHAIN_FILE   Required for --platform windows on a non-Windows host
  JOBS                Optional build parallelism (default: host CPU count)

Host prerequisites this script does not install for you (all confirmed against this exact
tree's CMakeLists.txt/cmake/*.cmake, not assumed): cmake, a C/C++ toolchain, bison >= 2.4
(generates sql/sql_yacc.cc -- there is no pre-generated parser committed to this tree),
curses/readline development headers (MYSQL_CHECK_READLINE calls FIND_PACKAGE(Curses
REQUIRED) unconditionally for the mariadb/mysql CLI client -- e.g. libncurses-dev on
Debian/Ubuntu, ncurses-devel on Fedora/RHEL, ncurses via Homebrew on mac), and on Windows, a
working mingw-w64 cross toolchain. Unlike OpenSSL, these are ordinary build tools available
via every platform's normal package manager, not something this repo vendors itself.

Disabled up front, on every platform, because their nested git submodules are not checked
out in this tree (see submodules/mariadb-server/.gitmodules): the RocksDB, ColumnStore, S3
and DuckDB storage engines, and the WSREP/Galera replication API. If you want any of those,
add and init the matching submodule first, then drop the matching -DPLUGIN_..=NO /
-DWITH_WSREP=OFF from this script's COMMON_DEFS.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --platform)
            [ "$#" -ge 2 ] || { log_line ERROR "Missing value for --platform"; exit 2; }
            PLATFORM="$2"; PLATFORM_SET=1; shift 2 ;;
        --clean) CLEAN=1; shift ;;
        --no-clean) CLEAN=0; shift ;;
        --version)
            [ "$#" -ge 2 ] || { log_line ERROR "Missing value for --version"; exit 2; }
            VERSION_OVERRIDE="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) log_line ERROR "Unknown argument: $1"; usage; exit 2 ;;
    esac
done

if [ "${PLATFORM_SET}" -eq 1 ]; then
    case "${PLATFORM}" in
        linux|mac|windows) ;;
        ios|android)
            log_line ERROR "--platform ${PLATFORM} is not supported for mariadb-server: mariadbd is a network daemon (listening sockets, a filesystem data directory, forked/threaded connection handling) with no officially supported mobile build -- unlike this repo's openssl/mariadb-connector-c builds, which do target ${PLATFORM}."
            exit 2
            ;;
        *) log_line ERROR "Invalid --platform value: ${PLATFORM}"; exit 2 ;;
    esac
else
    host_os=$(uname -s)
    case "${host_os}" in
        Darwin) PLATFORM="mac" ;;
        Linux) PLATFORM="linux" ;;
        MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
        *) log_line ERROR "Unsupported host OS: ${host_os}. Use --platform to select a target explicitly."; exit 2 ;;
    esac
    log_line INFO "Auto-detected host platform '${PLATFORM}' from '${host_os}'."
fi

if [ "${PLATFORM}" = "windows" ]; then
    log_line WARN "MariaDB server's Windows support historically targets MSVC; this script builds it with a mingw-w64 toolchain (for consistency with this repo's other Windows builds) which is comparatively untested upstream. Expect to iterate here."
fi

for tool in cmake bison; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        log_line ERROR "${tool} was not found. Install it and retry (bison must be >= 2.4; there is no pre-generated sql/sql_yacc.cc committed to this tree)."
        exit 2
    fi
done

if [ -n "${VERSION_OVERRIDE}" ]; then
    VERSION="${VERSION_OVERRIDE}"
    log_line INFO "Using version override: ${VERSION}"
else
    VERSION=$(
        awk -F= '
            /^MYSQL_VERSION_MAJOR=/ { maj=$2 }
            /^MYSQL_VERSION_MINOR=/ { min=$2 }
            /^MYSQL_VERSION_PATCH=/ { pat=$2 }
            END { if (maj != "" && min != "" && pat != "") print maj "." min "." pat }
        ' "${ROOT_DIR}/VERSION" 2>/dev/null
    )
    if [ -z "${VERSION}" ]; then
        VERSION=$(git -C "${ROOT_DIR}" describe --tags --always 2>/dev/null || date +%Y%m%d)
        log_line FALLBACK "Could not read VERSION. Using ${VERSION}."
    else
        log_line INFO "Using repo version: ${VERSION}"
    fi
fi

if [ "${CLEAN}" -eq 1 ]; then
    log_line INFO "Cleaning build/stage roots"
    rm -rf "${BUILD_ROOT}"
    mkdir -p "${BUILD_ROOT}" "${STAGE_ROOT}"
fi

JOBS_DEFAULT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
JOBS=${JOBS:-${JOBS_DEFAULT}}

# Applies user/patches/*.patch directly to this submodule's own checkout (ROOT_DIR), not a
# scratch copy (unlike chdman-simd's build script) -- mariadb-server's full tree is too large
# to duplicate for one one-line change. This does leave the patched file(s) showing as
# modified in `git status` inside submodules/mariadb-server after a build; that's expected,
# not a bug -- revert with a plain file edit or `git checkout -- <file>` yourself if you want
# a clean checkout (this script never runs git). Idempotent: a dry-run first, in both
# directions, so re-running this script on an already-patched tree is a no-op, not a failure.
apply_patches() {
    patch_dir="${USER_DIR}/patches"
    [ -d "${patch_dir}" ] || return 0
    for p in "${patch_dir}"/*.patch; do
        [ -e "${p}" ] || continue
        name=$(basename "${p}")
        if (cd "${ROOT_DIR}" && patch -p1 --dry-run < "${p}") >/dev/null 2>&1; then
            (cd "${ROOT_DIR}" && patch -p1 < "${p}")
            log_line INFO "Applied patch: ${name}"
        elif (cd "${ROOT_DIR}" && patch -p1 -R --dry-run < "${p}") >/dev/null 2>&1; then
            log_line INFO "Patch already applied: ${name}"
        else
            log_line ERROR "Patch ${name} does not apply (forward or reverse) -- this tree's client/CMakeLists.txt may have changed upstream. Manual merge needed."
            return 1
        fi
    done
}

apply_patches || exit 1

# See this repo's submodules/mariadb-connector-c/user/scripts/build_connector_c.sh: same
# reasoning, same mismatch (our openssl build publishes shared/+include/, not the lib(64)/+
# include/ layout FindOpenSSL's own search expects), same fix -- resolve the exact
# library/header paths ourselves instead of relying on OPENSSL_ROOT_DIR's directory-
# convention search.
# Same auto-discovery as submodules/mariadb-connector-c/user/scripts/build_connector_c.sh:
# picks the newest-mtime version dir under ../openssl/user/release/<platform>/<arch>/ when
# OPENSSL_ROOT_DIR isn't set, rather than requiring it on every invocation.
auto_discover_openssl_root() {
    platform_name="$1"
    arch_name="$2"
    candidates_dir="${ROOT_DIR}/../openssl/user/release/${platform_name}/${arch_name}"
    [ -d "${candidates_dir}" ] || return 1
    latest=$(ls -1dt "${candidates_dir}"/*/ 2>/dev/null | head -n 1)
    [ -n "${latest}" ] || return 1
    printf '%s' "${latest%/}"
}

ssl_defs_for() {
    # $1 = platform, $2 = arch.
    platform_name="$1"
    arch_name="$2"

    if [ -z "${OPENSSL_ROOT_DIR:-}" ]; then
        auto_root=$(auto_discover_openssl_root "${platform_name}" "${arch_name}") && [ -n "${auto_root}" ] || auto_root=""
        if [ -n "${auto_root}" ]; then
            OPENSSL_ROOT_DIR="${auto_root}"
            log_line INFO "OPENSSL_ROOT_DIR not set; auto-discovered latest build: ${OPENSSL_ROOT_DIR}" >&2
        fi
    fi

    if [ -z "${OPENSSL_ROOT_DIR:-}" ]; then
        log_line ERROR "OPENSSL_ROOT_DIR is not set, and no build was found under ../openssl/user/release/${platform_name}/${arch_name}/. Build the vendored OpenSSL submodule first (submodules/openssl/user/scripts/build_openssl.sh --platform ${platform_name}) or pass an existing output dir (.../${platform_name}/<arch>/<version>) as OPENSSL_ROOT_DIR." >&2
        return 1
    fi
    inc_dir="${OPENSSL_ROOT_DIR}/include"
    lib_dir=""
    for cand in "${OPENSSL_ROOT_DIR}/shared" "${OPENSSL_ROOT_DIR}/lib" "${OPENSSL_ROOT_DIR}/lib64"; do
        [ -d "${cand}" ] && { lib_dir="${cand}"; break; }
    done
    if [ ! -d "${inc_dir}" ] || [ -z "${lib_dir}" ]; then
        log_line ERROR "OPENSSL_ROOT_DIR=${OPENSSL_ROOT_DIR} is missing include/ or a shared|lib|lib64 dir." >&2
        return 1
    fi
    crypto_lib=$(find "${lib_dir}" -maxdepth 1 \( -type f -o -type l \) \( -name 'libcrypto.so' -o -name 'libcrypto.dylib' -o -name 'libcrypto.dll.a' -o -name 'libcrypto.lib' \) | head -n 1)
    ssl_lib=$(find "${lib_dir}" -maxdepth 1 \( -type f -o -type l \) \( -name 'libssl.so' -o -name 'libssl.dylib' -o -name 'libssl.dll.a' -o -name 'libssl.lib' \) | head -n 1)
    if [ -z "${crypto_lib}" ] || [ -z "${ssl_lib}" ]; then
        log_line ERROR "Could not find libcrypto/libssl under ${lib_dir}." >&2
        return 1
    fi
    log_line INFO "Using OpenSSL: include=${inc_dir} crypto=${crypto_lib} ssl=${ssl_lib}" >&2
    printf '%s' "-DWITH_SSL=${OPENSSL_ROOT_DIR} -DOPENSSL_ROOT_DIR=${OPENSSL_ROOT_DIR} -DOPENSSL_INCLUDE_DIR=${inc_dir} -DOPENSSL_CRYPTO_LIBRARY=${crypto_lib} -DOPENSSL_SSL_LIBRARY=${ssl_lib}"
}

rpath_defs_for() {
    # bin/ (mariadbd, client tools) and shared/ (plugins) are siblings in our own release
    # layout -- not bin/../lib, which doesn't exist here (see build_connector_c.sh's
    # collect_artifacts for the same "shared", not "lib", naming). This does NOT make the
    # output self-contained against OpenSSL: libssl/libcrypto are deliberately left in
    # submodules/openssl's own release output, not duplicated into shared/ here (single
    # canonical OpenSSL build, reused by connector-c/server/the main app, per the decision
    # not to copy it into every consumer) -- whatever assembles the final app bundle still
    # needs to place that directory's contents where these RPATHs (or LD_LIBRARY_PATH/
    # DYLD_LIBRARY_PATH) can find them at runtime.
    case "$1" in
        mac) printf '%s' "-DCMAKE_INSTALL_RPATH=@loader_path;@loader_path/../shared" ;;
        linux) printf '%s' "-DCMAKE_INSTALL_RPATH=\$ORIGIN:\$ORIGIN/../shared" ;;
        *) printf '%s' "" ;;
    esac
}

# CMAKE_COMPILE_WARNING_AS_ERROR=OFF: not strictly required as of writing (unlike
# mariadb-connector-c, which hits deprecated-declarations from this repo's newer vendored
# OpenSSL, MariaDB server's own -Werror handling is scattered across cmake/os/*.cmake rather
# than one blanket switch), but kept defensively for the same reason -- a newer OpenSSL than
# this server tree was written against can turn a warning into a hard error, and this is the
# documented, non-source-editing escape hatch (see build_connector_c.sh for the same note).
# Every PLUGIN_<NAME>=NO below is a storage engine or plugin this project doesn't use --
# each name confirmed against its own MYSQL_ADD_PLUGIN(<name> ...) call (not guessed from
# the .so filename, which can differ via MODULE_OUTPUT_NAME, e.g. ftexample -> mypluglib.so)
# so a typo here fails loudly at configure time instead of silently building anyway.
# Unused storage engines (not InnoDB/Aria/MyISAM, which stay -- Aria is MANDATORY and
# already statically linked into mariadbd, never a separate .so):
UNUSED_STORAGE_ENGINES="-DPLUGIN_ARCHIVE=NO -DPLUGIN_BLACKHOLE=NO -DPLUGIN_CONNECT=NO \
-DPLUGIN_EXAMPLE=NO -DPLUGIN_FEDERATED=NO -DPLUGIN_FEDERATEDX=NO -DPLUGIN_MROONGA=NO \
-DPLUGIN_SPHINX=NO -DPLUGIN_SPIDER=NO -DPLUGIN_TEST_SQL_DISCOVERY=NO"
# Test/example/QA-only plugins -- never meant to ship, only exist to exercise the plugin
# API in MariaDB's own test suite:
TEST_AND_EXAMPLE_PLUGINS="-DPLUGIN_FTEXAMPLE=NO -DPLUGIN_DAEMON_EXAMPLE=NO -DPLUGIN_FUNC_TEST=NO \
-DPLUGIN_DIALOG_EXAMPLES=NO -DPLUGIN_AUTH_TEST_PLUGIN=NO -DPLUGIN_QA_AUTH_INTERFACE=NO \
-DPLUGIN_QA_AUTH_SERVER=NO -DPLUGIN_QA_AUTH_CLIENT=NO -DPLUGIN_AUTH_0X0100=NO \
-DPLUGIN_TYPE_TEST=NO -DPLUGIN_TEST_VERSIONING=NO -DPLUGIN_TEST_SQL_SERVICE=NO -DPLUGIN_DISKS=NO"
# Optional introspection/policy plugins this project has no current use for (re-enable
# individually later if e.g. audit logging or InnoDB encryption-at-rest is ever wanted --
# FILE_KEY_MANAGEMENT, the real (non-test) encryption-at-rest plugin, is deliberately left
# enabled since it's small and may be useful, unlike its DEBUG_/EXAMPLE_ test-only siblings):
OPTIONAL_PLUGINS="-DPLUGIN_DEBUG_KEY_MANAGEMENT=NO -DPLUGIN_EXAMPLE_KEY_MANAGEMENT=NO \
-DPLUGIN_PROVIDER_BZIP2=NO -DPLUGIN_PASSWORD_REUSE_CHECK=NO -DPLUGIN_SIMPLE_PASSWORD_CHECK=NO \
-DPLUGIN_QUERY_RESPONSE_TIME=NO -DPLUGIN_QUERY_CACHE_INFO=NO -DPLUGIN_TYPE_MYSQL_JSON=NO \
-DPLUGIN_TYPE_MYSQL_TIMESTAMP=NO -DPLUGIN_HANDLERSOCKET=NO -DPLUGIN_LOCALES=NO \
-DPLUGIN_METADATA_LOCK_INFO=NO -DPLUGIN_SERVER_AUDIT=NO"

COMMON_DEFS="-DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF \
-DPLUGIN_ROCKSDB=NO -DPLUGIN_COLUMNSTORE=NO -DPLUGIN_S3=NO -DPLUGIN_DUCKDB=NO \
-DWITH_WSREP=OFF -DWITH_UNIT_TESTS=OFF -DWITH_EMBEDDED_SERVER=OFF \
${UNUSED_STORAGE_ENGINES} ${TEST_AND_EXAMPLE_PLUGINS} ${OPTIONAL_PLUGINS}"

collect_artifacts() {
    stage_dir="$1"
    platform_name="$2"
    arch_name="$3"
    all_defs="$4"

    out_base="${RELEASE_DIR}/${platform_name}/${arch_name}/${VERSION}"
    out_bin="${out_base}/bin"
    out_shared="${out_base}/shared"
    out_include="${out_base}/include"
    mkdir -p "${out_bin}" "${out_shared}" "${out_include}"

    # Curated allowlist, trimmed to what a programmatic sqlx-only app plus occasional manual
    # debugging actually needs -- not "copy everything cmake --install produced" (a real
    # build without this list produces 43 files, 557MB, in bin/ alone). Kept:
    #   mariadbd, mariadbd-safe(-helper), mariadb-waitpid -- the daemon and how it's run.
    #   mariadb-install-db -- one-time data directory init before mariadbd's first start
    #     (installs to scripts/, not bin/ -- omitting it here was an earlier bug).
    #   mariadb -- the interactive client, kept for manual debugging (poke at live data,
    #     SHOW PROCESSLIST/EXPLAIN/ENGINE INNODB STATUS) -- the one tool here that actually
    #     saves time day to day; everything sqlx can already do isn't worth a second copy.
    #   mariadb-dump, mariadb-show, mariadb-check -- explicitly requested to keep.
    # Dropped as redundant with the app driving sqlx directly, or too narrow a disaster-
    # recovery/production-DBA use case for a local single-app instance: mariadb-admin
    # (mariadb-e "..." covers ping/status/processlist), aria_chk/aria_pack/aria_dump_log/
    # aria_read_log/aria_ftdump/myisamchk/myisampack/myisamlog/myisam_ftdump/innochecksum
    # (offline, server-stopped corruption checks -- InnoDB already validates itself via its
    # own redo log/doublewrite buffer on startup), mariadb-backup/mariabackup/mbstream
    # (338MB -- a stopped-server file copy, or `FLUSH TABLES WITH READ LOCK` + copy while
    # running, covers backup here), mariadb-binlog/mariadb-hotcopy (replication/legacy, not
    # applicable), mariadb-test/mariadb-client-test (MTR test-suite internals), mariadbd-multi
    # (multi-instance management, not needed), mariadb-secure-installation/-tzinfo-to-sql/
    # -upgrade/-plugin/-setpermission/-access/-migrate-config-file/-service-convert/
    # -convert-table-format/-fix-extensions (one-time/legacy setup scripts), mariadb-slap
    # (load-testing tool, not applicable to a single local app), mariadb-import (mariadb-dump
    # is kept but LOAD DATA INFILE via sqlx covers import), my_print_defaults/perror/mytop/
    # replace/resolve_stack_dump/resolveip/mariadb_config/mysql_config/mariadb-conv/
    # mariadb-dumpslow/mariadb-find-rows (small standalone utilities, none load-bearing), and
    # every legacy mysql*/mysqld* compatibility symlink.
    BIN_KEEP_LIST="mariadbd mariadbd-safe mariadbd-safe-helper mariadb-waitpid \
mariadb-install-db mariadb mariadb-dump mariadb-show mariadb-check"

    for bindir in bin sbin scripts; do
        d="${stage_dir}/${bindir}"
        [ -d "${d}" ] || continue
        for name in ${BIN_KEEP_LIST}; do
            f="${d}/${name}"
            [ -e "${f}" ] || [ -L "${f}" ] || continue
            cp -Pf "${f}" "${out_bin}/"
        done
    done

    for libdir in lib lib64; do
        d="${stage_dir}/${libdir}"
        [ -d "${d}" ] || continue
        # -r: plugin .so files live under lib/plugin/, lib/mysql/plugin/, etc, not flat.
        find "${d}" \( -type f -o -type l \) \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.dll' \) | while IFS= read -r f; do
            cp -Pf "${f}" "${out_shared}/"
        done
    done
    find "${stage_dir}/bin" -maxdepth 1 -type f -name '*.dll' 2>/dev/null | while IFS= read -r f; do
        cp -f "${f}" "${out_shared}/" 2>/dev/null || true
    done

    if [ -d "${stage_dir}/include" ]; then
        cp -R "${stage_dir}/include/." "${out_include}/"
    fi

    {
        echo "timestamp=${TIMESTAMP}"
        echo "platform=${platform_name}"
        echo "arch=${arch_name}"
        echo "version=${VERSION}"
        echo "cmake=$(cmake --version | head -n 1)"
        echo "git_commit=$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        echo "definitions=${all_defs}"
        echo "log_file=${LOG_FILE}"
        echo "disabled_plugins=rocksdb,columnstore,s3,duckdb (nested submodules not checked out)"
        echo "disabled_features=wsrep (nested submodule not checked out)"
    } > "${out_base}/build-info.txt"

    log_line INFO "Artifacts saved to ${out_base}"
}

build_one() {
    platform_name="$1"
    arch_name="$2"
    extra_defs="$3"

    build_dir="${BUILD_ROOT}/${platform_name}/${arch_name}"
    stage_dir="${STAGE_ROOT}/${platform_name}-${arch_name}"
    rm -rf "${build_dir}" "${stage_dir}"
    mkdir -p "${build_dir}" "${stage_dir}"

    ssl_defs=$(ssl_defs_for "${platform_name}" "${arch_name}") || return 1
    defs="${COMMON_DEFS} $(rpath_defs_for "${platform_name}") ${ssl_defs} ${extra_defs}"

    log_line INFO "Configuring ${platform_name}/${arch_name}"
    # shellcheck disable=SC2086
    if ! run_and_log cmake -S "${ROOT_DIR}" -B "${build_dir}" ${defs}; then
        log_line ERROR "Configure failed for ${platform_name}/${arch_name}."
        return 1
    fi

    log_line INFO "Building ${platform_name}/${arch_name} (jobs=${JOBS})"
    if ! run_and_log cmake --build "${build_dir}" --config RelWithDebInfo -j "${JOBS}"; then
        log_line ERROR "Build failed for ${platform_name}/${arch_name}."
        return 1
    fi

    log_line INFO "Installing ${platform_name}/${arch_name}"
    if ! run_and_log cmake --install "${build_dir}" --prefix "${stage_dir}"; then
        log_line ERROR "cmake --install failed for ${platform_name}/${arch_name}."
        return 1
    fi

    collect_artifacts "${stage_dir}" "${platform_name}" "${arch_name}" "${defs}"
}

build_linux() {
    log_line INFO "Starting linux/x64 build"
    build_one linux x64 ""
}

build_mac() {
    log_line INFO "Starting mac/arm64 build"
    build_one mac arm64 "-DCMAKE_OSX_ARCHITECTURES=arm64"
}

build_windows() {
    log_line INFO "Starting windows/x64 build"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            log_line INFO "Native Windows host detected; using host MinGW-w64 toolchain directly."
            build_one windows x64 ""
            return $?
            ;;
    esac
    if [ -z "${WINDOWS_TOOLCHAIN_FILE:-}" ]; then
        log_line ERROR "WINDOWS_TOOLCHAIN_FILE is not set (required to cross-compile windows/x64 from a non-Windows host)."
        return 1
    fi
    [ -f "${WINDOWS_TOOLCHAIN_FILE}" ] || { log_line ERROR "WINDOWS_TOOLCHAIN_FILE does not exist: ${WINDOWS_TOOLCHAIN_FILE}"; return 1; }
    build_one windows x64 "-DCMAKE_TOOLCHAIN_FILE=${WINDOWS_TOOLCHAIN_FILE}"
}

failures=""
case "${PLATFORM}" in
    linux) build_linux || failures="${failures} linux/x64" ;;
    mac) build_mac || failures="${failures} mac/arm64" ;;
    windows) build_windows || failures="${failures} windows/x64" ;;
esac

if [ -n "${failures}" ]; then
    log_line ERROR "Build completed with failures:${failures}"
    log_line ERROR "See full details in ${LOG_FILE}"
    exit 1
fi

log_line INFO "Build completed successfully for: ${PLATFORM}"
log_line INFO "Release root: ${RELEASE_DIR}"
log_line INFO "Log file: ${LOG_FILE}"
