Here is the full plaintext reconstruction of the "Load Balancing" lab assignment based on the document provided.

---

# University of Waterloo - Department of Electrical and Computer Engineering

ECE 358: Computer Networks | Lab X: Load Balancing 

## 1. Overview

In this lab, you'll explore common load-balancing algorithms used to distribute client traffic across multiple servers, preventing hotspots and improving throughput, latency, scalability, and availability. Load balancers exist in different areas, including distributed systems, cloud computing, and computer networks.

From a client's perspective, the load balancer is a single point of contact (such as a front-end server) that receives client requests and forwards them to a pool of back-end servers. These servers process the request and send responses to the load balancer, which forwards them back to the client.

Designing a good load balancer typically considers factors such as workload type, server resource availability, geographical distribution, link bandwidth, latency, and protocols. They are generally categorized into:

* 
**Dynamic load balancers:** Consider the current state of each server before forwarding a request.


* 
**Static load balancers:** Distribute traffic without adjusting for server state, usually relying on sending an equal amount of traffic to each server.



## 2. Learning Objectives

By the end of this lab, students should be able to:

1. Explain how a network load balancer operates at the OSI model 4th layer, including its role in request routing and response handling.


2. Configure and run a Mininet topology; verify connectivity and enforce isolation.


3. Implement request forwarding logic at the Front End (FE) and track per-backend state (e.g., active connections).


4. Implement a round-robin load balancing algorithm.


5. Implement a thread-safe load balancer in Python.



## 3. Prerequisites

* **Background:** Lecture on load balancing; ARP/Ethernet; TCP/UDP basics; hashing.


* 
**Tools:** Mininet VM (provided), Python 3, ping, iperf3 or a simple Python client/server, tcpdump/Wireshark (optional).


* 
**Skills:** Basic Linux CLI; editing/running Python.



## 4. Lab Topology

You will use the starter code to create the logical topology described below. Read the socket (`ip_address:port`) assignment carefully.

### Network Configuration

**Clients (Connected to switch s1):**

* 
**h1:** `eth0: 10.0.0.2/24` 


* 
**h2:** `eth0: 10.0.0.3/24` 


* 
**h3:** `eth0: 10.0.0.4/24` 



**Load Balancer (lb):**

* 
**eth0:** `10.0.0.9:5000` (facing clients/s1) 


* 
**eth1:** `20.0.0.2:6000` (facing backends/s2) 



**Back Ends (Connected to switch s2):**

* 
**b1:** `eth0: 20.0.0.3:6000` 


* 
**b2:** `eth0: 20.0.0.4:6000` 


* 
**b3:** `eth0: 20.0.0.5:6000` 



All networks have a subnet mask of `/24`.

### Connectivity Rules

* **Clients (h1-h3):** Can communicate with each other and the load balancer (lb). Cannot communicate with back-end servers (b1-b3).


* **Load Balancer (lb):** Can communicate with h1, h2, h3 via interface `eth0`. Can communicate with b1, b2, b3 via interface `eth1`. It dispatches client requests to backends and forwards responses back to clients.


* **Back Ends (b1-b3):** Can communicate with each other and the load balancer. Cannot communicate with clients.



**Note:** Due to Mininet virtual switching, you cannot fully disable communication between `hX` and `lb-eth1` or `bX` and `lb-eth0`. The important isolation aspect is that `hX` and `bX` cannot communicate with each other.

## 5. Tasks

### Starter Code Content

You are provided with: `client.py`, `backend_server.py`, a folder with 10 sample inputs, `load_balancer.py` (primitive code), `lab_topology.py` (primitive topology), and a bash script to instantiate servers.

### Task 1: Setup Network Isolation

Your first deliverable is to finish the network topology code in `lab_topology.py`.

**You Must:**

* Configure network interfaces for clients (h1, h2, h3), backend servers (b1, b2, b3), and the load balancer.


* Ensure appropriate connectivity between network nodes.


* Ensure appropriate network isolation between network nodes.



**You Must NOT:**

* Change hostnames for clients or backends in `lab_topology.py` (Penalty: 0 marks for the assignment).


* Change the filename `lab_topology.py`.


* Hardcode ports on hosts; ensure ports are handled in the Python script.



#### Verification Steps (Instructor Orientation)

Use the following workflow to verify your topology:

1. Check IP addresses with `ifconfig` (e.g., `mininet> h1 ifconfig`).


2. Check connectivity between clients (e.g., `mininet> h1 ping 10.0.0.3`).


3. Check connectivity between backends (e.g., `mininet> b1 ping 20.0.0.4`).


4. Check connectivity between clients and load-balancer (e.g., `mininet> h1 ping 10.0.0.9`).


5. Check connectivity between backends and load-balancer (e.g., `mininet> b1 ping 20.0.0.2`).


6. 
**Check isolation** between backends and clients (e.g., `mininet> b1 ping 10.0.0.3`) — this should fail.



### Task 2: Implement the Round-Robin Load Balancer Algorithm

Your second deliverable is to implement the round-robin algorithm on the load balancer.

**You Must:**

* Configure a **thread-safe** load balancer that forwards incoming requests to backends using round-robin, receives responses, and sends them back to the correct client.


* Respect the communication contract between network nodes.



**You Must NOT:**

* Change the filename `load_balancer.py`.


* Change code sections marked as `DO NOT CHANGE`.



**You Should:**

* Adapt `client.py` and `backend_server.py` to ensure the load balancer sends the correct response to the correct client.


* Test with single client/multiple requests and multiple clients/concurrent requests.



### Communication Contract & JSON Formats

The request and response payloads are sent in JSON format as follows:

1. **Client -> Load Balancer:**
* Payload: Request ID and graph data.


* JSON Structure: `{"graph": data, "req_id": req_id}`.




2. **Load Balancer -> Backend Server:**
* Payload: Client IP, request ID, and graph data.


* JSON Structure: `{"graph": data, "req_id": req_id, "client_ip": client_ip}`.




3. **Backend Server -> Load Balancer:**
* Payload: Backend IP, vertex count, client IP, and request ID.


* JSON Structure: `{"vertex_count": data, "req_id": req_id, "client_ip": client_ip, "backend_ip": backend_ip}`.




4. **Load Balancer -> Client:**
* Payload: Backend name (b1, b2, or b3), vertex count, client IP, and request ID.


* JSON Structure: `{"vertex_count": data, "req_id": req_id, "client_ip": client_ip, "backend": be_name}`.





**Instructor Note:** Be careful with **thread safety** and request/response relationships. It is easy to receive a request from one client and send the response to another. Ensure the round-robin algorithm works correctly.

## 6. Reflection Questions

Students must answer the following in their report:

1. How would you make this implementation scale with the number of clients? 


2. In which cases is the round-robin a good load-balancing algorithm? 


3. How could you make this load balancer fault tolerant? 



## 7. Deliverables

Students should submit:

* The correct network topology implementation in `lab_topology.py`.


* The correct load balancer code implemented as `load_balancer.py`.


* 
*Note:* You can submit `client.py` and `backend_server.py`, but they will not be graded.



## 8. Grading Rubric (10 points total)

* 
**Up to 1 point:** Correct IP address configuration in `lab_topology.py`.


* 
**Up to 2 points:** Correct network connectivity and isolation in `lab_topology.py`.


* 
**Up to 3 points:** Test case where only 1 client is sending requests.


* 
**Up to 4 points:** Test case where more than 1 client is sending requests.



## 9. Instructor Notes

* Expected run time: ~2 minutes.



---

**Next Step:** Would you like me to outline the logic for `load_balancer.py` to ensure it meets the thread-safety and round-robin requirements?
