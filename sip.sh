#!/bin/bash
# sip — keep your Mac awake while AI works
#
# A tiny caffeinate wrapper for AI coding tools (Claude Code, Cursor, CodeBuddy, etc.).
# Each prompt "sips" a cup of coffee — starts a 15-minute caffeinate timer.
# If one is already running, it kills and restarts. When it expires, Mac sleeps normally.
#
# Usage:
#   sip.sh                 Hook mode (called by UserPromptSubmit, consumes stdin)
#   sip.sh status          Show active caffeinate instances and hook registration
#   sip.sh stop            Kill all sip-managed caffeinate instances
#   sip.sh install         Install hook into detected IDE settings.json
#   sip.sh uninstall       Remove hook and stop caffeinate

set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────

TIMEOUT="${SIP_TIMEOUT:-900}"                          # default 15 min
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_PATH="${INSTALL_DIR}/sip.sh"
HOOK_CMD="${HOME}/.local/bin/sip.sh"
MARKER="sip-caffeinate"                                # identifier in process args
HOOK_TAG="# managed by sip"                             # unique tag for hook identification
LOCK_DIR="${TMPDIR:-/tmp}/sip.lock"                    # mkdir atomic lock dir (prevents concurrent caffeinate)
LOCK_TIMEOUT_MS=2000                                   # max wait to acquire lock (~2s; hook timeout=5s leaves 3s for work)
LOCK_POLL_MS=100                                       # lock poll interval

# IDE definitions: name:config_dir[:config_file[:schema]] (space-separated)
# schema defaults to "anthropic" (hooks at .hooks.<Event>); "zcode" uses
# hooks at .hooks.events.<Event> with hooks.enabled=true and no matcher field.
# config_file defaults to settings.json; codex uses hooks.json; zcode uses config.json.
# Default: auto-detect. Others require --ide to specify explicitly.
_IDES="claude:$HOME/.claude codebuddy:$HOME/.codebuddy workbuddy:$HOME/.workbuddy cursor:$HOME/.cursor cline:$HOME/.cline augment:$HOME/.augment windsurf:$HOME/.windsurf codex:$HOME/.codex:hooks.json zcode:$HOME/.zcode/cli:config.json:zcode"

# ─── Prerequisites ────────────────────────────────────────────────────────────

_require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "❌ '$1' is required but not found. Install it first." >&2
        exit 1
    }
}

# ─── Locking ──────────────────────────────────────────────────────────────────
#
# mkdir is POSIX-atomic: exactly one concurrent caller creates the dir, the
# rest fail. This serializes hook handlers (reset/ensure/stop) so that under
# multi-client / multi-session concurrency only one caffeinate ever exists.
#
# Stale-lock recovery: if the holder dies without releasing (e.g. SIGKILL),
# the next acquirer detects the dead pid via `kill -0` and reclaims the lock.
# Worst case (pid file unreadable / holder alive but wedged): the acquirer
# gives up after LOCK_TIMEOUT_MS and the hook fails silently — it never blocks
# the IDE, because hooks run with a 5s timeout and we wait at most ~2s.

_acquire_lock() {
    local tries=0 max_tries=$(( LOCK_TIMEOUT_MS / LOCK_POLL_MS ))
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        # Reclaim if the holder is dead (prevents permanent deadlock).
        local owner_pid
        owner_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
            rm -rf "$LOCK_DIR" 2>/dev/null || true
            continue
        fi
        tries=$((tries + 1))
        [ "$tries" -ge "$max_tries" ] && return 1
        sleep 0.1
    done
    echo "$$" > "$LOCK_DIR/pid"
    trap '_release_lock' EXIT INT TERM
}

_release_lock() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }

# ─── IDE helpers ──────────────────────────────────────────────────────────────

