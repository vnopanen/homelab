TODO: automate file browser config creation
https://filebrowserquantum.com/en/docs/getting-started/docker/#step-2-create-config

add to setup:
uidmap — Provides newuidmap and newgidmap for rootless user/group namespace mapping.

passt — Provides the pasta network namespace backend.

aardvark-dns — Handles container-to-container DNS resolution.

netavark — The container network stack manager.

nftables — Required firewall backend used by netavark.

dbus-user-session — Initializes the user-level D-Bus session bus required for systemd user unit management and cgroup integration.
