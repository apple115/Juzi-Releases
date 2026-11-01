#!/bin/sh
# Install or upgrade Juzi server binaries from a Juzi-Releases GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/apple115/Juzi-Releases/master/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/apple115/Juzi-Releases/master/install.sh | sh -s -- --remote
#
# The script installs juzi-server and juzi-remote for the current OS/arch,
# verifies SHA-256 and the embedded protocols, replaces the executable
# atomically, and hot-replaces running daemons through --handoff. Panes survive
# a handoff; use --no-restart to change files only.
set -eu

REPO=${JUZI_RELEASE_REPO:-apple115/Juzi-Releases}
PREFIX=${JUZI_PREFIX:-"$HOME/.local/bin"}
STABLE_REMOTE="$HOME/.local/share/juzi/bin/juzi-remote"
VERSION=${JUZI_VERSION:-}
TAG=""
RELEASE_BASE=${JUZI_RELEASE_BASE:-}
NO_RESTART=0
FORCE=0
DO_SERVER=0
DO_REMOTE=0
EXPLICIT_KIND=0

usage() {
	cat <<'EOF'
usage: install.sh [--server] [--remote] [--prefix DIR] [--version TAG]
                  [--no-restart] [--force]

  --server       install juzi-server only
  --remote       install juzi-remote only
  (neither)      install both
  --prefix DIR   binary directory (default ~/.local/bin)
  --version TAG  release tag such as v1.2.0 (default: latest)
  --no-restart   do not hand off running daemons
  --force        hand off even when the route protocol changed

Environment: JUZI_RELEASE_REPO, JUZI_VERSION, JUZI_PREFIX,
             JUZI_RELEASE_BASE (a local directory or file:// URL for testing)
EOF
	cat <<'EOF'

A remote-only upgrade through the bootstrap:
  curl -fsSL https://raw.githubusercontent.com/apple115/Juzi-Releases/master/install.sh |
    sh -s -- --remote
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--server) DO_SERVER=1; EXPLICIT_KIND=1 ;;
		--remote) DO_REMOTE=1; EXPLICIT_KIND=1 ;;
		--prefix) shift; [ $# -gt 0 ] || { usage >&2; exit 2; }; PREFIX=$1 ;;
		--prefix=*) PREFIX=${1#*=} ;;
		--version) shift; [ $# -gt 0 ] || { usage >&2; exit 2; }; VERSION=$1 ;;
		--version=*) VERSION=${1#*=} ;;
		--no-restart) NO_RESTART=1 ;;
		--force) FORCE=1 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "install.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done
if [ "$EXPLICIT_KIND" = 0 ]; then
	DO_SERVER=1
	DO_REMOTE=1
fi
if [ -n "$VERSION" ]; then
	VERSION=${VERSION#v}
	TAG=v$VERSION
fi

die() { echo "install.sh: $*" >&2; exit 1; }
warn() { echo "install.sh: $*" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/juzi-install.XXXXXX") || die "cannot create a temporary directory"
if [ "${JUZI_KEEP_TMP:-0}" = 1 ]; then
	echo "install.sh: temporary files kept in $TMP" >&2
else
	trap 'rm -rf "$TMP"' EXIT INT TERM
fi

case "$(uname -s)" in
	Linux) OS=linux ;;
	Darwin) OS=darwin ;;
	*) die "unsupported operating system: $(uname -s)" ;;
esac
case "$(uname -m)" in
	x86_64|amd64) ARCH=amd64 ;;
	aarch64|arm64) ARCH=arm64 ;;
	*) die "unsupported architecture: $(uname -m)" ;;
esac

if [ -n "$RELEASE_BASE" ]; then
	MODE=base
	RELEASE_BASE=${RELEASE_BASE%/}
else
	MODE=github
	API="https://api.github.com/repos/$REPO"
fi

fetch_url() {
	url=$1
	dst=$2
	accept=${3:-}
	if command -v curl >/dev/null 2>&1; then
		set -- -fsSL --retry 3 --connect-timeout 15
		if [ -n "${GITHUB_TOKEN:-}" ]; then
			set -- "$@" -H "Authorization: Bearer $GITHUB_TOKEN"
		fi
		if [ -n "$accept" ]; then
			set -- "$@" -H "Accept: $accept"
		fi
		curl "$@" -o "$dst" "$url"
	elif command -v wget >/dev/null 2>&1; then
		set --
		if [ -n "${GITHUB_TOKEN:-}" ]; then
			set -- "$@" --header="Authorization: Bearer $GITHUB_TOKEN"
		fi
		if [ -n "$accept" ]; then
			set -- "$@" --header="Accept: $accept"
		fi
		wget -q "$@" -O "$dst" "$url"
	else
		die "need curl or wget to download releases"
	fi
}

