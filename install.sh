#!/bin/bash
# Build Bytemeter.app from this folder and install it. Safe to run again after
# pulling changes: it stops the running copy, replaces the app and reloads it.
#
#   ./install.sh                     build, install to ~/Applications, start at login
#   ./install.sh --app PATH          install that Bytemeter.app, already built, instead
#   ./install.sh --bundle-only DIR   build and sign Bytemeter.app into DIR, nothing else
#   ./install.sh --uninstall         stop it and move it to the Bin (your data is kept)
#   ./install.sh --dry-run           say what would happen and change nothing
#   ./install.sh --disable-sandbox   passed to swift build, for building inside
#                                    another sandbox such as Homebrew's
#
# --dry-run works with every other option. Needs macOS 13 or later, and to
# build, the Xcode command line tools: xcode-select --install
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
NAME="Bytemeter"
LABEL="io.github.adi-debug-source.bytemeter"
APP="$HOME/Applications/$NAME.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGS="$HOME/Library/Logs/$NAME"
DATA="$HOME/Library/Application Support/$NAME"
JOB="gui/$UID/$LABEL"
# The app's binary wherever its bundle lives. Arguments are not allowed after
# it, so a one-off "Bytemeter --dashboard" run is never mistaken for the app.
RUNNING='Bytemeter\.app/Contents/MacOS/Bytemeter$'

say() { printf '  %s\n' "$1"; }
die() { printf '  %s\n' "$1" >&2; exit 1; }

to_bin() {  # move, never delete, so anything removed can be put back
    [ -e "$1" ] || return 0
    local name dest
    name="$(basename "$1")"
    dest="$HOME/.Trash/$name"
    [ -e "$dest" ] && dest="$HOME/.Trash/$name $(date +%H%M%S)"
    mkdir -p "$HOME/.Trash"
    mv "$1" "$dest"
}

needs_value() {  # $1 = option, $2 = what follows it, $3 = an example
    case "${2:-}" in
        ""|-*) echo "$1 needs a path, for example: ./install.sh $1 $3"; exit 2 ;;
    esac
}

MODE=install
OUT=""
FROM=""
DRY=0
SANDBOX=""
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle-only)
            needs_value "$1" "${2:-}" dist
            [ "$MODE" = install ] || { echo "choose one of --bundle-only and --uninstall"; exit 2; }
            MODE=bundle
            OUT="$2"
            shift ;;
        --app)
            needs_value "$1" "${2:-}" dist/Bytemeter.app
            FROM="$2"
            shift ;;
        --uninstall)
            [ "$MODE" = install ] || { echo "choose one of --bundle-only and --uninstall"; exit 2; }
            MODE=uninstall ;;
        --dry-run) DRY=1 ;;
        --disable-sandbox) SANDBOX="--disable-sandbox" ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $1 (try --help)"; exit 2 ;;
    esac
    shift
done
if [ "$MODE" = bundle ] && [ -n "$FROM" ]; then
    echo "--app installs a bundle that is already built and --bundle-only builds one. Choose one."
    exit 2
