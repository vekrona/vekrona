pragma Singleton
import Quickshell

Singleton {
    function detached(argv: list<string>): void {
        Quickshell.execDetached(["systemd-run", "--user", "--scope", "--collect", "--quiet", "--"].concat(argv));
    }
}
