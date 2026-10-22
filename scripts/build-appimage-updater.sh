#!/usr/bin/env bash
# Ordinary/package builds need only the C bridge. AppImage release builds also
# build the pinned updater and bundle its runtime closure for detached apply.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-helper}"
OUT="${2:-$HERE/build}"
mkdir -p "$OUT"
read -r -a CC_COMMAND <<< "${CC:-cc}"
read -r -a AR_COMMAND <<< "${AR:-ar}"
read -r -a EXTRA_FLAGS <<< "${CFLAGS:-}"
"${CC_COMMAND[@]}" -std=c11 -O2 -fPIC -pthread "${EXTRA_FLAGS[@]}" -c "$HERE/app/appimage_update_client.c" -o "$OUT/appimage_update_client.o"
"${AR_COMMAND[@]}" rcs "$OUT/libwnappimage.a" "$OUT/appimage_update_client.o"
if [[ "$MODE" == bridge ]]; then exit 0; fi
if [[ "$MODE" != helper ]]; then printf 'Usage: %s [bridge|helper] [out-dir]\n' "$0" >&2; exit 2; fi

SOURCE="$HERE/vendor/appimage-updater"
WORK="$OUT/appimage-updater-build"
PREFIX="$WORK/prefix"
mkdir -p "$SOURCE" "$WORK"
pin() {
  local name="$1" key equals value
  while read -r key equals value; do
    if [[ "$key" == "$name-commit" && "$equals" == = ]]; then printf '%s\n' "$value"; return; fi
  done < "$HERE/DEPS_PIN"
  printf 'Missing %s-commit pin\n' "$name" >&2; return 1
}
checkout() {
  local name="$1" repo="$2" revision dir
  revision="$(pin "$name")"
  [[ "$revision" =~ ^[a-f0-9]{40}$ ]] || { printf 'Invalid %s pin\n' "$name" >&2; return 1; }
  dir="$SOURCE/$name"
  if [[ ! -d "$dir/.git" ]]; then git init -q "$dir"; git -C "$dir" remote add origin "https://github.com/$repo.git"; fi
  if ! git -C "$dir" cat-file -e "$revision^{commit}" 2>/dev/null; then git -C "$dir" fetch --depth=1 origin "$revision"; fi
  git -C "$dir" checkout --detach "$revision"
  git -C "$dir" submodule update --init --recursive --depth=1
}
checkout appimageupdate AppImageCommunity/AppImageUpdate
checkout appimageupdate-zsync2 AppImageCommunity/zsync2
checkout appimageupdate-libappimage AppImageCommunity/libappimage
checkout appimageupdate-cpr libcpr/cpr
checkout appimageupdate-args Taywee/args
checkout appimageupdate-xdgutils AppImageCommunity/xdg-utils-cxx
# The pinned validator otherwise loops forever on multiple signatures and
# passes a non-NUL-terminated vector to mkdtemp. Keep the minimal patch local.
SAFETY_PATCH="$HERE/scripts/appimage-updater/upstream-safety.patch"
if ! git -C "$SOURCE/appimageupdate" apply --reverse --check "$SAFETY_PATCH" 2>/dev/null; then
  git -C "$SOURCE/appimageupdate" apply --check "$SAFETY_PATCH"
  git -C "$SOURCE/appimageupdate" apply "$SAFETY_PATCH"
fi
ZSYNC_PATCH="$HERE/scripts/appimage-updater/zsync-types.patch"
if ! git -C "$SOURCE/appimageupdate-zsync2" apply --reverse --check "$ZSYNC_PATCH" 2>/dev/null; then
  git -C "$SOURCE/appimageupdate-zsync2" apply --check "$ZSYNC_PATCH"
  git -C "$SOURCE/appimageupdate-zsync2" apply "$ZSYNC_PATCH"
fi
# libappimage otherwise downloads xdg-utils-cxx master. Install our pinned copy
# to a private prefix and make the upstream build use that package instead.
cmake -S "$SOURCE/appimageupdate-xdgutils" -B "$WORK/xdg" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$WORK/xdg" --parallel "${JOBS:-2}"
cmake --install "$WORK/xdg"
cmake -S "$HERE/scripts/appimage-updater" -B "$WORK/helper" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_PREFIX_PATH="$PREFIX" -DWN_UPDATER_SOURCE="$SOURCE/appimageupdate" \
  -DFETCHCONTENT_SOURCE_DIR_ZSYNC2="$SOURCE/appimageupdate-zsync2" \
  -DFETCHCONTENT_SOURCE_DIR_LIBAPPIMAGE="$SOURCE/appimageupdate-libappimage" \
  -DFETCHCONTENT_SOURCE_DIR_CPR="$SOURCE/appimageupdate-cpr" \
  -DFETCHCONTENT_SOURCE_DIR_ARGS="$SOURCE/appimageupdate-args"
