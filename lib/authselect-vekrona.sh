#!/usr/bin/env bash

PAM_U2F_STOCK='pam_u2f.so cue'
# authfile: see lib/pam-u2f.sh. etc/pam.d/vekrona-lock-u2f carries the same arguments.
PAM_U2F_VEKRONA='pam_u2f.so cue pinverification=1 origin=pam://vekrona appid=pam://vekrona authfile=/etc/u2f_mappings'
AUTHSELECT_PAM_FILES=(system-auth password-auth)

# The profile stage 45-auth writes and selects, with the features it selects, and what `authselect current --raw` reports once it
# is selected (sorted, on one line): 70-verify compares with the same.
PROFILE_NAME=vekrona
PROFILE_ID="custom/$PROFILE_NAME"
PROFILE_FEATURES=(with-silent-lastlog with-fingerprint with-pam-u2f)

wanted_authselect_selection() {
  printf '%s\n' "$PROFILE_ID" "${PROFILE_FEATURES[@]}" | sort | paste -sd' '
}

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

# render_authselect_profile BASE DEST: DEST must be a directory only root can change (with_root_scratch_dir), because root installs
# what is rendered into it: in a directory the user owns, any process of the user could swap a file between the render and the install.
render_authselect_profile() {
  local base="$1" dest="$2" f content found owner
  owner="$(stat -c %u "$dest")" || die "cannot read the owner of the authselect profile directory $dest"
  [[ "$owner" == 0 ]] || die "authselect profile directory is not root-owned: $dest (owner uid '$owner')"
  root cp -a "$base/." "$dest" || die "cannot copy authselect base profile from $base"
  for f in "${AUTHSELECT_PAM_FILES[@]}"; do
    content="$(<"$dest/$f")"
    found="$(count_occurrences "$content" "$PAM_U2F_STOCK")"
    [[ "$found" -eq 2 ]] || die "expected 2 pam_u2f lines in base profile $f, found $found"
    printf '%s\n' "${content//"$PAM_U2F_STOCK"/"$PAM_U2F_VEKRONA"}" | root tee "$dest/$f" >/dev/null || die "cannot write $dest/$f"
  done
}
