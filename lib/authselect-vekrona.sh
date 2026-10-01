#!/usr/bin/env bash

PAM_U2F_STOCK='pam_u2f.so cue'
PAM_U2F_VEKRONA='pam_u2f.so cue pinverification=1 origin=pam://vekrona appid=pam://vekrona'
AUTHSELECT_PAM_FILES=(system-auth password-auth)

authselect_base_dir() {
  local d
  for d in /usr/share/authselect/vendor/local /usr/share/authselect/default/local; do
    if [[ -d "$d" ]]; then
      printf '%s' "$d"
      return 0
    fi
  done
  die "authselect base profile 'local' not found"
}

count_occurrences() {
  local text="$1" needle="$2" stripped
  stripped="${text//"$needle"/}"
  printf '%s' "$(((${#text} - ${#stripped}) / ${#needle}))"
}

render_authselect_profile() {
  local base="$1" dest="$2" f content found
  cp -a "$base/." "$dest" || die "cannot copy authselect base profile from $base"
  for f in "${AUTHSELECT_PAM_FILES[@]}"; do
    content="$(<"$dest/$f")"
    found="$(count_occurrences "$content" "$PAM_U2F_STOCK")"
    [[ "$found" -eq 2 ]] || die "expected 2 pam_u2f lines in base profile $f, found $found"
    printf '%s\n' "${content//"$PAM_U2F_STOCK"/"$PAM_U2F_VEKRONA"}" >"$dest/$f"
  done
}
