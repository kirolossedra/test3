from mininet.net import Mininet
from mininet.topo import Topo
from mininet.node import Node, OVSSwitch
from mininet.cli import CLI
from mininet.link import TCLink
from mininet.node import RemoteController
from mininet.log import setLogLevel, info

from mininet.node import Node

class LoadBalancer(Node):
    """Dual-homed LB that is locked down by default.
       Later, call open_tcp_service(...) to allow exactly one service path."""
    def config(self, **params):
        super().config(**params)

        self.cmd('sysctl -w net.ipv4.ip_forward=0')

class LoadBalancerTopo(Topo):
    def build(self, delay = '0ms'):

        # Network 1 (Left-hand Network)
        # hX = Clients
        h1 = self.addHost(name="h1", ip="10.0.0.2/24", defaultRoute="via 10.0.0.9")
        h2 = self.addHost(name="h2", ip="10.0.0.3/24", defaultRoute="via 10.0.0.9")
        h3 = self.addHost(name="h3", ip="10.0.0.4/24", defaultRoute="via 10.0.0.9")
        s1 = self.addSwitch(name='s1')
        self.addLink(h1, s1)
        self.addLink(h2, s1)
        self.addLink(h3, s1)

        # Network 2 (Right-hand Network)
        # bX = Back-End Servers
        b1 = self.addHost(name="b1", ip="20.0.0.3/24", defaultRoute="via 20.0.0.2")
        b2 = self.addHost(name="b2", ip="20.0.0.4/24", defaultRoute="via 20.0.0.2")
        b3 = self.addHost(name="b3", ip="20.0.0.5/24", defaultRoute="via 20.0.0.2")
        s2 = self.addSwitch(name="s2")
        self.addLink(b1, s2)
        self.addLink(b2, s2)
        self.addLink(b3, s2)

        # Load Balancer
        lb = self.addHost(name="lb", cls=LoadBalancer, ip=None) 
       
        self.addLink(lb, s1, intfName1="lb-eth0", params1={"ip": "10.0.0.9/24"})
        self.addLink(lb, s2, intfName1="lb-eth1", params1={"ip": "20.0.0.2/24"})

if __name__ == '__main__':
    topology = LoadBalancerTopo()
    network = Mininet(topo=topology, link=TCLink, controller=lambda name:RemoteController(name, p='127.0.0.1', port=6633))
    network.start()

    network.get('h1')
    network.get('h2')
    network.get('h3')

    network.get('b1')
    network.get('b2')
    network.get('b3')

    network.get('lb')

    CLI(network)
    network.stop()
