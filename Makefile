# Makefile for mirmid — an AI agent harness in Free Pascal / Lazarus.
FPC      ?= fpc
LAZBUILD ?= lazbuild
SRC      := src
TESTS    := tests
BUILD    := build
BIN      := bin
LIB      := $(BUILD)/lib
TESTLIB  := $(BUILD)/testlib

# Executable suffix: .exe on Windows.
ifeq ($(OS),Windows_NT)
EXEEXT := .exe
endif

APP      := $(BIN)/mirmid$(EXEEXT)
TESTAPP  := $(BIN)/testrunner$(EXEEXT)
FAKEMCP  := $(BIN)/fakemcp$(EXEEXT)
STREAMPROBE := $(BIN)/streamprobe$(EXEEXT)

# Windows x86_64 cross-build (needs the FPC win64 units).
WINBUILD := $(BUILD)/win64
WINBIN   := $(BIN)/win64
WINAPP   := $(WINBIN)/mirmid.exe

# Mandatory dependency: the tls library (Pascal TLS client and crypto
# primitives, https://github.com/svetodar/tls) — mirmid talks https through
# mirmid.tlsclient and cannot be built without it. The directory is taken from
# TLS_DIR; by default deps/tls (git submodule) is tried first, then the
# sibling directory ../tls.
# The tls directory is chosen by the presence of units: an empty deps/tls
# (uninitialised git submodule) must not shadow a working ../tls checkout.
TLSCANDIDATES ?= deps/tls ../tls
TLS_DIR  ?= $(firstword $(foreach d,$(TLSCANDIDATES),$(if $(wildcard $(d)/src/*.pas),$(d))))
TLSUNITS := $(wildcard $(TLS_DIR)/src/*.pas)
ifeq ($(strip $(TLSUNITS)),)
TLSFLAGS :=
else
TLSFLAGS := -Fu$(TLS_DIR)/src
endif

# Embedded trust roots (tls.roots): the unit $(TLS_DIR)/src/tls.roots.pas
# links the tlsroots.res resource via {$R ...}. The file is not in git — the
# tls library builds it with its own `roots` goal (rootsgen: certs/*.pem ->
# DER table + .rc, then fpcres -> .res), and `make clean` removes it. So that a
# build from a clean clone does not fail on {$R}, the resource is generated
# here too, reusing the library goal (the single source of truth for the table
# format). Requires fpcres from the FPC distribution; override with FPCRES=...
ROOTSRES := $(TLS_DIR)/src/tlsroots.res
FPCRES   ?= fpcres

# The resource dependency is only needed by the tls version that already has
# the tls.roots unit (it is the one that links {$R tlsroots.res}); an older
# library without it builds as before and needs no roots step.
ifneq ($(wildcard $(TLS_DIR)/src/tls.roots.pas),)
TLSROOTSDEP := $(ROOTSRES)
else
TLSROOTSDEP :=
endif

# Print the selected tls directory: build.sh prepares the resource and syncs
# the submodule exactly there, without duplicating the TLS_DIR selection logic.
tls-dir:
	@echo $(TLS_DIR)

.PHONY: tls-dir

# -O2 -gl: optimisation and debug info; -Fusrc: path to the project units.
FPCFLAGS := -O2 -gl -Fusrc $(TLSFLAGS)
# gmkdir — cross-platform mkdir -p shipped with FPC (in fpc's bin).
# On Unix, if gmkdir is not in PATH, fall back to mkdir -p.
ifeq ($(OS),Windows_NT)
GMKDIR := gmkdir -p
else
GMKDIR := $(shell command -v gmkdir 2>/dev/null)
ifeq ($(GMKDIR),)
GMKDIR := mkdir -p
endif
endif

all: app

app: $(APP)

$(APP): $(wildcard $(SRC)/*.pas) $(TLSUNITS) $(TLSROOTSDEP) $(SRC)/mirmid.lpr
	@$(GMKDIR) $(LIB) $(BIN)
	$(FPC) $(FPCFLAGS) -FU$(LIB) -FE$(BIN) $(SRC)/mirmid.lpr

test: $(TESTAPP) $(FAKEMCP) $(STREAMPROBE)
	$(TESTAPP) --all --format=plain

$(TESTAPP): $(wildcard $(TESTS)/*.pas) $(TESTS)/testrunner.lpr $(wildcard $(SRC)/*.pas) $(TLSUNITS) $(TLSROOTSDEP)
	@$(GMKDIR) $(TESTLIB) $(BIN)
	$(FPC) $(FPCFLAGS) -Fu$(TESTS) -FU$(TESTLIB) -FE$(BIN) $(TESTS)/testrunner.lpr

$(FAKEMCP): $(TESTS)/fixtures/fakemcp.pas
	@$(GMKDIR) $(TESTLIB) $(BIN)
	$(FPC) $(FPCFLAGS) -FU$(TESTLIB) -FE$(BIN) $(TESTS)/fixtures/fakemcp.pas

$(STREAMPROBE): $(TESTS)/fixtures/streamprobe.pas $(wildcard $(SRC)/*.pas)
	@$(GMKDIR) $(TESTLIB) $(BIN)
	$(FPC) $(FPCFLAGS) -FU$(TESTLIB) -FE$(BIN) $(TESTS)/fixtures/streamprobe.pas

# Embedded roots resource: the only external step is the `roots` goal of the
# tls library itself (rootsgen + fpcres), so the table format is defined in one
# place. That directory must contain a Makefile: a working ../tls and an
# initialised deps/tls have one, while an "empty" submodule never gets here —
# TLS_DIR is selected by the presence of src/*.pas.
$(ROOTSRES):
	@if [ ! -f "$(TLS_DIR)/Makefile" ]; then \
	  echo "ERROR: $(TLS_DIR)/Makefile not found — cannot build $(ROOTSRES)"; \
	  echo "       Point to the tls library directory: make TLS_DIR=../tls"; \
	  exit 1; \
	fi
	$(MAKE) -C $(TLS_DIR) roots FPCRES="$(FPCRES)"

# `roots` — the resource as a target of its own: build.sh and CI call it before
# a full build, and the same file is a prerequisite of every binary, so a plain
# `make app` / `make test` builds it too. Nothing to do in two cases: no tls
# checkout at all (a hard error — the binaries cannot be built either way) and
# an older tls without the tls.roots unit (it links no resource).
ifeq ($(strip $(TLS_DIR)),)
roots:
	@echo "ERROR: tls library not found (no src/*.pas in deps/tls or ../tls)"
	@echo "       Initialise the submodule: git submodule update --init deps/tls"
	@echo "       or point to it: make TLS_DIR=../tls"
	@exit 1
else
ifeq ($(strip $(TLSROOTSDEP)),)
roots:
	@echo "tls at $(TLS_DIR) has no tls.roots unit — no embedded roots to build"
else
roots: $(ROOTSRES)
	@echo "embedded roots resource: $(ROOTSRES)"
endif
endif

.PHONY: roots

run: app
	$(APP) $(ARGS)

lazbuild:
	$(LAZBUILD) mirmid.lpi

# Windows x86_64 cross-build: make win64 -> bin/win64/mirmid.exe.
# Requires an FPC with win64 target support and the win64 units installed
# (Debian/Ubuntu: fp-units-win-rtl, fp-units-win-base, fp-units-win-fcl,
# fp-units-win-net, fp-units-win-misc packages).
win64: $(WINAPP)

$(WINAPP): $(wildcard $(SRC)/*.pas) $(TLSUNITS) $(TLSROOTSDEP) $(SRC)/mirmid.lpr
	@$(GMKDIR) $(WINBUILD) $(WINBIN)
	$(FPC) $(FPCFLAGS) -Twin64 -FU$(WINBUILD) -FE$(WINBIN) $(SRC)/mirmid.lpr

clean:
	rm -rf $(BUILD) $(BIN)
	rm -f $(SRC)/*.o $(SRC)/*.ppu $(TESTS)/*.o $(TESTS)/*.ppu
	rm -f $(TESTS)/fixtures/*.o $(TESTS)/fixtures/*.ppu
