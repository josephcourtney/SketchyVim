VERSION = "1.0.11"
CC = clang
DEFINES = -DHAVE_CONFIG_H -DMACOS_X -DMACOS_X_DARWIN # -DMANUAL_AX -DGUI_MOVES
LIBS = lib/libvim.a -lm -lncurses -liconv -framework Carbon -framework Cocoa
WARN_FLAGS = -Wall -Wno-array-bounds \
	     -Wno-unknown-warning-option \
	     -Wno-cpp -Wno-pointer-sign \
	     -Wno-unused-parameter \
	     -Wno-strict-overflow \
	     -Wno-return-type -Werror
CFLAGS = $(WARN_FLAGS) $(DEFINES) -g -Ilib -Ilib/libvim/proto -std=c99 -O2 #-fsanitize=address -fsanitize=undefined

# libvim vendors an older Vim configure script. Modern Clang emits warnings for
# several of its feature probes; treating those warnings as errors makes the
# probes incorrectly report that C99, ncurses, const, volatile, etc. are
# unavailable. Keep SketchyVim's -Werror build, but use compatibility flags for
# the vendored library.
LIBVIM_CFLAGS = $(DEFINES) -g -Iproto -std=c99 -O2 \
	-Wno-error=implicit-function-declaration \
	-Wno-error=implicit-int \
	-Wno-error=int-conversion \
	-Wno-error=incompatible-function-pointer-types \
	-Wno-error=deprecated-non-prototype \
	-Wno-error=implicit-int-float-conversion

ODIR = bin
SRC = src

_OBJ = helpers.om workspace.om event_tap.o ax.o buffer.o line.o env_vars.o
OBJ = $(patsubst %, $(ODIR)/%, $(_OBJ))

.PHONY: all x86 arm64 universal sign lib lib-clean clean distclean

all: $(ODIR)/svim

x86: CFLAGS = $(WARN_FLAGS) $(DEFINES) -g -Ilib -Ilib/libvim/proto -std=c99 -O2 -target x86_64-apple-macos12.0
x86: $(ODIR)/svim
	mv $(ODIR)/svim $(ODIR)/svim_x86
	rm -rf $(ODIR)/*.o
	rm -rf $(ODIR)/*.om

arm64: CFLAGS = $(WARN_FLAGS) $(DEFINES) -g -Ilib -Ilib/libvim/proto -std=c99 -O2 -target arm64-apple-macos12.0
arm64: $(ODIR)/svim
	mv $(ODIR)/svim $(ODIR)/svim_arm64
	rm -rf $(ODIR)/*.o
	rm -rf $(ODIR)/*.om

universal:
	$(MAKE) x86
	$(MAKE) arm64
	lipo -create -output $(ODIR)/svim $(ODIR)/svim_x86 $(ODIR)/svim_arm64

sign:
	$(MAKE) universal
	codesign -fs 'svim-cert' $(ODIR)/svim

bundle: clean
	$(MAKE) sign
	@mkdir bundle
	cp $(ODIR)/svim bundle/
	cp -r examples/ bundle/
	tar -czf bundle_$(VERSION).tgz bundle/
	rm -rf bundle/

lib: lib/libvim.a

lib/libvim.a:
	git submodule update --init --recursive
	rm -f libvim/src/auto/config.cache libvim/src/auto/config.mk libvim/src/auto/config.h
	$(MAKE) -C libvim/src CFLAGS='$(LIBVIM_CFLAGS)'
	cp libvim/src/libvim.a lib/libvim.a

$(ODIR)/svim: lib/libvim.a $(SRC)/main.m $(OBJ) | $(ODIR)
	$(CC) $(CFLAGS) $(SRC)/main.m $(OBJ) -o $@ $(LIBS)

$(ODIR)/%.o: $(SRC)/%.c $(SRC)/%.h | $(ODIR)
	$(CC) -c -o $@ $< $(CFLAGS)

$(ODIR)/%.om: $(SRC)/%.m $(SRC)/%.h | $(ODIR)
	$(CC) -c -o $@ $< $(CFLAGS)

$(ODIR):
	mkdir $(ODIR)

lib-clean:
	-$(MAKE) -C libvim/src distclean
	rm -f lib/libvim.a
	rm -f libvim/src/auto/config.cache libvim/src/auto/config.mk libvim/src/auto/config.h

clean:
	rm -rf $(ODIR)

distclean: clean lib-clean