fetch() {
	src=$1
	dst=$2
	case "$RELEASE_BASE" in
		http://*|https://*) fetch_url "$RELEASE_BASE/$src" "$dst" ;;
		file://*) cp "${RELEASE_BASE#file://}/$src" "$dst" ;;
		*) cp "$RELEASE_BASE/$src" "$dst" ;;
	esac
}

# asset_id resolves a GitHub release asset name through api.github.com. The
# compact release JSON is split at each asset object so the URL stays adjacent
# to the name; no jq is required on a fresh remote host.
asset_id() {
	name=$1
	{ sed 's/{"url":"https:\/\/api.github.com\/repos\//\n&/g' "$TMP/github-release.json"; printf '\n'; } |
		while IFS= read -r line; do
			case "$line" in *"/releases/assets/"*) ;; *) continue ;; esac
			aname=$(printf '%s' "$line" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
			[ "$aname" = "$name" ] || continue
			id=$(printf '%s' "$line" | sed -n 's/.*releases\/assets\/\([0-9]*\)".*/\1/p')
			if [ -n "$id" ]; then
				printf '%s\n' "$id"
				break
			fi
		done
}

fetch_asset() {
	name=$1
	dst=$2
	if [ "$MODE" = base ]; then
		fetch "$name" "$dst"
		return
	fi
	id=$(asset_id "$name")
	[ -n "$id" ] || die "release has no asset $name"
	fetch_url "$API/releases/assets/$id" "$dst" "application/octet-stream"
}

json_string() {
	sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}
json_number() {
	sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$1" | head -n 1
}
hash_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d ' ' -f 1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d ' ' -f 1
	else
		die "need sha256sum or shasum"
	fi
}

echo "Downloading Juzi server release"
if [ "$MODE" = github ]; then
	if [ -n "$TAG" ]; then
		endpoint="$API/releases/tags/$TAG"
	else
		endpoint="$API/releases/latest"
	fi
	fetch_url "$endpoint" "$TMP/github-release.raw" "application/vnd.github+json" ||
		die "cannot read the GitHub release (rate limit? set GITHUB_TOKEN)"
	# GitHub pretty-prints this response. Asset lookup is line-oriented, so
	# strip all whitespace; only field names, URLs and asset names are read.
	tr -d '[:space:]' < "$TMP/github-release.raw" > "$TMP/github-release.json"
	RELEASE_TAG=$(sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' "$TMP/github-release.json" | head -n 1)
	[ -n "$RELEASE_TAG" ] || die "GitHub release has no tag"
	if [ -n "$TAG" ] && [ "$TAG" != "$RELEASE_TAG" ]; then
		die "requested $TAG but GitHub returned $RELEASE_TAG"
	fi
fi
fetch_asset release.json "$TMP/release.json" || die "release.json is missing"
fetch_asset SHA256SUMS "$TMP/SHA256SUMS" || die "SHA256SUMS is missing"
RELEASE_VERSION=$(json_string "$TMP/release.json" version)
RELEASE_TAG=$(json_string "$TMP/release.json" tag)
RELEASE_ROUTE=$(json_number "$TMP/release.json" routeVersion)
RELEASE_HANDOFF=$(json_number "$TMP/release.json" handoffVersion)
RELEASE_LAYOUT=$(json_number "$TMP/release.json" workspaceLayoutProtocol)
[ -n "$RELEASE_VERSION" ] || die "release.json has no version"
[ -n "$RELEASE_ROUTE" ] && [ -n "$RELEASE_HANDOFF" ] && [ -n "$RELEASE_LAYOUT" ] || die "release.json has no protocol versions"
if [ -n "$TAG" ] && [ -n "$RELEASE_TAG" ] && [ "$TAG" != "$RELEASE_TAG" ]; then
	die "requested $TAG but the release contains $RELEASE_TAG"
fi

verify_asset() {
	name=$1
	expected=$(awk -v n="$name" '$2 == n { print $1; exit }' "$TMP/SHA256SUMS")
	[ -n "$expected" ] || die "SHA256SUMS does not list $name"
	actual=$(hash_file "$TMP/$name")
	[ "$actual" = "$expected" ] || die "SHA-256 mismatch for $name"
}

verify_binary() {
	path=$1
	name=$2
	out=$("$path" --version 2>/dev/null) || die "$name cannot run on $OS/$ARCH"
	case "$out" in
		"$name $RELEASE_VERSION ("*) ;;
		*) die "$name reports '$out' (expected $RELEASE_VERSION)" ;;
	esac
	info=$("$path" --handoff-check 2>/dev/null) || die "$name has no handoff support"
	handoff=$(printf '%s\n' "$info" | sed -n 's/.*"handoffVersion":[[:space:]]*\([0-9]*\).*/\1/p')
	route=$(printf '%s\n' "$info" | sed -n 's/.*"routeVersion":[[:space:]]*\([0-9]*\).*/\1/p')
	[ "$handoff" = "$RELEASE_HANDOFF" ] || die "$name handoffVersion $handoff (expected $RELEASE_HANDOFF)"
	[ "$route" = "$RELEASE_ROUTE" ] || die "$name routeVersion $route (expected $RELEASE_ROUTE)"
	if [ "$name" = "juzi-remote" ]; then
		cap=$("$path" info 2>/dev/null) || die "$name info failed"
		protocol=$(printf '%s\n' "$cap" | sed -n 's/.*"protocol":[[:space:]]*"\([^"]*\)".*/\1/p')
		layout=$(printf '%s\n' "$cap" | sed -n 's/.*"workspaceLayoutProtocol":[[:space:]]*\([0-9]*\).*/\1/p')
		[ "$protocol" = "routed-remote-v1" ] || die "$name is not a routed remote backend"
		[ "$layout" = "$RELEASE_LAYOUT" ] || die "$name workspaceLayoutProtocol $layout (expected $RELEASE_LAYOUT)"
	fi
}