_ide_name()     { echo "${1%%:*}"; }
# _ide_dir: return config dir = second segment (handle name:dir[:file[:schema]])
_ide_dir()      { local rest="${1#*:}"; echo "${rest%%:*}"; }
# _ide_settings: return config file path; default settings.json, codex uses hooks.json
# Strips optional 4th segment (schema) so it doesn't leak into the path.
_ide_settings() {
    local rest="${1#*:}"                                    # dir[:file[:schema]]
    local dir="${rest%%:*}"                                 # dir
    local file="${rest#*:}"                                 # :file[:schema] or rest itself if no ':'
    [ "$file" = "$rest" ] && file="settings.json"           # no ':file' → default
    file="${file%%:*}"                                      # strip :schema if present
    echo "$dir/$file"
}
# _ide_schema: return hook schema — "anthropic" (default) or "zcode"
# The 4th colon-separated segment; absent → "anthropic".
_ide_schema() {
    local rest="${1#*:}"                                    # dir[:file[:schema]]
    local after_dir="${rest#*:}"                             # :file[:schema] or rest
    [ "$after_dir" = "$rest" ] && { echo "anthropic"; return; }  # no file → no schema
    local schema="${after_dir#*:}"                           # :schema or after_dir itself
    [ "$schema" = "$after_dir" ] && { echo "anthropic"; return; }  # no schema → default
    echo "$schema"
}

_get_ide() {
    # Lookup IDE entry by name
    for ide in $_IDES; do
        if [ "$(_ide_name "$ide")" = "$1" ]; then
            echo "$ide"
            return 0
        fi
    done
    return 1
}

_default_ide() {
    # Auto-detect: first IDE whose config dir exists, else claude.
    for ide in $_IDES; do
        if [ -d "$(_ide_dir "$ide")" ]; then
            echo "$ide"
            return 0
        fi
    done
    echo "claude:$HOME/.claude"
}

_resolve_ides() {
    # Resolve target IDEs: --ide <name> → single IDE, else auto-detect.
    # Usage: _resolve_ides [--ide <name>]
    local explicit_ide=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --ide) shift; explicit_ide="${1:-}"
                   [ -z "$explicit_ide" ] && { echo "❌ --ide requires a value" >&2; exit 1; }
                   shift ;;
            *) shift ;;
        esac
    done

    if [ -n "$explicit_ide" ]; then
        local entry
        if ! entry=$(_get_ide "$explicit_ide"); then
            echo "❌ unknown IDE: $explicit_ide (supported: $(for i in $_IDES; do _ide_name "$i"; done | tr '\n' ' '))" >&2
            exit 1
        fi
        echo "$entry"
    else
        _default_ide
    fi
}

_scan_ides() {
    # Scan all IDEs for status display — shows registered + unregistered.
    for ide in $_IDES; do
        echo "$ide"
    done
}

# ─── Hook modes ───────────────────────────────────────────────────────────────
#
# Two strategies to balance responsiveness vs system overhead:
#
#   reset  — kill + restart caffeinate (resets the 15-min timer)
#            Used by: UserPromptSubmit, SubagentStart (low frequency)
#
#   ensure — start only if not already running (idempotent, no kill)
#            Used by: PostToolUse (high frequency, fires on every tool call)
#
# This way UserPromptSubmit resets the countdown on each user prompt,
# while PostToolUse just guarantees coverage without churning processes.
#
# Hook mode uses silent failure: never let errors disrupt the AI workflow.

_consume_stdin() { cat > /dev/null; }

_start_caffeinate() {
    bash -c "exec -a '$MARKER' caffeinate -is -t '$TIMEOUT'" &>/dev/null &
    disown 2>/dev/null || true
}

cmd_hook_reset() {
    _consume_stdin
    _acquire_lock || return 0
    pkill -f "$MARKER" 2>/dev/null || true
    _start_caffeinate 2>/dev/null || true
    _release_lock
}

cmd_hook_ensure() {
    _consume_stdin
    _acquire_lock || return 0
    pgrep -f "$MARKER" >/dev/null 2>&1 || _start_caffeinate 2>/dev/null || true
    _release_lock
}

