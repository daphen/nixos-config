{ config, pkgs, inputs, ... }:

{
  # Network Configuration
  # =====================
  
  # Enable NetworkManager
  networking.networkmanager = {
    enable = true;
    wifi.powersave = false;  # only honored when NM owns wlan0 directly — see service below
  };

  # Enable IWD (iNet Wireless Daemon) as backend for NetworkManager
  networking.wireless.iwd.enable = true;
  networking.networkmanager.wifi.backend = "iwd";

  # NM's wifi.powersave=false does NOT apply when iwd is the backend — NM hands
  # off device management to iwd and the kernel default (power_save=on) sticks.
  # That caused 100-400ms ping spikes to the gateway from MT7925 dozing between
  # AP beacons. Force power_save off at boot + after resume.
  systemd.services.wifi-powersave-off = {
    description = "Disable WiFi power save on wlan0";
    wants = [ "iwd.service" ];
    after = [ "iwd.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.iw}/bin/iw dev wlan0 set power_save off";
    };
  };
  powerManagement.resumeCommands = ''
    ${pkgs.iw}/bin/iw dev wlan0 set power_save off || true
  '';

  # Firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];
  };

  # Prefer IPv4 over IPv6 in DNS resolution
  # IPv6 connections to some services (e.g. Spotify dealer) time out
  environment.etc."gai.conf".text = ''
    precedence ::ffff:0:0/96 100
  '';

  # DNS
  services.resolved = {
    enable = true;
    settings.Resolve.DNSSEC = "false";
  };

  # GoLinks - maps "go" hostname to GoLinks' server so http://go/* works in all browsers
  networking.hosts = {
    "52.72.13.96" = [ "go" ];
  };

  # Tailscale - lovbox requires it; also resolves internal.lovable.net for
  # tsauth.DevResolver (previously worked around by pointing the host at
  # 127.0.0.1, now removed above).
  #
  # --accept-routes is load-bearing: lovable infra advertises subnet routes
  # (e.g. internal.lovable.net at 185.41.151.3) via tailscale-subnet-router-*
  # peers. Without accepting them, the public-IP destinations time out
  # because traffic goes out the default route instead of through the tailnet.
  services.tailscale = {
    enable = true;
    # From the fresher pin: LoL preview rejects older clients.
    package = inputs.nixpkgs-latest.legacyPackages.${pkgs.system}.tailscale;
    extraUpFlags = [ "--accept-routes" ];
  };

  # IPv6 strategy: enabled on loopback, disabled on every external interface.
  #
  # Original problem (solved by ipv6.disable=1): wlan0 got a link-local
  # IPv6 address from NetworkManager/iwd before the
  # net.ipv6.conf.wlan0.disable_ipv6 sysctl could take effect. Go's HTTP
  # client did Happy Eyeballs on external services (Confidence/Spotify CDN,
  # gcloud auth, etc.) → 30s timeouts before IPv4 fallback.
  #
  # New problem ipv6.disable=1 introduced: Chromium resolves localhost
  # and *.localhost to BOTH 127.0.0.1 and ::1 (RFC 6761 hardcoded). With
  # the IPv6 stack gone entirely, every fetch eats a multi-second Happy
  # Eyeballs penalty on the fallback from ::1 → 127.0.0.1. Local dev
  # browsing was 50× slower than colleagues on macOS.
  #
  # This config solves both: keep the IPv6 stack so ::1 works (no browser
  # penalty), but prevent any external interface from acquiring an IPv6
  # address (no Go-client timeouts). NetworkManager is the timing-correct
  # place to disable per-connection IPv6 — sysctl alone was unreliable
  # because NM brings interfaces up after the activation script runs.
  networking.networkmanager.connectionConfig = {
    "ipv6.method" = "disabled";
  };

  # Belt-and-suspenders for any interface NM doesn't manage (docker bridges,
  # virtual ifs, etc.). Loopback stays enabled so ::1 works.
  boot.kernel.sysctl = {
    "net.ipv6.conf.default.disable_ipv6" = 1;
    "net.ipv6.conf.all.disable_ipv6" = 1;
    "net.ipv6.conf.lo.disable_ipv6" = 0;
  };

  # Block link-local (169.254.0.0/16) from being routed off-link.
  #
  # RFC 3927: link-local addresses are reserved for on-link
  # auto-configuration and must not traverse routers. macOS adds a
  # link-scoped route for this range automatically when an interface
  # comes up; Linux on NixOS does not. Without this rule, traffic to
  # 169.254.x.x falls through to the default route, the gateway
  # silently drops the packets, and TCP times out after 5-30 seconds.
  #
  # Concrete impact: every Google/AWS/Azure cloud SDK probes
  # 169.254.169.254 (the industry-convention metadata-service address)
  # at startup or per-call to detect "am I running on a cloud VM?".
  # Off-cloud, that probe ate a 5s timeout per call, which manifested
  # as every authenticated API call in local dev being 5s slow
  # (Firebase Admin SDK's VerifyIDToken was the visible symptom).
  #
  # `prohibit` makes the kernel reject the route immediately with
  # EHOSTUNREACH/EACCES, so the SDK probe fails in microseconds and
  # falls back to file-based credentials (~/.config/gcloud/...).
  # Applied via localCommands so it runs on every activation without
  # needing to enumerate interfaces.
  networking.localCommands = ''
    ip route replace prohibit 169.254.0.0/16 || true
  '';

  # Additional network tools
  # NetworkManager is already included by enabling the service
  # environment.systemPackages = with pkgs; [
  #   # networkmanager-dmenu  # TODO: Find correct package name
  # ];
}
