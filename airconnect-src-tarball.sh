#!/bin/sh
set -eu

# version
if [ -n "${1:-}" ]; then
    VERSION="$1"
    echo "==> Using specified version: $VERSION"
else
    echo "==> Detecting latest release version from upstream..."
    VERSION="$(git ls-remote --tags --sort=-v:refname https://github.com/philippe44/AirConnect.git | awk -F'/' '!/\^\{\}/ {print $3; exit}')"
    if [ -z "$VERSION" ]; then
        VERSION="$(curl -sSL "https://api.github.com/repos/philippe44/AirConnect/releases/latest" 2>/dev/null | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')"
    fi
    if [ -z "$VERSION" ]; then
        echo "ERROR: Failed to detect latest version from git tags or API" >&2
        exit 1
    fi
    echo "==> Detected latest version: $VERSION"
fi

# output
OUTPUT="${2:-$PWD/AirConnect-${VERSION}-src.tar.xz}"

TMPDIR="$(mktemp -d /tmp/airconnect_build.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

ROOTDIR="$TMPDIR/AirConnect-$VERSION"

git_clone() {
    _retries=3
    while [ "$_retries" -gt 0 ]; do
        if git clone "$@"; then
            return 0
        fi
        _retries=$((_retries - 1))
        echo "Git clone failed, retrying in 2s ($_retries left)..." >&2
        sleep 2
    done
    return 1
}

git_fetch_commit() {
    _dest="$1"
    _url="$2"
    _commit="$3"
    _keep_git="$4"
    shift 4

    mkdir -p "$_dest"
    (
        cd "$_dest"
        git init -q
        git remote add origin "$_url"
        if [ "$#" -gt 0 ]; then
            git config core.sparseCheckout true
            git sparse-checkout init --no-cone
            git sparse-checkout set "$@"
            _fetch_cmd="git fetch --depth 1 --filter=blob:none origin $_commit"
        else
            _fetch_cmd="git fetch --depth 1 origin $_commit"
        fi

        _retries=3
        while [ "$_retries" -gt 0 ]; do
            if eval "$_fetch_cmd"; then
                break
            fi
            _retries=$((_retries - 1))
            echo "Git fetch failed, retrying in 2s ($_retries left)..." >&2
            sleep 2
        done
        if [ "$_retries" -eq 0 ]; then
            echo "ERROR: Failed to fetch $_commit from $_url" >&2
            exit 1
        fi

        git checkout -q FETCH_HEAD
        if [ "$_keep_git" -ne 1 ]; then
            rm -rf .git
        fi
    )
}

get_submodule_commit() {
    _tree="$1"
    _path="$2"
    _commit="$(git -C "$_tree" ls-tree HEAD "$_path" 2>/dev/null | awk '{print $3}')"
    if [ -z "$_commit" ]; then
        echo "ERROR: Could not resolve submodule commit for $_path" >&2
        exit 1
    fi
    echo "$_commit"
}

echo "==> Fetching AirConnect ($VERSION)..."
git_clone --depth 1 --filter=blob:none --branch "$VERSION" --no-checkout \
    https://github.com/philippe44/AirConnect.git "$ROOTDIR"

(
    cd "$ROOTDIR"
    git sparse-checkout init --no-cone
    git sparse-checkout set '/*' '!/*.zip' '!/bin'
    git checkout "$VERSION"
)
MTIME="$(git -C "$ROOTDIR" log -1 --format=%ct "$VERSION" 2>/dev/null || echo 1727373960)"

echo "==> Resolving pinned submodule commits from AirConnect ($VERSION)..."
COMMIT_CROSSTOOLS="$(get_submodule_commit "$ROOTDIR" common/crosstools)"
COMMIT_DMAP="$(get_submodule_commit "$ROOTDIR" common/dmap-parser)"
COMMIT_CODECS="$(get_submodule_commit "$ROOTDIR" common/libcodecs)"
COMMIT_MDNS="$(get_submodule_commit "$ROOTDIR" common/libmdns)"
COMMIT_PUPNP="$(get_submodule_commit "$ROOTDIR" common/libpupnp)"
COMMIT_RAOP="$(get_submodule_commit "$ROOTDIR" common/libraop)"
COMMIT_NANOPB="$(get_submodule_commit "$ROOTDIR" aircast/nanopb)"

rm -rf "$ROOTDIR/.git"

echo "==> Fetching submodules at pinned commits..."

# crosstools
git_fetch_commit "$ROOTDIR/common/crosstools" "https://github.com/philippe44/crosstools.git" "$COMMIT_CROSSTOOLS" 0
sed -i '/#include <sys\/poll.h>/d' "$ROOTDIR/common/crosstools/src/platform.h"

# dmap-parser
git_fetch_commit "$ROOTDIR/common/dmap-parser" "https://github.com/philippe44/dmap-parser.git" "$COMMIT_DMAP" 0

