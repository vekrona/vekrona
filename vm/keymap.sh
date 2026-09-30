#!/usr/bin/env bash
set -euo pipefail

map_char() {
  local c="$1"
  case "$c" in
    ' ') echo KEY_SPACE ;;
    $'\t') echo KEY_TAB ;;
    $'\n') echo KEY_ENTER ;;
    [a-z]) echo "KEY_${c^^}" ;;
    [A-Z]) echo "KEY_LEFTSHIFT KEY_${c}" ;;
    [0-9]) echo "KEY_${c}" ;;
    '-') echo KEY_MINUS ;;
    '=') echo KEY_EQUAL ;;
    '[') echo KEY_LEFTBRACE ;;
    ']') echo KEY_RIGHTBRACE ;;
    ';') echo KEY_SEMICOLON ;;
    "'") echo KEY_APOSTROPHE ;;
    ',') echo KEY_COMMA ;;
    '.') echo KEY_DOT ;;
    '/') echo KEY_SLASH ;;
    \\) echo KEY_BACKSLASH ;;
    '`') echo KEY_GRAVE ;;
    '!') echo "KEY_LEFTSHIFT KEY_1" ;;
    '@') echo "KEY_LEFTSHIFT KEY_2" ;;
    '#') echo "KEY_LEFTSHIFT KEY_3" ;;
    '$') echo "KEY_LEFTSHIFT KEY_4" ;;
    '%') echo "KEY_LEFTSHIFT KEY_5" ;;
    '^') echo "KEY_LEFTSHIFT KEY_6" ;;
    '&') echo "KEY_LEFTSHIFT KEY_7" ;;
    '*') echo "KEY_LEFTSHIFT KEY_8" ;;
    '(') echo "KEY_LEFTSHIFT KEY_9" ;;
    ')') echo "KEY_LEFTSHIFT KEY_0" ;;
    '_') echo "KEY_LEFTSHIFT KEY_MINUS" ;;
    '+') echo "KEY_LEFTSHIFT KEY_EQUAL" ;;
    '{') echo "KEY_LEFTSHIFT KEY_LEFTBRACE" ;;
    '}') echo "KEY_LEFTSHIFT KEY_RIGHTBRACE" ;;
    ':') echo "KEY_LEFTSHIFT KEY_SEMICOLON" ;;
    '"') echo "KEY_LEFTSHIFT KEY_APOSTROPHE" ;;
    '<') echo "KEY_LEFTSHIFT KEY_COMMA" ;;
    '>') echo "KEY_LEFTSHIFT KEY_DOT" ;;
    '?') echo "KEY_LEFTSHIFT KEY_SLASH" ;;
    '|') echo "KEY_LEFTSHIFT KEY_BACKSLASH" ;;
    '~') echo "KEY_LEFTSHIFT KEY_GRAVE" ;;
    *)
      echo "keymap.sh: no keycode mapping for character: $c" >&2
      return 1
      ;;
  esac
}

[[ $# -eq 1 ]] || { echo "usage: $(basename "$0") TEXT" >&2; exit 2; }
text="$1"

for (( i = 0; i < ${#text}; i++ )); do
  map_char "${text:i:1}"
done
