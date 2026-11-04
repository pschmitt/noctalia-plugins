#!/usr/bin/env bash

usage() {
  printf 'Usage: %s [status|toggle|show|hide]\n' "$(basename "$0")"
}

main() {
  local schema=org.gnome.desktop.a11y.applications
  local key=screen-keyboard-enabled
  local action="${1:-toggle}"
  local pattern='^(squeekboard|\.squeekboard-wr)$'
  case "$action" in
    -h|--help) usage; return 0 ;;
    status|toggle|show|hide) ;;
    *) usage >&2; return 2 ;;
  esac
  # Include Nix's truncated wrapped process name; never match command lines.
  if [[ "$action" == toggle ]]
  then
    if pgrep -u "$UID" -x "$pattern" >/dev/null
    then
      action=hide
    else
      action=show
    fi
  fi
  case "$action" in
    show)
      gsettings set "$schema" "$key" true || return 1
      if ! pgrep -u "$UID" -x "$pattern" >/dev/null
      then
        setsid squeekboard </dev/null >/dev/null 2>&1 &
        sleep 0.2
        pgrep -u "$UID" -x "$pattern" >/dev/null || return 1
      fi
      ;;
    hide)
      gsettings set "$schema" "$key" false || return 1
      pkill -u "$UID" -x "$pattern" || [[ "$?" == 1 ]] || return 1
      ;;
  esac
  if pgrep -u "$UID" -x "$pattern" >/dev/null
  then
    printf 'enabled\n'
  else
    printf 'disabled\n'
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]
then
  main "$@"
fi

# vim: set ft=sh et ts=2 sw=2 :
