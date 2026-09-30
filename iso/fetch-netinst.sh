#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $(basename "$0") <fedora-release> <dest-dir>" >&2; exit 2; }
release="$1"
dest="$2"

mkdir -p "$dest"

iso_dir_url="https://download.fedoraproject.org/pub/fedora/linux/releases/$release/Everything/x86_64/iso/"

resolved_url="$(curl -sS -f -o /dev/null -w '%{url_effective}' -L --max-redirs 1 -I "$iso_dir_url")" \
  || { echo "could not resolve a mirror for $iso_dir_url" >&2; exit 1; }
[[ "$resolved_url" != "$iso_dir_url" ]] \
  || { echo "$iso_dir_url did not redirect to a mirror; refusing to pin to the redirector itself" >&2; exit 1; }
[[ "$resolved_url" == */ ]] \
  || { echo "mirror redirect for $iso_dir_url resolved to a non-directory URL: $resolved_url" >&2; exit 1; }

listing="$(curl -sS -f -L "$resolved_url")" \
  || { echo "could not list directory $resolved_url" >&2; exit 1; }
checksum_name="$(grep -oE "Fedora-Everything-$release-[0-9.]+-x86_64-CHECKSUM" <<<"$listing" | sort -u | head -n1)"
[[ -n "$checksum_name" ]] \
  || { echo "no Fedora-Everything-$release-*-x86_64-CHECKSUM entry found in the directory listing of $resolved_url" >&2; exit 1; }

checksum_url="${resolved_url}${checksum_name}"
checksum_file="$dest/$checksum_name"
curl -sS -f -o "$checksum_file.part" "$checksum_url" \
  || { echo "could not download $checksum_url" >&2; exit 1; }
mv "$checksum_file.part" "$checksum_file"

fedora_gpg="$dest/.fedora.gpg"
curl -sS -f -o "$fedora_gpg.part" https://fedoraproject.org/fedora.gpg \
  || { echo "could not download https://fedoraproject.org/fedora.gpg" >&2; exit 1; }
mv "$fedora_gpg.part" "$fedora_gpg"

gnupg_home="$(mktemp -d)"
trap 'rm -rf "$gnupg_home"' EXIT
chmod 700 "$gnupg_home"

GNUPGHOME="$gnupg_home" gpg --batch --quiet --import "$fedora_gpg" \
  || { echo "could not import Fedora release keys from $fedora_gpg" >&2; exit 1; }

GNUPGHOME="$gnupg_home" gpg --batch --verify "$checksum_file" \
  || { echo "GPG signature verification failed for $checksum_file against Fedora's release keys" >&2; exit 1; }

iso_name="$(grep -oE "Fedora-Everything-netinst-x86_64-${release}[0-9._-]*\.iso" "$checksum_file" | sort -u | head -n1)"
[[ -n "$iso_name" ]] \
  || { echo "no Fedora-Everything-netinst-x86_64-$release*.iso entry found in $checksum_file" >&2; exit 1; }

checksum_line="$(grep -F "SHA256 ($iso_name) =" "$checksum_file" || true)"
[[ -n "$checksum_line" ]] \
  || { echo "no SHA256 line for $iso_name found in $checksum_file" >&2; exit 1; }
expected_sha256="${checksum_line##*= }"
[[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "malformed SHA256 value for $iso_name in $checksum_file: $expected_sha256" >&2; exit 1; }

iso_path="$dest/$iso_name"
verified_marker="$iso_path.sha256-verified"

if [[ -f "$iso_path" && -f "$verified_marker" && "$(cat "$verified_marker")" == "$expected_sha256" ]]; then
  echo "$iso_path"
  exit 0
fi

echo "downloading $iso_name from $resolved_url..." >&2
curl -sS -f -o "$iso_path.part" "${resolved_url}${iso_name}" \
  || { echo "could not download ${resolved_url}${iso_name}" >&2; exit 1; }
mv "$iso_path.part" "$iso_path"

actual_sha256="$(sha256sum "$iso_path" | awk '{print $1}')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  rm -f "$iso_path"
  echo "sha256 mismatch for $iso_name: expected $expected_sha256, got $actual_sha256" >&2
  exit 1
fi

echo "$expected_sha256" > "$verified_marker"
echo "$iso_path"