download_binary() {
	kind=$1
	name="$kind-$OS-$ARCH"
	fetch_asset "$name" "$TMP/$name" || die "cannot download $name"
	chmod 700 "$TMP/$name" || die "cannot make $name executable"
	verify_asset "$name"
	verify_binary "$TMP/$name" "$kind"
}

install_binary() {
	src=$1
	dest=$2
	dir=$(dirname "$dest")
	mkdir -p "$dir" || die "cannot create $dir"
	tmp="$dest.tmp.$$"
	cp "$src" "$tmp" || die "cannot write $tmp"
	chmod 700 "$tmp" || die "cannot chmod $tmp"
	if [ -f "$dest" ]; then
		cp -p "$dest" "$dest.previous" 2>/dev/null || true
	fi
	mv -f "$tmp" "$dest" || { rm -f "$tmp"; die "cannot replace $dest"; }
}

# Collect running daemons before replacing files, while their original
# executables are still present. Output is "kind<TAB>state<TAB>pid".
emit_daemon() {
	args=$1
	pid=${2:-}
	case "$args" in *--daemon*) ;; *) return 0 ;; esac
	kind=
	executable=
	for arg in $args; do
		case "${arg##*/}" in
			juzi-remote) kind=remote; executable=$arg; break ;;
			juzi-server) kind=server; executable=$arg; break ;;
		esac
	done
	[ -n "$kind" ] || return 0
	# Only touch a daemon that runs the binary this script is replacing. A
	# developer machine can have many unrelated test daemons; a broad scan used
	# to hand them all off.
	case "$kind" in
		server)
			[ "$DO_SERVER" = 1 ] || return 0
			[ "$executable" = "$PREFIX/juzi-server" ] || return 0
			;;
		remote)
			[ "$DO_REMOTE" = 1 ] || return 0
			case "$executable" in
				"$STABLE_REMOTE") ;;
				"$HOME"/.local/share/juzi/versions/*/juzi-remote) ;;
				*) return 0 ;;
			esac
			;;
	esac
	state=
	prev=
	for arg in $args; do
		case "$arg" in
			--state-dir=*|-state-dir=*) state=${arg#*=} ;;
		esac
		case "$prev" in
			--state-dir|-state-dir) state=$arg ;;
		esac
		prev=$arg
	done
	if [ -z "$state" ]; then
		if [ "$kind" = remote ]; then
			state="$HOME/.local/share/juzi/remote"
		elif [ "$OS" = darwin ]; then
			state="$HOME/Library/Application Support/Juzi/Daemon"
		else
			state="$HOME/.config/Juzi/Daemon"
		fi
	fi
	if [ -d "$state" ] && [ -S "$state/daemon.sock" ]; then
		# Capture the route protocol before files are replaced. After an
		# in-place replacement /proc/<pid>/exe points at a deleted inode.
		old_route=
		if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
			old_exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
			old_exe=${old_exe% (deleted)}
			if [ -n "$old_exe" ] && [ -x "$old_exe" ]; then
				old_route=$(route_version_of "$old_exe" || true)
			fi
		fi
		printf '%s\t%s\t%s\t%s\n' "$kind" "$state" "$pid" "$old_route"
	fi
}

collect_daemons() {
	out=$1
	: > "$out"
	if [ -d /proc/self ]; then
		for cmdline in /proc/[0-9]*/cmdline; do
			[ -r "$cmdline" ] || continue
			args=$(tr '\0' ' ' < "$cmdline" 2>/dev/null) || continue
			pid=${cmdline#/proc/}
			pid=${pid%/cmdline}
			emit_daemon "$args" "$pid" >> "$out" || true
		done
	else
		ps -axo pid=,args= 2>/dev/null | while IFS= read -r line; do
			set -- $line
			[ $# -gt 0 ] || continue
			pid=$1
			shift
			emit_daemon "$*" "$pid" >> "$out" || true
		done
	fi
	# One line per daemon; the PID only affects the route-version precheck.
	awk -F '\t' '!seen[$1 "\t" $2]++' "$out" > "$out.unique"
	mv "$out.unique" "$out"
}

route_version_of() {
	path=$1
	info=$("$path" --handoff-check 2>/dev/null) || return 1
	printf '%s\n' "$info" | sed -n 's/.*"routeVersion":[[:space:]]*\([0-9]*\).*/\1/p'
}

handoff_daemon() {
	kind=$1
	state=$2
	pid=$3
	old_route=$4
	newbin=$5
	if [ -n "$old_route" ] && [ "$old_route" != "$RELEASE_ROUTE" ] && [ "$FORCE" = 0 ]; then
		warn "route protocol $old_route -> $RELEASE_ROUTE differs; skipping $kind $state (update the Juzi App first, or pass --force)"
		return 0
	fi
	if out=$("$newbin" --handoff --state-dir "$state" --handoff-binary "$newbin" 2>&1); then
		echo "Hot-replaced $kind daemon: $state"
	else
		warn "could not hot-replace $kind daemon at $state: $out (the next start uses the new binary)"
	fi
}

DAEMONS="$TMP/daemons"
if [ "$NO_RESTART" = 0 ]; then
	collect_daemons "$DAEMONS"
fi

echo "Juzi server $RELEASE_VERSION ($OS/$ARCH)"
if [ "$DO_SERVER" = 1 ]; then
	download_binary juzi-server
fi
if [ "$DO_REMOTE" = 1 ]; then
	download_binary juzi-remote
fi

if [ "$DO_SERVER" = 1 ]; then
	install_binary "$TMP/juzi-server-$OS-$ARCH" "$PREFIX/juzi-server"
	echo "Installed $PREFIX/juzi-server"
fi
if [ "$DO_REMOTE" = 1 ]; then
	install_binary "$TMP/juzi-remote-$OS-$ARCH" "$PREFIX/juzi-remote"
	install_binary "$TMP/juzi-remote-$OS-$ARCH" "$STABLE_REMOTE"
	echo "Installed $PREFIX/juzi-remote and the stable remote channel $STABLE_REMOTE"
fi

if [ "$NO_RESTART" = 0 ]; then
	while IFS='	' read -r kind state pid old_route; do
		[ -n "$kind" ] || continue
		if [ "$kind" = server ] && [ "$DO_SERVER" = 0 ]; then
			continue
		fi
		if [ "$kind" = remote ] && [ "$DO_REMOTE" = 0 ]; then
			continue
		fi
		if [ "$kind" = server ]; then
			handoff_daemon "$kind" "$state" "$pid" "$old_route" "$PREFIX/juzi-server"
		else
			handoff_daemon "$kind" "$state" "$pid" "$old_route" "$STABLE_REMOTE"
		fi
	done < "$DAEMONS"
fi

if [ "$DO_SERVER" = 1 ] && [ "$DO_REMOTE" = 1 ]; then
	echo "Done. juzi-server and juzi-remote are available in $PREFIX."
elif [ "$DO_SERVER" = 1 ]; then
	echo "Done. juzi-server is available in $PREFIX."
else
	echo "Done. juzi-remote is available in $PREFIX."
fi
