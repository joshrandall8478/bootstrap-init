# Ports

Syncthing requires port 22000 TCP/UDP for sync connections and 21027 UDP for local discovery.
Sometimes the phone does not connect over the Nebula network, and without the local network as a
fallback, the connection fails. The firewall commands allow for the local network.

The Docker `compose.yaml` adds these ports to the host. This is required for all configurations.
```yaml
      # TCP based sync protocol traffic
      - target: 22000
        published: 22000
        protocol: "tcp"
        mode: "host"
      # QUIC based sync protocol traffic
      - target: 22000
        published: 22000
        protocol: "udp"
        mode: "host"
      # Discovery broadcasts on IPv4 and multicasts on IPv6
      - target: 21027
        published: 21027
        protocol: "udp"
        mode: "host"
```

The Nebula firewall rules allow incoming traffic from the Nebula network.
```yaml
    # ---
    # Allow tcp/22000 (syncthing)
    - port: 22000
      proto: tcp
      host: any
    # ---
    # Allow udp/22000 (syncthing)
    - port: 22000
      proto: udp
      host: any
    # ---
    # Allow udp/21027 (syncthing)
    - port: 21027
      proto: udp
      host: any
```

The firewall rules allow incoming traffic from the local network. The local IP may need to be used
in the Syncthing device connection option to force discovery using the LAN.
```bash
firewall-cmd --zone public --add-port 22000/tcp
firewall-cmd --zone public --add-port 22000/udp
firewall-cmd --zone public --add-port 21027/udp
firewall-cmd --runtime-to-permanent
```

If the Nebula network is not available, the LAN IP can be entered to force the LAN discovery.
```text
tcp://computer-01.nebula.example.com, tcp://10.10.10.10, dynamic
```