# ─── Status ───────────────────────────────────────────────────────────────────

cmd_status() {
    echo "=== sip status ==="
    echo ""

    # script installed?
    if [ -f "$INSTALL_PATH" ]; then
        echo "  script:  ✅  $INSTALL_PATH"
    else
        echo "  script:  ❌  not installed ($INSTALL_PATH)"
    fi

    # caffeinate running? (no jq needed for this check)
    echo ""
    local found=0
    while IFS= read -r line; do
        local pid
        pid=$(echo "$line" | awk '{print $1}')
        echo "  running: ✅  caffeinate pid=$pid  (timeout=${TIMEOUT}s)"
        found=1
    done < <(pgrep -f "$MARKER" 2>/dev/null | while IFS= read -r p; do ps -p "$p" -o pid=,args= 2>/dev/null; done || true)
    [ "$found" -eq 0 ] && echo "  running: ⏸️   not active"
    echo ""

    # hooks registered? (requires jq)
    if ! command -v jq >/dev/null 2>&1; then
        echo "  hook:    ⚠️  jq not installed — cannot check hook registration"
        return 0
    fi
    while IFS= read -r ide; do
        local name settings schema
        name=$(_ide_name "$ide")
        settings=$(_ide_settings "$ide")
        schema=$(_ide_schema "$ide")

        if [ -f "$settings" ]; then
            # ZCode doesn't have SubagentStart — only check the two it supports.
            local hook_events="UserPromptSubmit PostToolUse SubagentStart"
            if [ "$schema" = "zcode" ]; then
                hook_events="UserPromptSubmit PostToolUse"
            fi
            local hook_base
            if [ "$schema" = "zcode" ]; then
                hook_base=".hooks.events"
            else
                hook_base=".hooks"
            fi
            local all_ok=true
            for event in $hook_events; do
                if ! jq -e "${hook_base}.${event}[]? | .hooks[]? | select(.command | contains(\"sip.sh\"))" \
                    "$settings" >/dev/null 2>&1; then
                    all_ok=false
                    break
                fi
            done
            # ZCode also requires hooks.enabled=true
            if [ "$schema" = "zcode" ] && $all_ok; then
                if ! jq -e '.hooks.enabled == true' "$settings" >/dev/null 2>&1; then
                    all_ok=false
                fi
            fi
            if $all_ok; then
                echo "  hook:    ✅  $name"
            else
                echo "  hook:    ❌  $name (incomplete)"
            fi
        else
            echo "  hook:    —    $name"
        fi
    done < <(_scan_ides)
}

# ─── Stop ─────────────────────────────────────────────────────────────────────

cmd_stop() {
    _acquire_lock || return 1
    local stopped=0
    while IFS= read -r pid; do
        kill "$pid" 2>/dev/null && stopped=$((stopped + 1))
    done < <(pgrep -f "$MARKER" 2>/dev/null || true)
    _release_lock
    echo "[sip] stopped $stopped instance(s)"
}

# ─── Install ──────────────────────────────────────────────────────────────────

