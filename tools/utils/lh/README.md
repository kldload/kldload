<img width="1177" height="569" alt="image" src="https://github.com/user-attachments/assets/907a3fd5-7aa5-41df-8d59-21919848572f" />

## LogHog (lh)

The ultimate log ferensics tool that ANYONE can use.

## "modes"

**TAIL**  *Default*
Automatically stitches logs together by timestamp, enabling real-time event monitoring. This mode makes 
it easy to follow and investigate incidents like authentication failures, permission denials, and SQL 
injections. **Press `CTRL+C`** to quit.

**LESS**  *Secondary*
Buffers are sent directly to **less** for further editing and in-depth review, searches, and complex log 
analysis.  
**Press `h` for help** or **`q` to quit to menu**.

### Features

- **(A)uth** – Find every authentication error instantly.  
- **(E)rrors** – Identify all system errors effortlessly.  
- **(L)ive All** – A special version of `tail` that stitches logs together from all sources, appending them by timestamp for proper ordering.  
- **(N)etwork** – Analyze and dissect anything related to networking protocols.  
- **(R)egEX** – Simplified or complex regex parser. No need for complex syntax—just separate keywords like `error|fail|warn|etc`.  
- **(I)P Search** – Locate and extract IP addresses automatically.  
- **(S)et Log Paths** – Define custom log file paths.  
- **(J)SON Export** – Output logs in structured JSON format.  
- **(H)elp** – Quick reference guide for usage.  

**Remote Operation**
Changing paths also accepts network shares / mounts and devices, allowing for consumption of logs from ANY TARGET local or remote.


## Other key features include:
  
**Regex Search**: Allows powerful searches across all logs using regular expressions, making it simple to detect 
patterns like IP addresses, error messages, and unauthorized access attempts. 

**Network Protocol Filter**: Filters logs by protocol (HTTP, FTP, SSH, etc.) to quickly identify network-related 
issues.

**Error Filtering**: Isolates error-related events like failures, critical warnings, and socket timeouts for faster 
troubleshooting.

**Stupid FAST!**: Witten in C lh will instantly rip through your logs.

**

# Install.

  ```bash
  ./install.sh
  lh
  ```

   
  Depedicies
  ```bash
  json-c readline
  ```

