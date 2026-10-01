# shellcheck shell=sh
case ":$PATH:" in
  *":/usr/local/share/mise/shims:"*) ;;
  *) export PATH="$PATH:/usr/local/share/mise/shims" ;;
esac