cmd_install() {
    _require jq
    echo ""
    echo "=== sip install ==="
    echo ""

    # show IDE detection info (only when --ide is not specified)
    if [[ ! "$*" == *"--ide"* ]]; then
        local resolved
        resolved=$(_default_ide)
        echo "  ℹ️  auto-detected IDE: $(_ide_name "$resolved")"
        echo ""
    fi

    # 1. copy self to ~/.local/bin/sip.sh (skip if already there)
    mkdir -p "$INSTALL_DIR"
    local self
    self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    if [ "$self" = "$INSTALL_PATH" ]; then
        echo "  ✅ script already at $INSTALL_PATH"
    else
        cp "$0" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo "  ✅ script → $INSTALL_PATH"
    fi

    # check PATH
    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*) ;;
        *) echo "  ⚠️  add to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac

    # 2. register hooks in each target IDE's settings.json
    #    UserPromptSubmit / SubagentStart → reset (kill + restart, resets timer)
    #    PostToolUse                      → ensure (idempotent, no kill)
    #    ZCode has no SubagentStart event — skipped for zcode schema.
    local events_reset="UserPromptSubmit SubagentStart"
    local events_ensure="PostToolUse"

    _register_hook() {
        local event="$1" cmd="$2" settings="$3" schema="$4"
        local tagged_cmd="$cmd $HOOK_TAG"
        local hook_entry
        if [ "$schema" = "zcode" ]; then
            # ZCode: no matcher field (omitting it matches all), hooks at .hooks.events.<Event>
            hook_entry=$(jq -n --arg cmd "$tagged_cmd" '{
                "hooks": [{"type": "command", "command": $cmd, "timeout": 5}]
            }')
        else
            # Anthropic: matcher "*" matches all
            hook_entry=$(jq -n --arg cmd "$tagged_cmd" '{
                "matcher": "*",
                "hooks": [{"type": "command", "command": $cmd, "timeout": 5}]
            }')
        fi
        local hook_base
        if [ "$schema" = "zcode" ]; then
            hook_base=".hooks.events"
        else
            hook_base=".hooks"
        fi
        if jq -e "${hook_base}.${event}[]? | .hooks[]? | select(.command | contains(\"sip.sh\"))" \
            "$settings" >/dev/null 2>&1; then
            echo "     ✅ hook already registered: $event"
        else
            local tmp="${settings}.tmp"
            if [ "$schema" = "zcode" ]; then
                # ZCode: set hooks.enabled=true and write to .hooks.events.<Event>
                jq --argjson entry "$hook_entry" --arg event "$event" '
                    .hooks //= {} |
                    .hooks.enabled = true |
                    .hooks.events //= {} |
                    .hooks.events[$event] //= [] |
                    .hooks.events[$event] += [$entry]
                ' "$settings" > "$tmp" && mv "$tmp" "$settings"
            else
                # Anthropic: write to .hooks.<Event>
                jq --argjson entry "$hook_entry" --arg event "$event" '
                    .hooks //= {} |
                    .hooks[$event] //= [] |
                    .hooks[$event] += [$entry]
                ' "$settings" > "$tmp" && mv "$tmp" "$settings"
            fi
            echo "     ✅ hook → $event"
        fi
    }

    while IFS= read -r ide; do
        local name settings schema
        name=$(_ide_name "$ide")
        settings=$(_ide_settings "$ide")
        schema=$(_ide_schema "$ide")

        echo "  [$name]"

        mkdir -p "$(dirname "$settings")"
        if [ ! -f "$settings" ]; then
            echo '{}' > "$settings"
        fi

        # ZCode doesn't support SubagentStart — skip it.
        local effective_reset="$events_reset"
        if [ "$schema" = "zcode" ]; then
            effective_reset="UserPromptSubmit"
        fi

        for event in $effective_reset; do
            _register_hook "$event" "$HOOK_CMD" "$settings" "$schema"
        done
        for event in $events_ensure; do
            _register_hook "$event" "$HOOK_CMD ensure" "$settings" "$schema"
        done
        # Codex requires trusting non-managed hooks once (bound to current hash).
        [ "$name" = "codex" ] && echo "     ⚠️  Codex: run /hooks in Codex to trust the hook (one-time)"
        echo ""
    done < <(_resolve_ides "$@")

    echo "  Restart your IDE to activate."
    echo "  Run 'sip.sh status' to verify."
    echo ""
}

# ─── Uninstall ────────────────────────────────────────────────────────────────

