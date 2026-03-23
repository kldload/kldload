# Socket Snoop - Realtime Socket Monitoring, @OR(ϵ)SOURCES

## Overview

The Socket Monitoring Tool is a powerful and lightweight solution designed for system administrators who need real-time insights into socket-level network activity on their systems. By leveraging eBPF, this tool provides detailed logs of connection states, including source and destination IP addresses, ports, process IDs (PIDs), and associated commands (COMM), as well as TCP state transitions. Socket_snoop is a poerful addition to tcpdump.

```plaintext
FEATURES:
- Captures TCP state changes (inet_sock_set_state tracepoint).
- Monitors key TCP connection states like SYN_SENT, FIN_WAIT, and TIME_WAIT.
- Tracks TCP retransmissions (tcp_retransmit_skb tracepoint), a key indicator of network issues.
- Logs the process ID (PID) and command name (COMM) associated with each connection.
- Logs connection details (source/destination IP and port, process ID, and state) to /var/log/socket_monitor.log.
- Skips noisy or invalid entries, like connections with IP 0.0.0.0.
- Maps TCP states to human-readable descriptions.
- Formats IP addresses for readability.
- Uses perf_buffer for real-time event handling.
- Can run continuously and provide live updates via the console and log file.
- Real-Time Logging: Captures and logs socket connections as they occur.
- Detailed Insights: Provides source and destination IP addresses, ports, PIDs, command names, and TCP states.
- Formatted Output: Logs are time-stamped and categorized (e.g., Opened Connection, Closed Connection, Established Connection).
- Lightweight and Efficient: Runs efficiently using eBPF without significant performance overhead.

BENEFITS:
- Simplifies network monitoring by highlighting key details often buried in more complex tools.
- Reduces the need for deep packet analysis with tools like tcpdump or wireshark.
- Enhances operational awareness for system administrators managing critical infrastructure.

LIMITATIONS:
- IP4 only (wip)
- Need to add Dynamic Filters / pid/ip/ports
- Enhance Error Handling
- Perfomance Tuning
```
## Use Cases

Security Monitoring: Detect suspicious or unauthorized network activity.
Performance Debugging: Identify network latency or dropped connections by observing TCP states.
Audit Logging: Maintain a comprehensive record of all socket-level network interactions.
Real-Time Monitoring: Observe live network activity without the complexity of tools like tcpdump or wireshark. In addition, no network frames are captured so it's perfect for high security networks.

## Install Options

## One-Shot Install/Run
```
# download repo
git clone git@github.com:unixbox-net/linux-tools.git
cd linux-tools/debian/monitoring

# install system deps
chmod +x install-deps-debian.sh
sudo ./install-deps-debian.sh

# make venv + install python deps
python3 -m venv .venv
. .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# test
pytest -q

# run socket_snoop
sudo .venv/bin/python socket_snoop.py --log-file /var/log/socket_monitor.log
```

## "Make" Install/Run
```
make setup     # installs system deps
make deps      # creates venv + pip deps
make test      # runs pytest
sudo make run  # runs the monitor
```

## As a service
```
sudo sed -i "s|/opt/socket-snoop|$HOME/linux-tools|g" systemd/socket-snoop.service
sudo cp systemd/socket-snoop.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now socket-snoop.service
sudo systemctl status socket-snoop.service
```

## Install Docker Debian 13
```
# remove old versions
sudo apt-get remove -y docker docker-engine docker.io containerd runc || true

# deps
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# gpg key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# repo for Debian 13 "trixie"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# install engine + cli + plugins
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# enable + start
sudo systemctl enable --now docker

# test
sudo docker run hello-world
```
## Build and Run Docker Image
```
cd ~/linux-tools/debian/monitoring
export DOCKER_BUILDKIT=1
sudo docker build --network host --pull -t socket-snoop:latest .

sudo docker run --rm -it \
  --privileged \
  --pid=host \
  --net=host \
  -v /lib/modules:/lib/modules:ro \
  -v /usr/src:/usr/src:ro \
  -v /sys:/sys:ro \
  -v /var/log:/var/log \
  socket-snoop:latest \
  /app/.venv/bin/python /app/socket_snoop.py --log-file /var/log/socket_monitor.log
```


### Testing
In another terminal
```
curl http://example.com/ >/dev/null 2>&1 || true
nc -vz google.com 80 || true
```


### Log Examples