cmake --build "$WORK/helper" --target squashfuse-EXTERNAL --parallel "${JOBS:-2}"
cmake --build "$WORK/helper" --target wn-appimage-update --parallel "${JOBS:-2}"
cp "$WORK/helper/wn-appimage-update" "$OUT/wn-appimage-update"
LIBS="$OUT/appimage-update-lib"
rm -rf "$LIBS"
mkdir -p "$LIBS"
cp -L "$(command -v gpg)" "$LIBS/gpg"
for repository in "$SOURCE"/*; do
  for license in "$repository"/LICENSE* "$repository"/COPYING* "$repository"/Copyright* "$repository"/lib/*/LICENSE* "$repository"/lib/*/COPYING*; do
    [[ -f "$license" ]] || continue
    cp "$license" "$LIBS/LICENSE.$(basename "$repository").$(basename "$(dirname "$license")").$(basename "$license")"
  done
done
sqfs_license="$(find "$WORK" -type f -path '*/squashfuse*/LICENSE' -print -quit)"
test -n "$sqfs_license"
cp "$sqfs_license" "$LIBS/LICENSE.squashfuse"
copy_system_license() {
  local binary="$1" package record
  if command -v dpkg-query >/dev/null; then
    while IFS= read -r record; do
      package="${record%%: /*}"
      [[ -n "$package" ]] || continue
      if [[ -f "/usr/share/doc/$package/copyright" ]]; then
        cp "/usr/share/doc/$package/copyright" "$LIBS/LICENSE.$package"
      elif [[ -f "/usr/share/doc/${package%%:*}/copyright" ]]; then
        cp "/usr/share/doc/${package%%:*}/copyright" "$LIBS/LICENSE.${package%%:*}"
      fi
    done <<< "$(dpkg-query -S "$binary" 2>/dev/null || true)"
  elif command -v pacman >/dev/null; then
    package="$(pacman -Qoq "$binary" 2>/dev/null || true)"
    [[ -n "$package" ]] || return 0
    for record in "/usr/share/licenses/$package"/*; do
      [[ -f "$record" ]] || continue
      cp -L "$record" "$LIBS/LICENSE.$package.$(basename "$record")"
    done
  fi
}
copy_system_license "$(command -v gpg)"
for license in /usr/share/common-licenses/{GPL-2,GPL-3,LGPL-2,LGPL-2.1,LGPL-3} /usr/share/licenses/common/{GPL2,GPL3,LGPL2,LGPL2.1,LGPL3}/*; do
  [[ -f "$license" ]] || continue
  cp -L "$license" "$LIBS/LICENSE.common.$(basename "$(dirname "$license")").$(basename "$license")"
done
# Use ldd's loader-resolved transitive closure, copying real files rather than
# symlinks: the runtime stages them O_NOFOLLOW outside the AppImage mount.
# Never bundle glibc/the loader: mixing those with the host breaks execution.
for executable in "$WORK/helper/wn-appimage-update" "$LIBS/gpg"; do
  while read -r name arrow resolved remainder; do
    if [[ "$arrow" == '=>' && "$resolved" == 'not' ]]; then printf 'Missing library: %s\n' "$name" >&2; exit 1; fi
    [[ "$arrow" == '=>' && "$resolved" == /* ]] || continue
    name="${name##*/}"
    case "$name" in
      libc.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libm.so.*|libmvec.so.*|\
      libutil.so.*|libanl.so.*|libresolv.so.*|libnss_*|libnsl.so.1|\
      libBrokenLocale.so.*|libthread_db.so.*|ld-linux*) continue;;
    esac
    cp -L "$resolved" "$LIBS/$name"
    copy_system_license "$resolved"
  done < <(ldd "$executable")
done
# libappimageupdate is linked from the build tree: set the packaged binary's
# lookup path independently of that tree. LD_LIBRARY_PATH switches to the
# private staged lib directory when the helper is detached.
patchelf --set-rpath '$ORIGIN/appimage-update-lib' "$OUT/wn-appimage-update"