cmd_uninstall() {
    _require jq
    echo ""
    echo "=== sip uninstall ==="
    echo ""

    # show IDE detection info (only when --ide is not specified)
    if [[ ! "$*" == *"--ide"* ]]; then
        local resolved
        resolved=$(_default_ide)
        echo "  ℹ️  auto-detected IDE: $(_ide_name "$resolved")"
        echo ""
    fi

    # 1. stop caffeinate
    cmd_stop
    echo ""

    # 2. remove hooks from each target IDE's settings.json
    while IFS= read -r ide; do
        local name settings schema
        name=$(_ide_name "$ide")
        settings=$(_ide_settings "$ide")
        schema=$(_ide_schema "$ide")

        echo "  [$name]"

        if [ -f "$settings" ]; then
            local tmp="${settings}.tmp"
            if [ "$schema" = "zcode" ]; then
                # ZCode: clean .hooks.events.<Event>, then remove empty events + enabled
                jq '
                    . as $root |
                    ["UserPromptSubmit", "PostToolUse"] | reduce .[] as $event ($root;
                        if .hooks.events[$event] then
                            .hooks.events[$event] |= [.[] | select(.hooks | all(.command | contains("sip.sh") | not))]
                        else . end |
                        if .hooks.events[$event] == [] then del(.hooks.events[$event]) else . end
                    ) |
                    if .hooks.events == {} then del(.hooks.events) else . end |
                    if .hooks | has("enabled") and (.hooks.events // {} | length == 0) then del(.hooks.enabled) else . end |
                    if .hooks == {} or .hooks == {"enabled":true} then del(.hooks) else . end
                ' "$settings" > "$tmp" && mv "$tmp" "$settings"
            else
                # Anthropic: clean .hooks.<Event>
                jq '
                    . as $root |
                    ["UserPromptSubmit", "PostToolUse", "SubagentStart"] | reduce .[] as $event ($root;
                        if .hooks[$event] then
                            .hooks[$event] |= [.[] | select(.hooks | all(.command | contains("sip.sh") | not))]
                        else . end |
                        if .hooks[$event] == [] then del(.hooks[$event]) else . end
                    ) |
                    if .hooks == {} then del(.hooks) else . end
                ' "$settings" > "$tmp" && mv "$tmp" "$settings"
            fi

            # remove empty settings file
            if jq -e '. == {}' "$settings" >/dev/null 2>&1; then
                rm -f "$settings"
                echo "  ✅ hooks removed (settings cleaned up)"
            else
                echo "  ✅ hooks removed"
            fi
        else
            echo "  ℹ️  no settings file found"
        fi
        echo ""
    done < <(_resolve_ides "$@")

    # 3. remove script
    if [ -f "$INSTALL_PATH" ]; then
        rm -f "$INSTALL_PATH"
        echo "  ✅ script removed: $INSTALL_PATH"
    else
        echo "  ℹ️  script not found"
    fi

    echo ""
    echo "  Done. Restart your IDE to complete."
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    "")         cmd_hook_reset ;;
    ensure)     cmd_hook_ensure ;;
    status)     cmd_status ;;
    stop)       cmd_stop ;;
    install)    shift; cmd_install "$@" ;;
    uninstall)  shift; cmd_uninstall "$@" ;;
    -h|--help)
        echo "sip.sh — keep your Mac awake while AI works"
        echo ""
        echo "Usage:"
        echo "  sip.sh              Hook mode: kill + restart caffeinate (resets timer)"
        echo "  sip.sh ensure       Hook mode: start only if not running (idempotent)"
        echo "  sip.sh status       Show installation and runtime status"
        echo "  sip.sh stop         Kill all sip-managed caffeinate instances"
        echo "  sip.sh install      Install to ~/.local/bin/ and register hooks"
        echo "  sip.sh uninstall    Remove hooks, stop caffeinate, remove script"
        echo ""
        echo "Options:"
        echo "  install/uninstall --ide <name>   Target IDE"
        echo "                                  Supported: claude codebuddy workbuddy cursor cline augment windsurf codex zcode"
        echo "                                  Default: auto-detect"
        echo ""
        echo "Environment:"
        echo "  SIP_TIMEOUT      Caffeinate timeout in seconds (default: 900)"
        ;;
    *)
        echo "Unknown command: $1 (try 'sip.sh --help')" >&2
        exit 1 ;;
esac
