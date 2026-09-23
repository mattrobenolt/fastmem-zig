# NixOS configuration for every benchmark box.
#
# infra/base puts this file in the launch template user_data. On boot, the
# amazon-init service of the official NixOS AMI copies it to
# /etc/nixos/configuration.nix and runs `nixos-rebuild switch` against the
# channel that the AMI ships. The file must evaluate against that channel
# (nixos-25.11 for the pinned AMIs), not against the flake of this repo.
# amazon-init reads a line that starts with three hash signs as a channel
# URL, and a file that starts with #! as a shell script. Avoid both.
#
# Bump `imageVersion` when a change here matters to the harness, and bump
# `image_version` in bench.toml to the same value. The harness waits until
# /etc/bench-image matches `image_version`.
{ pkgs, lib, ... }:
let
  imageVersion = "1";

  # TTL guard: power off after the ExpiresAt instance tag. The launch template
  # sets shutdown behavior to terminate, so poweroff destroys the instance.
  ttlGuard = ''
    set -u
    imds=http://169.254.169.254/latest
    state=/run/bench-ttl-guard
    fallback_seconds=$((12 * 3600))

    now=$(date -u +%s)
    expires=""

    # IMDSv2: get a session token, then read the tag. curl prints 000 as the
    # HTTP code when it cannot connect.
    code=000
    if token=$(curl -sf -m 2 -X PUT \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' "$imds/api/token"); then
      code=$(curl -s -m 2 -o "$state/tag" -w '%{http_code}' \
        -H "X-aws-ec2-metadata-token: $token" \
        "$imds/meta-data/tags/instance/ExpiresAt") || true
    fi

    case $code in
      200)
        # The tag is RFC 3339 UTC, for example 2026-09-24T04:00:00Z. Check the
        # shape first: `date -d` also accepts "" and words like "tomorrow".
        value=$(cat "$state/tag")
        rfc3339='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
        if [[ $value =~ $rfc3339 ]] && expires=$(date -u -d "$value" +%s); then
          echo "$expires" >"$state/expires-at"
        else
          echo "ExpiresAt tag '$value' is not an RFC 3339 UTC time; using the fallback"
          expires=""
          rm -f "$state/expires-at"
        fi
        ;;
      404)
        # No ExpiresAt tag, or instance metadata tags are off.
        rm -f "$state/expires-at"
        ;;
      *)
        # IMDS did not answer. Keep the last value that it gave, so that a
        # short IMDS fault does not stop a box that has a long TTL.
        echo "IMDS read failed (HTTP $code)"
        if [ -s "$state/expires-at" ]; then
          expires=$(cat "$state/expires-at")
        fi
        ;;
    esac

    if [ -z "$expires" ]; then
      uptime=$(cut -d. -f1 /proc/uptime)
      expires=$((now - uptime + fallback_seconds))
    fi

    if [ "$now" -ge "$expires" ]; then
      echo "TTL expired at $(date -u -d "@$expires" +%Y-%m-%dT%H:%M:%SZ); powering off"
      poweroff
    fi
  '';
in
{
  imports = [
    <nixpkgs/nixos/modules/virtualisation/amazon-image.nix>
  ];

  # The release of the pinned AMIs. It controls stateful defaults only.
  system.stateVersion = "25.11";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.settings.download-buffer-size = 134217728;

  # The harness ships dynamically linked binaries that use the standard
  # interpreter paths (/lib64/ld-linux-x86-64.so.2, /lib/ld-linux-aarch64.so.1).
  programs.nix-ld.enable = true;

  # Disable ASLR for stable benchmark addresses and fewer page-table variations.
  boot.kernel.sysctl."kernel.randomize_va_space" = 0;
  boot.kernel.sysctl."kernel.perf_event_paranoid" = -1;
  boot.kernel.sysctl."kernel.kptr_restrict" = 0;

  # Mask services not needed during benchmarking to reduce timer interrupts
  # and background CPU noise. mkForce: the amazon-image module sets some of
  # these (serial-getty@ttyS0, amazon-ssm-agent) at default priority, which
  # conflicts with a plain `false` — the eval fails and the first-boot
  # rebuild never lands.
  # NOTE: do NOT disable dhcpcd — it owns the interface on the EC2 image;
  # stopping it at the first-boot switch deconfigures the leased address and
  # the instance becomes unreachable seconds after boot. Its idle cost is
  # one renewal per hour; not worth losing the box.
  systemd.services.amazon-ssm-agent.enable = lib.mkForce false;
  systemd.services.systemd-timesyncd.enable = lib.mkForce false;
  systemd.services.systemd-oomd.enable = lib.mkForce false;
  systemd.services."serial-getty@ttyS0".enable = lib.mkForce false;

  environment.systemPackages = with pkgs; [
    rsync
    binutils
    util-linux
    perf
    jq
  ];

  environment.etc."bench-image".text = "${imageVersion}\n";

  systemd.services.bench-ttl-guard = {
    description = "Power off the box after its ExpiresAt tag";
    path = [ pkgs.curl ];
    script = ttlGuard;
    serviceConfig = {
      Type = "oneshot";
      RuntimeDirectory = "bench-ttl-guard";
      # Keep the last ExpiresAt value between runs of this oneshot service.
      RuntimeDirectoryPreserve = "yes";
    };
  };

  systemd.timers.bench-ttl-guard = {
    description = "Check the box TTL every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      AccuracySec = "5s";
    };
  };
}
