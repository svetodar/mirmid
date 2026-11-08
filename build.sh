#!/usr/bin/env bash
# Build mirmid and run the unit-test suite.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v fpc >/dev/null 2>&1; then
  echo "ERROR: fpc compiler not found. Install Free Pascal / Lazarus." >&2
  exit 1
fi
if ! command -v make >/dev/null 2>&1; then
  echo "ERROR: make not found (package make / mingw32-make)." >&2
  exit 1
fi

# gmkdir ships with the FPC distribution but may be missing (for example in
# the Debian package). When it is absent, create a shim over mkdir -p.
if ! command -v gmkdir >/dev/null 2>&1; then
  shimdir="$(pwd)/build/.shim"
  mkdir -p "$shimdir"
  printf '#!/usr/bin/env bash\nexec mkdir -p "$@"\n' > "$shimdir/gmkdir"
  chmod +x "$shimdir/gmkdir"
  export PATH="$shimdir:$PATH"
fi

# tls object files in the build directories and the generated resource inside
# the submodule: after a revision change they must be dropped. FPC compares
# source and .ppu timestamps with one-second resolution, so a fast checkout
# followed by a build within the same second gives a false "up to date" and
# errors such as "idents no member".
reset_tls_outputs() {
  rm -f build/lib/tls.*.ppu build/lib/tls.*.o \
        build/testlib/tls.*.ppu build/testlib/tls.*.o \
        build/win64/tls.*.ppu build/win64/tls.*.o
  rm -f deps/tls/src/tls.*.ppu deps/tls/src/tls.*.o
  rm -f deps/tls/src/tlsroots.res
  rm -rf deps/tls/build/rootsgen
  rm -f deps/tls/bin/rootsgen
}

# The deps/tls submodule must be at the revision recorded in the mirmid index:
# an outdated revision lacks the tls.roottable/tls.roots units and the build
# fails with "Can't find unit tls.roottable". A clean submodule tree is
# fast-forwarded here (to a locally available commit, no network); a dirty one
# is left untouched with a warning only.
sync_tls_submodule() {
  [ -d deps/tls/src ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  local pinned current
  pinned="$(git ls-tree HEAD -- deps/tls 2>/dev/null | awk '{print $3}')"
  [ -n "$pinned" ] || return 0
  current="$(git -C deps/tls rev-parse HEAD 2>/dev/null)" || return 0
  [ "$pinned" = "$current" ] && return 0
  if [ -n "$(git -C deps/tls status --porcelain 2>/dev/null)" ]; then
    echo "Warning: deps/tls is at ${current:0:7}, expected ${pinned:0:7}," >&2
    echo "         but the submodule has local changes — leaving it as is." >&2
    return 0
  fi
  if git -C deps/tls cat-file -e "${pinned}^{commit}" 2>/dev/null; then
    echo "deps/tls: ${current:0:7} -> ${pinned:0:7} (revision pinned in the mirmid index)"
    git -C deps/tls checkout -q "$pinned"
    reset_tls_outputs
  else
    echo "Warning: deps/tls is at ${current:0:7}, expected ${pinned:0:7}," >&2
    echo "         but that revision is not available locally. Run:" >&2
    echo "         git submodule update --init deps/tls" >&2
  fi
}

sync_tls_submodule

# The tls directory is selected by the Makefile (deps/tls, then ../tls) — ask
# it, so the steps below use the same directory and do not duplicate the
# selection logic.
TLS_DIR="$(make -s --no-print-directory tls-dir)"
if [ -z "$TLS_DIR" ]; then
  echo "ERROR: tls library not found (no src/*.pas in deps/tls or ../tls)." >&2
  echo "       Initialise the submodule: git submodule update --init deps/tls" >&2
  echo "       or point to the directory: TLS_DIR=/path/to/tls ./build.sh" >&2
  exit 1
fi
export TLS_DIR

# mirmid.tlsclient uses tls.roottable directly: an old tls has no such unit and
# the build cannot succeed anyway — warn before fpc is called.
if [ ! -f "$TLS_DIR/src/tls.roottable.pas" ]; then
  echo "Warning: $TLS_DIR has no tls.roottable.pas — the tls library is outdated." >&2
  echo "         A revision with tls.roots is required; check deps/tls or set TLS_DIR." >&2
fi

# The embedded roots resource is built by the `roots` goal of the Makefile,
# which reuses the tls library goal (rootsgen + fpcres). On some builds
# rootsgen exits with an error after the resource has already been created: it
# reads ExitStatus before fpcres really exits (fixed in tls later). So success
# is checked by the file, not only by the exit code.
roots_res="$TLS_DIR/src/tlsroots.res"
if [ -f "$TLS_DIR/src/tls.roots.pas" ]; then
  roots_failed=0
  roots_out="$(make -s --no-print-directory roots \
    FPCRES="${FPCRES:-fpcres}" 2>&1)" || roots_failed=1
  if [ "$roots_failed" -eq 1 ] && [ -f "$roots_res" ]; then
    echo "Warning: the roots goal returned an error, but $roots_res exists"
    echo "         (known rootsgen/fpcres race in tls) — continuing the build."
  elif [ ! -f "$roots_res" ]; then
    printf '%s\n' "$roots_out" >&2
    echo "ERROR: could not build $roots_res." >&2
    exit 1
  fi
fi

make app
make test
echo
echo "Build finished: $(pwd)/bin/mirmid"