fi
# Paths given relative to where the script was run from.
case "$OUT" in ""|/*) ;; *) OUT="$PWD/$OUT" ;; esac
case "$FROM" in ""|/*) ;; *) FROM="$PWD/$FROM" ;; esac

# One step. In a dry run it only says what it would do. For real it runs the
# command, then says what it did. $1 = would, $2 = did, the rest = the command.
step() {
    local would="$1" did="$2"
    shift 2
    if [ "$DRY" = 1 ]; then
        say "would $would"
    else
        "$@"
        [ -n "$did" ] && say "$did"
    fi
    return 0
}

agent_loaded() { launchctl print "$JOB" >/dev/null 2>&1; }
running_pid() { pgrep -U "$UID" -f "$RUNNING" 2>/dev/null | head -n 1; }

# Stop the copy launchd runs and any copy opened by hand, and wait until both
# are gone. A bootout, not a kill: with launchd still holding the job, a killed
# copy counts as a crash and is started again within ten seconds.
stop_running() {
    # Both can fail harmlessly: bootout sometimes reports an error while it is
    # still unloading, and pkill fails when there is nothing to stop. The loop
    # below is the real check.
    if agent_loaded; then launchctl bootout "$JOB" 2>/dev/null || true; fi
    pkill -U "$UID" -f "$RUNNING" 2>/dev/null || true
    local tries=0
    while agent_loaded || [ -n "$(running_pid)" ]; do
        tries=$((tries + 1))
        [ "$tries" -gt 20 ] && die "Bytemeter did not stop within 10 seconds. Quit it from its menu, then run this again."
        sleep 0.5
    done
    return 0
}

say_stop_plan() {  # what stopping means right now, in either mode
    local pid
    pid="$(running_pid)"
    if agent_loaded; then
        step "stop and unload the launchd job $JOB" "stopped the launchd job $JOB" stop_running
    elif [ -n "$pid" ]; then
        step "stop the copy that is running (pid $pid)" "stopped the copy that was running" stop_running
    else
        say "nothing running to stop"
    fi
}

# ----------------------------------------------------------------- uninstall

if [ "$MODE" = uninstall ]; then
    echo
    echo "Bytemeter: uninstall"
    echo "--------------------"
    [ "$DRY" = 1 ] && say "dry run: nothing will be changed"
    say_stop_plan
    if [ -e "$AGENT" ]; then
        step "move $AGENT to the Bin" "login item moved to the Bin" to_bin "$AGENT"
    else
        say "no login item at $AGENT"
    fi
    if [ -e "$APP" ]; then
        step "move $APP to the Bin" "app moved to the Bin" to_bin "$APP"
    else
        say "no app at $APP"
    fi
    say "your data stays in $DATA"
    [ -d "$LOGS" ] && say "the error log stays in $LOGS"
    say "to remove the history as well, move that folder to the Bin yourself"
    echo
    exit 0
fi

# ------------------------------------------------- where the app comes from

[ "$(uname)" = Darwin ] || die "Bytemeter is a macOS app and only runs on a Mac."

# --app: a bundle someone else built, such as Homebrew. Checked before it is
# trusted, and read only: the copy that gets installed is made later.
check_bundle() {
    [ -d "$FROM" ] || die "there is no app at $FROM"
    local id
    id="$(plutil -extract CFBundleIdentifier raw -o - "$FROM/Contents/Info.plist" 2>/dev/null || true)"
    [ "$id" = "$LABEL" ] || die "$FROM is not a Bytemeter app"
    [ -x "$FROM/Contents/MacOS/$NAME" ] || die "$FROM has no $NAME executable inside it"
    codesign --verify --deep --strict "$FROM" 2>/dev/null || die "the signature of $FROM does not verify, so it was not installed"
    if [ -d "$APP" ] && [ "$(cd "$FROM" && pwd -P)" = "$(cd "$APP" && pwd -P)" ]; then
        die "$FROM is the installed copy itself. Point --app at the one to install."
    fi
    VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$FROM/Contents/Info.plist")"
    BUILD="$(plutil -extract CFBundleVersion raw -o - "$FROM/Contents/Info.plist")"
}

if [ -n "$FROM" ]; then
    check_bundle
else
    command -v swift >/dev/null 2>&1 || die "swift was not found. Install the command line tools: xcode-select --install"
    [ -f "$SRC/VERSION" ] || die "VERSION is missing from $SRC"
    VERSION="$(sed -n 's/^VERSION=//p' "$SRC/VERSION" | tr -d '[:space:]')"
    BUILD="$(sed -n 's/^BUILD=//p' "$SRC/VERSION" | tr -d '[:space:]')"
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION=$VERSION in the VERSION file is not like 1.2.3"
    [[ "$BUILD" =~ ^[0-9]+$ ]] || die "BUILD=$BUILD in the VERSION file is not a whole number"
fi

TITLE="Bytemeter $VERSION (build $BUILD)"
echo
echo "$TITLE"
echo "$TITLE" | tr '[:print:]' '-'
[ "$DRY" = 1 ] && say "dry run: nothing will be changed"

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

swift_build() {  # every swift build call, so --disable-sandbox reaches them all
    (cd "$SRC" && swift build -c release ${SANDBOX:+"$SANDBOX"} "$@")
}

build_binary() {
    say "building, which takes a minute or two the first time"
    if ! swift_build --product "$NAME" >"$WORK/build.log" 2>&1; then
        tail -n 30 "$WORK/build.log" >&2
        die "the build failed. The last lines of its output are above."
    fi
    local dir
    if ! dir="$(swift_build --show-bin-path 2>>"$WORK/build.log")"; then
        tail -n 30 "$WORK/build.log" >&2
        die "swift build could not say where it put the app. The last lines of its output are above."
    fi
    BIN="$dir/$NAME"
    [ -x "$BIN" ] || die "the build finished but $BIN is missing"
}

# Assemble the bundle in a temporary folder, so a failed step never leaves a
# half built app where a working one was.
assemble_bundle() {
    local app="$WORK/$NAME.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BIN" "$app/Contents/MacOS/$NAME"
    cp "$SRC/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
    cp "$SRC/Scripts/Info.plist" "$app/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$BUILD" "$app/Contents/Info.plist"
    plutil -lint -s "$app/Contents/Info.plist"
    # Extended attributes such as Finder information make codesign refuse a bundle.
    xattr -cr "$app"
    # Ad hoc signed, which is all a locally built app needs. No --deep when
    # signing: it is deprecated and has produced signatures the loader rejects.
    # Checking with --deep is fine. The linker has already signed the binary,
    # so codesign always says it is replacing a signature; that is shown only
    # if signing fails.
    local said
    said="$(codesign --force --sign - "$app" 2>&1)" || { printf '%s\n' "$said" >&2; die "signing failed"; }
    codesign --verify --deep --strict "$app"
}

# ditto keeps the bundle exactly as it is, signature included. It copies
# rather than moves, because the original belongs to whoever built it.
copy_bundle() {
    ditto "$FROM" "$WORK/$NAME.app"
    codesign --verify --deep --strict "$WORK/$NAME.app"
}

if [ -n "$FROM" ]; then
    if [ "$DRY" = 1 ]; then
        say "would copy $FROM, already built (its signature verifies)"
    else
        WORK="$(mktemp -d -t bytemeter)"
        copy_bundle
        say "using the app already built at $FROM"
    fi
    # A bundle downloaded through a browser carries this mark. It is reported,
    # not removed: whether to trust a download is the owner's call, not this
    # script's.
    if xattr -p com.apple.quarantine "$FROM" >/dev/null 2>&1; then
        say "note: $FROM is marked as downloaded from the internet,"
        say "      so macOS may refuse to start it until you allow it"
    fi
elif [ "$DRY" = 1 ]; then
    say "would build: swift build -c release${SANDBOX:+ $SANDBOX} --product $NAME, in $SRC"
    say "would assemble $NAME.app in a temporary folder from:"
    say "    $SRC/.build/release/$NAME"
    say "    $SRC/Scripts/Info.plist, with version $VERSION and build $BUILD"
    say "    $SRC/Resources/AppIcon.icns"
    say "would sign it ad hoc: codesign --force --sign -, then codesign --verify --deep --strict"
else
    WORK="$(mktemp -d -t bytemeter)"
    build_binary
    assemble_bundle
    say "built and signed ad hoc"
fi

# ------------------------------------------------------------ --bundle-only

place_bundle() {  # a previous build in the same folder is replaced
    mkdir -p "$OUT"
    rm -rf "${OUT:?}/$NAME.app"
    mv "$WORK/$NAME.app" "$OUT/$NAME.app"
}

if [ "$MODE" = bundle ]; then
    step "put the app at $OUT/$NAME.app" "app ready: $OUT/$NAME.app" place_bundle
    say "nothing in ~/Applications or ~/Library was touched"
    echo
    exit 0
fi

# ---------------------------------------------------------- full install

install_app() {
    mkdir -p "$(dirname "$APP")"
    rm -rf "${APP:?}"
    mv "$WORK/$NAME.app" "$APP"
}

fill_home() {  # $1 = plist, $2 = key path. launchd does not expand ~, so the template says __HOME__
    local value
    value="$(plutil -extract "$2" raw -o - "$1")"
    # Remove, then insert. On an array element, plutil -replace inserts a new
    # element in front of the old one instead of replacing it.
    plutil -remove "$2" "$1"
    plutil -insert "$2" -string "${value/__HOME__/$HOME}" "$1"
}

write_agent() {
    local plist="$WORK/agent.plist"
    cp "$SRC/Scripts/bytemeter.plist" "$plist"
    fill_home "$plist" ProgramArguments.0
    fill_home "$plist" StandardErrorPath
    grep -q __HOME__ "$plist" && die "Scripts/bytemeter.plist has a __HOME__ this script does not fill in"
    # The template and this script must agree on where the app and the log live.
    [ "$(plutil -extract ProgramArguments.0 raw -o - "$plist")" = "$APP/Contents/MacOS/$NAME" ] \
        || die "Scripts/bytemeter.plist points somewhere other than $APP"
    [ "$(dirname "$(plutil -extract StandardErrorPath raw -o - "$plist")")" = "$LOGS" ] \
        || die "Scripts/bytemeter.plist logs somewhere other than $LOGS"
    plutil -lint -s "$plist"
    chmod 644 "$plist"
    mkdir -p "$(dirname "$AGENT")"
    mv "$plist" "$AGENT"
}

# A full bootout and bootstrap, never kickstart. launchd caches the code
# signature it registered for this path, and an ad hoc signature changes on
# every build, so a kickstart would launch the new binary against the old
# signature and the kernel would kill it.
start_agent() {
    # One quiet retry, for a bootout that has not finished yet. The second
    # attempt shows launchd's own error if it fails too.
    if ! launchctl bootstrap "gui/$UID" "$AGENT" 2>/dev/null; then
        sleep 1
        launchctl bootstrap "gui/$UID" "$AGENT" || die "launchd would not load $AGENT"
    fi
    local tries=0
    until [ -n "$(running_pid)" ]; do
        tries=$((tries + 1))
        [ "$tries" -gt 20 ] && die "launchd loaded Bytemeter but it is not running. Any error is in $LOGS/bytemeter.err"
        sleep 0.5
    done
    say "loaded, and running as pid $(running_pid)"
}

say_stop_plan
if [ -e "$APP" ]; then
    step "replace $APP" "app replaced: $APP" install_app
else
    step "install the app at $APP" "app installed: $APP" install_app
fi
step "make the log folder $LOGS" "" mkdir -p "$LOGS"
step "write the login item $AGENT, from $SRC/Scripts/bytemeter.plist" "login item written: $AGENT" write_agent
step "load it: launchctl bootstrap gui/$UID $AGENT" "" start_agent

if [ "$DRY" = 1 ]; then
    say "the app keeps its data in $DATA, which this script never touches"
else
    say "your data lives in $DATA"
    say "errors, if any, go to $LOGS/bytemeter.err"
    say "to remove it, run this again with --uninstall (your data is kept)"
fi
echo