Sample: /var/log/socket_monitor.log
```plaintext
Dec 30 2024 22:05:25.454 State Change: SRC=10.100.10.150:39134 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Closing (FIN_WAIT1)
Dec 30 2024 22:05:25.455 State Change: SRC=10.100.10.150:39134 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Closed
Dec 30 2024 22:05:25.455 State Change: SRC=10.100.10.150:0 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Opening (SYN_SENT)
Dec 30 2024 22:05:25.455 State Change: SRC=10.100.10.150:39136 DST=10.100.10.202:8000 PID=0 COMM=swapper/4 STATE=Connection Established
Dec 30 2024 22:05:25.836 State Change: SRC=10.100.10.150:39136 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Closing (FIN_WAIT1)
Dec 30 2024 22:05:25.836 State Change: SRC=10.100.10.150:39136 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Closed
Dec 30 2024 22:05:25.836 State Change: SRC=10.100.10.150:0 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Opening (SYN_SENT)
Dec 30 2024 22:05:25.836 State Change: SRC=10.100.10.150:39148 DST=10.100.10.202:8000 PID=0 COMM=swapper/6 STATE=Connection Established
Dec 30 2024 22:05:28.180 State Change: SRC=10.100.10.150:39148 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Closing (FIN_WAIT1)
Dec 30 2024 22:05:28.180 State Change: SRC=10.100.10.150:39148 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Closed
Dec 30 2024 22:05:28.180 State Change: SRC=10.100.10.150:0 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Opening (SYN_SENT)
Dec 30 2024 22:05:28.180 State Change: SRC=10.100.10.150:41994 DST=10.100.10.202:8000 PID=0 COMM=swapper/7 STATE=Connection Established
Dec 30 2024 22:05:28.315 State Change: SRC=10.100.10.150:0 DST=10.100.10.202:8000 PID=30512 COMM=pool-audacious STATE=Connection Opening (SYN_SENT)
Dec 30 2024 22:05:28.316 State Change: SRC=10.100.10.150:42006 DST=10.100.10.202:8000 PID=0 COMM=swapper/5 STATE=Connection Established
Dec 30 2024 22:05:28.592 State Change: SRC=10.100.10.150:42006 DST=10.100.10.202:8000 PID=30512 COMM=pool-audacious STATE=Connection Closing (FIN_WAIT1)
Dec 30 2024 22:05:28.592 State Change: SRC=10.100.10.150:42006 DST=10.100.10.202:8000 PID=30512 COMM=pool-audacious STATE=Connection Closed
Dec 30 2024 22:05:32.526 State Change: SRC=10.100.10.150:53046 DST=185.199.108.133:443 PID=3678 COMM=Chrome_ChildIOT STATE=Connection Closing (FIN_WAIT1)
Dec 30 2024 22:05:32.526 State Change: SRC=10.100.10.150:34984 DST=185.199.108.154:443 PID=3678 COMM=Chrome_ChildIOT STATE=Connection Closing (FIN_WAIT1)
Dec 30 2024 22:05:32.526 State Change: SRC=10.100.10.150:34994 DST=185.199.108.154:443 PID=3678 COMM=Chrome_ChildIOT STATE=Connection Closing (FIN_WAIT1)

```

### Breakdown's

Example 1:
```plaintext
Dec 30 2024 13:44:03.309 Connection Established: SRC=10.100.10.150:59660 DST=104.18.34.222:443 PID=0 COMM=swapper/7
```

*  Timestamp: Dec 30 2024 13:44:03.309
*  Event Type: Connection Established
*  Source (SRC): 10.100.10.150 (source IP) and 59660 (source port)
*  Destination (DST): 104.18.34.222 (destination IP) and 443 (destination port)
*  Process ID (PID): 0 (kernel-managed thread)
*  Command Name (COMM): swapper/7 (kernel idle thread for CPU core 7)

Example 2:
```plaintext
Dec 30 2024 13:44:03.345 Connection Opening (SYN_SENT): SRC=10.100.10.150:0 DST=35.244.154.8:443 PID=3382 COMM=Chrome_ChildIOT
```

*  Timestamp: Dec 30 2024 13:44:03.345
*  Event Type: Connection Opening (SYN_SENT)
*  Source (SRC): 10.100.10.150 (source IP) and 0 (port not yet assigned as connection is opening)
*  Destination (DST): 35.244.154.8 (destination IP) and 443 (destination port)
*  Process ID (PID): 3382 (user-space process ID)
*  Command Name (COMM): Chrome_ChildIOT (child process of Chrome browser)

