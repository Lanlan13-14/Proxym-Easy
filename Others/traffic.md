How to use？
```
wget https://ex-files.leikwanhost.com/traffic.sh && chmod +x traffic.sh && bash traffic.sh
```
And
```
curl -fsSL https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/Others/traffic.sh -o ~/traffic.sh && chmod +x ~/traffic.sh && ln -sf ~/traffic.sh /usr/local/bin/traffic-easy && traffic-easy
```
Sure! Here's a complete English version of the Traffic Easy usage guide:


---

Traffic Easy Usage Guide

---

1️⃣ Installation & Startup

One-line installation and menu launch
```
wget https://ex-files.leikwanhost.com/traffic.sh && chmod +x traffic.sh && bash traffic.sh
```
And
```
curl -fsSL https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/Others/traffic.sh -o ~/traffic.sh && chmod +x ~/traffic.sh && ln -sf ~/traffic.sh /usr/local/bin/traffic-easy && traffic-easy
```

Explanation:

1. Downloads traffic.sh to your home directory.


2. Makes it executable.


3. Creates a global command link traffic-easy.


4. Immediately launches the menu.



After this, you can always run:

traffic-easy

to bring up the configuration menu.


---

2️⃣ Menu Features

When you run traffic-easy, you will see:

====== Traffic Easy ======
1) Basic interval settings
2) Daytime settings
3) Nighttime settings
4) Daily traffic limit
5) Logging options
6) Save & start (daemon + auto-start)
7) Stop daemon & systemd
8) Stop & delete completely
0) Exit

Menu Descriptions

1. Basic Interval Settings

Set the interval between download cycles (seconds).



2. Daytime Settings

Day start hour (0~23)

Day end hour (0~23)

Thread min/max

Rate min/max (MB/s)

Total min/max per cycle (MB)



3. Nighttime Settings

Thread, rate, and total per cycle for nighttime (similar to daytime).



4. Daily Traffic Limit

Set the maximum download per day (MB).



5. Logging Options

Enable or disable logging (yes/no)

Set log retention in hours (default 24)

Disabling logs deletes existing logs



6. Save & Start

Saves the configuration to ~/.traffic-easy.conf

Starts systemd daemon for background execution

Enables auto-start on boot



7. Stop Daemon & systemd

Stops the running script daemon

Stops the systemd service



8. Stop & Delete Completely

Stops daemon

Deletes systemd service

Deletes logs, state, configuration files

Deletes the script itself



9. Exit

Exits the menu without starting or saving.





---

3️⃣ systemd Management

Service name: teasy.service


Check status:

systemctl status teasy.service

Enable/auto-start:

systemctl is-enabled teasy.service

View logs:

journalctl -u teasy.service -n 50 --no-pager

Stop:

systemctl stop teasy.service

Restart:

systemctl restart teasy.service

Disable auto-start:

systemctl disable teasy.service


---

4️⃣ Config & State Files

Config file: ~/.traffic-easy.conf

State file: ~/.traffic-easy.state (tracks daily usage)

Log file: ~/logs/traffic-easy.log (can be disabled)


Check current configuration:

cat ~/.traffic-easy.conf

Check daily usage:

cat ~/.traffic-easy.state

Tail live log:

tail -f ~/logs/traffic-easy.log


---

5️⃣ Example Settings

Example for a 24-hour schedule:

Daytime: 8:00–22:00

Daytime threads: 2–5

Daytime rate: 10–20 MB/s

Daytime total per cycle: 500–1000 MB

Nighttime threads: 1–3

Nighttime rate: 5–15 MB/s

Nighttime total per cycle: 200–600 MB

Daily limit: 5000 MB

Log retention: 24 hours


Set these values in the menu and choose 6) Save & start.


---

6️⃣ Quick Commands

Check status:
```
traffic-easy status
```
Stop daemon:
```
traffic-easy stop

Delete script & all files:

traffic-easy delete
```