# libcodecs - NO_FAAC
git_fetch_commit "$ROOTDIR/common/libcodecs" "https://github.com/philippe44/libcodecs.git" "$COMMIT_CODECS" 0 '/*' '!/targets'
patch -p1 -d "$ROOTDIR/common/libcodecs" << 'EOF'
--- a/addons/encoder.c
+++ b/addons/encoder.c
@@ -14,7 +14,9 @@
 
 #include "FLAC/stream_encoder.h"
 #include "layer3.h"
+#ifndef NO_FAAC
 #include "faac.h"
+#endif
 
 #include "encoder.h"
 
@@ -151,6 +153,9 @@ static bool mp3_open(struct encoder_s* encoder) {
 
 /*---------------------------------------------------------------------------*/
 static bool aac_open(struct encoder_s* encoder) {
+#ifdef NO_FAAC
+	return false;
+#else
 	encoder->codec = (void*)faacEncOpen(encoder->sample_rate, 2, &encoder->aac.in_samples, &encoder->aac.out_max_bytes);
 	if (!encoder->codec) return false;
 
@@ -167,6 +172,7 @@ static bool aac_open(struct encoder_s* encoder) {
 	faacEncSetConfiguration(encoder->codec, format);
 
 	return true;
+#endif
 }
 
 /*---------------------------------------------------------------------------*/
@@ -187,8 +193,10 @@ static void mp3_close(struct encoder_s* encoder) {
 
 /*---------------------------------------------------------------------------*/
 static void aac_close(struct encoder_s* encoder) {
+#ifndef NO_FAAC
 	faacEncEncode(encoder->codec, NULL, 0, encoder->data, encoder->aac.out_max_bytes);
 	faacEncClose(encoder->codec);
+#endif
 }
 
 /*---------------------------------------------------------------------------*/
@@ -231,6 +239,10 @@ static uint8_t* mp3_encode(struct encoder_s* encoder, int16_t* pcm, size_t frame
 
 /*---------------------------------------------------------------------------*/
 static uint8_t* aac_encode(struct encoder_s* encoder, int16_t* pcm, size_t frames, size_t* bytes) {
+#ifdef NO_FAAC
+	*bytes = 0;
+	return NULL;
+#else
 	memcpy(encoder->buffer + encoder->count * 2, pcm, frames * 4);
 	encoder->count += frames;
 	*bytes = 0;
@@ -245,6 +257,7 @@ static uint8_t* aac_encode(struct encoder_s* encoder, int16_t* pcm, size_t frame
 	}
 
 	return encoder->data;
+#endif
 }
 
 /*---------------------------------------------------------------------------*/
EOF

# libmdns
git_fetch_commit "$ROOTDIR/common/libmdns" "https://github.com/philippe44/libmdns.git" "$COMMIT_MDNS" 1 '/*' '!/targets' '!/bin'
COMMIT_MDNSSD="$(get_submodule_commit "$ROOTDIR/common/libmdns" mdnssd)"
COMMIT_MDNSSVC="$(get_submodule_commit "$ROOTDIR/common/libmdns" mdnssvc)"
rm -rf "$ROOTDIR/common/libmdns/.git"

git_fetch_commit "$ROOTDIR/common/libmdns/mdnssd" "https://github.com/philippe44/mdnssd.git" "$COMMIT_MDNSSD" 0 '/*' '!/bin'
git_fetch_commit "$ROOTDIR/common/libmdns/mdnssvc" "https://github.com/philippe44/mdnssvc.git" "$COMMIT_MDNSSVC" 0 '/*' '!/bin'

# libpupnp - upnpdebug.h
git_fetch_commit "$ROOTDIR/common/libpupnp" "https://github.com/philippe44/libpupnp.git" "$COMMIT_PUPNP" 0 '/*' '!/targets/*' '/targets/linux/x86_64/include/upnp/upnpdebug.h'
if [ -f "$ROOTDIR/common/libpupnp/targets/linux/x86_64/include/upnp/upnpdebug.h" ]; then
    cp "$ROOTDIR/common/libpupnp/targets/linux/x86_64/include/upnp/upnpdebug.h" "$ROOTDIR/common/libpupnp/addons/upnpdebug.h"
fi
rm -rf "$ROOTDIR/common/libpupnp/targets"

# libraop
git_fetch_commit "$ROOTDIR/common/libraop" "https://github.com/philippe44/libraop.git" "$COMMIT_RAOP" 0 '/*' '!/targets' '!/bin'

# nanopb
git_fetch_commit "$ROOTDIR/aircast/nanopb" "https://github.com/nanopb/nanopb.git" "$COMMIT_NANOPB" 0

# remove upstream build scripts and updater
rm -f "$ROOTDIR"/build.cmd "$ROOTDIR"/build.sh "$ROOTDIR"/buildall.sh "$ROOTDIR"/updater

echo "==> Creating Makefile..."
cat << 'EOF' > "$ROOTDIR/Makefile"
CC ?= gcc
CFLAGS ?= -O2 -Wall
LDFLAGS ?=

BINDIR ?= bin
BUILD_DIR ?= build

COMMON_DIR = common
AIRUPNP_DIR = airupnp
AIRCAST_DIR = aircast

INCLUDES = \
	-I$(COMMON_DIR) \
	-I$(COMMON_DIR)/crosstools/src \
	-I$(COMMON_DIR)/dmap-parser \
	-I$(COMMON_DIR)/libmdns/mdnssvc \
	-I$(COMMON_DIR)/libmdns/mdnssd \
	-I$(COMMON_DIR)/libraop/src \
	-I$(COMMON_DIR)/libpupnp/addons \
	-I$(COMMON_DIR)/libcodecs/addons \
	-I$(AIRUPNP_DIR)/src \
	-I$(AIRCAST_DIR)/src \
	-I$(AIRCAST_DIR)/nanopb

DEFINES = \
	-D_GNU_SOURCE \
	-DNDEBUG \
	-DNO_FAAC \
	-D_FILE_OFFSET_BITS=64 \
	-DPB_FIELD_16BIT \
	-Wno-format-truncation \
	-Wno-stringop-truncation

# sources
COMMON_SRCS = \
	$(wildcard $(COMMON_DIR)/crosstools/src/*.c) \
	$(wildcard $(COMMON_DIR)/dmap-parser/dmap_parser.c) \
	$(filter-out %climdnssd.c,$(wildcard $(COMMON_DIR)/libmdns/mdnssd/*.c)) \
	$(filter-out %climdnssvc.c,$(wildcard $(COMMON_DIR)/libmdns/mdnssvc/*.c)) \
	$(wildcard $(COMMON_DIR)/libpupnp/addons/*.c) \
	$(wildcard $(COMMON_DIR)/libcodecs/addons/encoder.c) \
	$(COMMON_DIR)/libraop/src/raop_server.c \
	$(COMMON_DIR)/libraop/src/raop_streamer.c \
	$(COMMON_DIR)/libraop/src/alac.c

AIRUPNP_SRCS = $(wildcard $(AIRUPNP_DIR)/src/*.c)
AIRCAST_SRCS = $(wildcard $(AIRCAST_DIR)/src/*.c) $(wildcard $(AIRCAST_DIR)/nanopb/*.c)

SHARED_OBJS = $(patsubst %.c,$(BUILD_DIR)/%.o,$(COMMON_SRCS))
AIRUPNP_OBJS = $(patsubst %.c,$(BUILD_DIR)/%.o,$(AIRUPNP_SRCS)) $(SHARED_OBJS)
AIRCAST_OBJS = $(patsubst %.c,$(BUILD_DIR)/%.o,$(AIRCAST_SRCS)) $(SHARED_OBJS)

AIRUPNP_LIBS = -lupnp -lixml -lssl -lcrypto -lFLAC -lshine -lpthread -lm
AIRCAST_LIBS = -lupnp -lixml -ljansson -lssl -lcrypto -lFLAC -lshine -lpthread -lm

all: $(BINDIR)/airupnp $(BINDIR)/aircast

$(BUILD_DIR)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(DEFINES) $(INCLUDES) -c $< -o $@

$(BINDIR)/airupnp: $(AIRUPNP_OBJS)
	@mkdir -p $(BINDIR)
	$(CC) $(AIRUPNP_OBJS) $(LDFLAGS) $(AIRUPNP_LIBS) -o $@

$(BINDIR)/aircast: $(AIRCAST_OBJS)
	@mkdir -p $(BINDIR)
	$(CC) $(AIRCAST_OBJS) $(LDFLAGS) $(AIRCAST_LIBS) -o $@

clean:
	rm -rf $(BUILD_DIR) $(BINDIR)/airupnp $(BINDIR)/aircast

.PHONY: all clean
EOF

echo "==> Packing source tarball (xz)..."
mkdir -p "$(dirname "$OUTPUT")"

TAR_OPTS="--exclude=targets --exclude=bin --exclude=build --exclude=*.orig --exclude=*.rej --exclude=.git --exclude=build.cmd --exclude=build.sh --exclude=buildall.sh --exclude=updater"
if tar --help 2>&1 | grep -q -- '--sort='; then
    tar --sort=name --mtime="@$MTIME" --owner=0 --group=0 --numeric-owner \
        $TAR_OPTS -cf - -C "$TMPDIR" "AirConnect-$VERSION" | xz -c > "$OUTPUT"
else
    tar $TAR_OPTS -c -C "$TMPDIR" "AirConnect-$VERSION" | xz -c > "$OUTPUT"
fi

HASH="$(sha256sum "$OUTPUT" | cut -d' ' -f1)"
SIZE="$(du -h "$OUTPUT" | cut -f1)"

echo "$HASH  $(basename "$OUTPUT")" > "${OUTPUT}.sha256"

echo "==> Successfully generated: $OUTPUT ($SIZE)"
echo "==> Checksum file: ${OUTPUT}.sha256"
echo "==> SHA256: $HASH"
echo "==> OpenWrt Makefile PKG_HASH: PKG_HASH:=$HASH"