Example 3:
```plaintext
Monitoring socket connections with enhanced metrics. Logs will be written to /var/log/socket_monitor.log
Dec 30 2024 22:00:46.334 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62382 PID=0 COMM=swapper/0 STATE=Connection Closing (CLOSE_WAIT)
Dec 30 2024 22:00:46.337 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62382 PID=43190 COMM=sshd-session STATE=Connection Closing (LAST_ACK)
Dec 30 2024 22:00:46.350 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62382 PID=0 COMM=swapper/0 STATE=Connection Closed
Dec 30 2024 22:00:46.372 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62383 PID=0 COMM=swapper/3 STATE=Connection Closing (CLOSE_WAIT)
Dec 30 2024 22:00:46.375 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62383 PID=43194 COMM=sshd-session STATE=Connection Closing (LAST_ACK)
Dec 30 2024 22:00:46.377 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62383 PID=0 COMM=swapper/3 STATE=Connection Closed
Dec 30 2024 22:00:47.799 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62407 PID=0 COMM=swapper/5 STATE=Connection Established
Dec 30 2024 22:00:47.929 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62408 PID=0 COMM=swapper/7 STATE=Connection Established
^C
```

Connection Report:
```plaintext
Stopping monitoring...

Connection Lifecycles:
Connection: 10.100.10.150:22 -> 10.100.10.197:62382
  Dec 30 2024 22:00:46.334: Connection Closing (CLOSE_WAIT)
  Dec 30 2024 22:00:46.337: Connection Closing (LAST_ACK)
  Dec 30 2024 22:00:46.350: Connection Closed
Connection: 10.100.10.150:22 -> 10.100.10.197:62383
  Dec 30 2024 22:00:46.372: Connection Closing (CLOSE_WAIT)
  Dec 30 2024 22:00:46.375: Connection Closing (LAST_ACK)
  Dec 30 2024 22:00:46.377: Connection Closed
Connection: 10.100.10.150:22 -> 10.100.10.197:62407
  Dec 30 2024 22:00:47.799: Connection Established
Connection: 10.100.10.150:22 -> 10.100.10.197:62408
  Dec 30 2024 22:00:47.929: Connection Established
```
The following is an example output of the tool monitoring SSH connections (SRC=10.100.10.150:22) between a server and a client (DST=10.100.10.197):

A connection lifecycle starts with an Established state, 
transitions through CLOSE_WAIT, 
and eventually reaches Closed.
Each state change is associated with the process managing it (e.g., sshd-session or swapper).

# Frequently Asked Questions (FAQ)

---

### 1. How is Socket Snoop different from tcpdump or Wireshark?
- **tcpdump/wireshark** capture **packets** (payloads, headers, full frames).  
- **socket_snoop** captures **events at the socket level** (who opened/closed connections, which process, what IP/port).  
- Benefit: no packet payloads → less noisy, more privacy-friendly, and easier to parse.  
- Example:  
  - tcpdump might show: `SYN 192.168.1.10:54321 -> 172.217.0.46:443`  
  - socket_snoop shows: `PID=1234 COMM=curl opened connection to google.com:443`.  

---

### 2. Why should I use Socket Snoop instead of tcpdump/wireshark?
- When you care about **which process/PID** created the connection.  
- When you want **real-time event logs** without packet captures.  
- When you need to debug **application-level network issues** (not low-level packet flows).  
- Faster setup: one script, no filters needed.  

---

### 3. How does Socket Snoop compare to Prometheus/Grafana?
- **Socket Snoop**: forensic/debug tool, process-level visibility, real-time logs.  
- **Prometheus/Grafana**: monitoring tool, long-term metrics, dashboards.  
- Use both: Socket Snoop for debugging *now*, Prometheus for monitoring *trends*.  

---

### 4. Does it replace tcpdump or wireshark?
- No — it **complements** them.  
- tcpdump/wireshark are for deep packet inspection.  
- socket_snoop is for **connection lifecycle visibility** (who, when, how).  

---

### 5. What are practical use cases?
- **Security**: detect unexpected outbound connections (`PID=1234 COMM=nc connecting to 203.x.x.x:22`).  
- **Debugging**: verify whether an app retries connections or leaks sockets.  
- **Performance**: identify retransmits or excessive TIME_WAIT states.  
- **Auditing**: maintain logs of which process accessed which remote host.  
- **Forensics**: run on a server under investigation to see live connections without dumping traffic.  

---

### 6. Can it monitor all containers or just the host?
- With `--pid=host --net=host` in Docker, it can monitor **all host + container connections**.  
- In Kubernetes, run as a privileged DaemonSet for node-wide monitoring.  

---

### 7. Is this lightweight? Will it slow my server?
- Yes, it’s lightweight.  
- Runs via **eBPF** tracepoints (kernel-supported, low overhead).  
- No packet copying, no payloads captured → minimal performance cost.  

---

### 8. What about IPv6?
- Currently supports **IPv4 only** (work in progress).  
- IPv6 support can be added by extending the BPF program.  

---

### 9. Can I run it as a background service?
- Yes.  
- A systemd service is included:  
  ```bash
  sudo cp systemd/socket-snoop.service /etc/systemd/system/
  sudo systemctl enable --now socket-snoop.service
  sudo systemctl status socket-snoop.service
