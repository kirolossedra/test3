#!/usr/bin/env python3
from mininet.net import Mininet
from mininet.node import OVSSwitch
from mininet.link import TCLink
from mininet.cli import CLI
from mininet.log import setLogLevel, info


def build_topology():
    net = Mininet(link=TCLink, switch=OVSSwitch, controller=None, autoSetMacs=True)

    info("*** Creating switches\n")
    s1 = net.addSwitch("s1")
    s2 = net.addSwitch("s2")

    info("*** Creating hosts\n")
    # Clients
    h1 = net.addHost("h1")
    h2 = net.addHost("h2")
    h3 = net.addHost("h3")

    # Load balancer (2 interfaces)
    lb = net.addHost("lb")

    # Backends
    b1 = net.addHost("b1")
    b2 = net.addHost("b2")
    b3 = net.addHost("b3")

    info("*** Creating links\n")
    # Clients <-> s1
    net.addLink(h1, s1)
    net.addLink(h2, s1)
    net.addLink(h3, s1)

    # Backends <-> s2
    net.addLink(b1, s2)
    net.addLink(b2, s2)
    net.addLink(b3, s2)

    # Load balancer has 2 NICs: one to each switch
    net.addLink(lb, s1)  # will become lb-eth0
    net.addLink(lb, s2)  # will become lb-eth1

    info("*** Starting network\n")
    net.start()

    info("*** Configuring interfaces / IP addresses\n")
    # Clients on 10.0.0.0/24
    h1.setIP("10.0.0.2/24", intf="h1-eth0")
    h2.setIP("10.0.0.3/24", intf="h2-eth0")
    h3.setIP("10.0.0.4/24", intf="h3-eth0")

    # Load balancer interfaces
    lb.setIP("10.0.0.9/24", intf="lb-eth0")
    lb.setIP("20.0.0.2/24", intf="lb-eth1")

    # Backends on 20.0.0.0/24
    b1.setIP("20.0.0.3/24", intf="b1-eth0")
    b2.setIP("20.0.0.4/24", intf="b2-eth0")
    b3.setIP("20.0.0.5/24", intf="b3-eth0")

    # Bring interfaces up (usually already up, but this makes it explicit)
    for h in [h1, h2, h3, lb, b1, b2, b3]:
        h.cmd("ip link set dev %s-eth0 up" % h.name)
    lb.cmd("ip link set dev lb-eth1 up")

    info("*** Enforcing isolation (no routing between client and backend networks)\n")
    # Make sure lb does NOT forward packets between eth0 and eth1
    lb.cmd("sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1")

    # Flush any old rules and then block forwarding across interfaces
    lb.cmd("iptables -F")
    lb.cmd("iptables -P FORWARD DROP")

    # Allow lb itself to talk to both sides (INPUT/OUTPUT), but do not route between them
    lb.cmd("iptables -P INPUT ACCEPT")
    lb.cmd("iptables -P OUTPUT ACCEPT")

    # Also make sure clients/backends don't have accidental default routes
    for h in [h1, h2, h3, b1, b2, b3]:
        h.cmd("ip route del default >/dev/null 2>&1 || true")

    info("*** Topology is up. Dropping into Mininet CLI.\n")
    return net


if __name__ == "__main__":
    setLogLevel("info")
    net = build_topology()
    CLI(net)
    net.stop()
