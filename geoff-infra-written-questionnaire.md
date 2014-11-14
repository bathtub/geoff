# GitHub Infrastructure Engineer Questionnaire

> Thanks again for applying to the Infrastructure Engineer job at GitHub! The purpose of this gist is to get a better sense of your technical skills and overall communication style. Take as much time as you need to answer these questions.

My pleasure, and, you're welcome! :octocat:

## Section 1

> Engineers at GitHub communicate primarily in written form, via GitHub Issues and Pull Requests. We expect our engineers to communicate clearly and effectively; they should be able to concisely express both their ideas as well as complex technological concepts.

> Please answer the following questions in as much detail as you feel comfortable with. The questions are purposefully open-ended, and we hope you take the opportunity to show us your familiarity with various technologies, tools, and techniques. Limit each answer to half a page if possible; walls of text are not required, and you'll have a chance to discuss your answers in further detail during a phone interview if we move forward in the process. Finally, feel free to use google, man pages and other resources if you'd like.

### Q1

> A service daemon in production has stopped responding to network requests. You receive an alert about the health of the service, and log in to the affected node to troubleshoot. How would you gather more information about the process and what it is doing? What are common reasons a process might appear to be locked up, and how would you rule out each possibility?

### A1: 

> A service daemon in production has stopped responding to network requests. You receive an alert about the health of the service, and log in to the affected node to troubleshoot.

Ok, back up for a second. If this on a server **in production**, first lets:

  - Verify that the service _continues_ to be unresponsive, in case this was perhaps just momentary high traffic volume or a latency issue.

  - Check to make sure other services/nodes are not also affected, indicating a larger network issue (including potentially an attack), hardware/hypervisor fault, etc.

  - If it is indeed a single unresponsive process, hopefully this is a service that one can shift to another node via load balancer, or spin up another instance in the interim. That is, try to get things back up and running before proceeding with the autopsy.

Moving on:

> How would you gather more information about the process and what it is doing? What are common reasons a process might appear to be locked up, and how would you rule out each possibility?

Lets start by making sure it's still doing *something*.

```bash
ps -ecjvx | grep foobard
```

If the process doesn't even show up, lets try to find why the process died, and/or isn't being respawned:

```bash
grep -r foobard /var/log | grep SIG # Did it signal?
grep -r foobard /var/log # Or use `ack` or `ag`.
```

Grepping through the logs should be one of the first things done in any case.

If the process is still running, check the output of `ps` for bad state ([TUZ], etc.), and/or abnormally high CPU or memory usage perhaps using `top` to watch fluctuations, and check to see if there's anything unusual afoot with the services' open `fd`s/sockets:

```bash
lsof -c foobard
```

If we're still hunting for an answer at this point, try `netstat`, `iostat`, `vmstat`, `iptables`, and friends. Use one or more of `[dlps]` `trace`, etc. Sample the process.

If I had to peg the most "common" causes for a daemon to lock up, I'd probably say memory (leaks, oversubscription). But its best not to speculate.

### Q2

> A user on an ubuntu machine runs `curl http://github.com`. Describe the lifecycle of the curl process and explain what happens in the kernel, over the network, and on github.com's servers before the command completes.

### A2: 

Well, possibly something like `curl: command not found` is printed to standard error, nothing happens in kernel, over the network, or elsewhere. (A minimal Ubuntu netinstall doesn't ship with `curl`.)

But, if I'm not being a smart-ass:

1. The shell `execve()`s the curl binary with arguments and environment.

2. The binary is read and the kernel `dlopen()`s and `mmaps()`s ~40 shared libraries into memory.

3. The curl global initializer function is called, reading relevant locale settings and environmental variables, and attempts to read a `~/.curlrc` file, if present. The URI is canonicalized, in this case, adding a trailing slash.

4. A system call (probably `getaddrinfo()`, as I don't believe Ubuntu's `curl` uses `c-ares`) is made to resolve the `github.com` domain name. It first tries to resolve an IPv6 address, but as there are no AAAA records for `github.com`, this fails.

   Honestly, I have no idea how glibc and the linux kernel really handles a DNS request, but its probably safe to assume this translates to the kernel copying the URI into kernel space, checking `/etc/hosts` and the various config files that specify the DNS server to use (not necessarily in `/etc/resolv.conf` these days, I don't think). At link layer, the kernel tells the NIC's device driver to send a request to the specified DNS server (UDP on port 53).

   In theory, this server would in turn query the `.com` TLD nameserver for the `github.com` nameserver, then query one of the authoritative servers for the corresponding IP address. In practice, this typically would be retrieved from a caching DNS server and have a relatively stable address.
   But as `github.com`'s nameservers are fancy high-availably load-balanced magical DynDNS servers, the A records have a TTL of mere seconds, and the IP address is constantly rotated to return any one of the addresses in the `192.30.252.128/30` block (with the rest of the `/27` block acting similarly, but for various subdomains.)

5. The kernel returns one (or possibly more than one) of these four IP addresses. `curl` calls `socket()` specifying TCP, then `connect()`, specifying port 80. If the `connect()` is successful, it calls `getpeername()` and `getsockname()` to verify the connection.

6. Over this socket, curl `send()`s an HTTP GET request for URI `/`, host `github.com`.

7. The answering http server responds with a status code `301 Moved Permanently` redirect to `https://github.com/`, and instructs to close the connection.

8. Because `curl` has not been invoked with a flag to follow redirects (and because the response `recv()`d had 0 content length), nothing is printed to `stdout`, the socket is closed, and curl returns 0.

Interestingly, because GitHub redirects **all** http traffic over https and uses your use of two different certificates for the root domain and subdomains, this has some interesting side effects. As in **CODENAME STEALTH OPOSSUM** (ask your security team). Which, while admittedly minor, continues to affect newer versions of Mac OS X.

### Q3

> Explain in detail each line of the following shell script. What is the purpose of this script? How would you improve it?

```
#!/bin/bash
set -e
set -o pipefail
exec sudo ngrep -P ' ' -l -W single -d bond0 -q 'SELECT' 'tcp and dst port 3306' |
  egrep "\[AP\] .\s*SELECT " |
  sed -e 's/^T .*\[AP\?\] .\s*SELECT/SELECT/' -e 's/$/;/' |
  ssh $1 -- 'sudo parallel --recend "\n" -j16 --spreadstdin mysql github_production -f -ss'
```

### A3: 

> Explain in detail each line of the following shell script.

```bash
#!/bin/bash
#--> Our interpreter is the GNU Bourne-Again Shell.
#--> Interestingly, the behavior of a shebang is not defined in POSIX.
#--> In an interactive shell, a shell script without one will execute in the
#--> current environment, and one may also use a `:` to specify the default
#--> shell in lieu of a shebang. However, since we're using some `bash`
#--> specific features, `#!/bin/bash` is what we want.

set -e
#--> Script breaks and exits non-zero, if any command exits non-zero.

set -o pipefail
#--> Exit non-zero if any command in pipeline exists non-zero (POSIX
#--> specifies a pipeline exits with the exit status of last command.)

exec sudo ngrep -P ' ' -l -W single -d bond0 -q 'SELECT' 'tcp and dst port 3306' |
#--> Replace current process with pipeline beginning with `ngrep`, which quietly
#--> greps through any TCP activity to port 3306 on interface bond0 for the
#--> word 'SELECT', replacing non-printable characters with a single space,
#--> then piping matching packets out on a single buffered line...

 egrep "\[AP\] .\s*SELECT " |
#--> ...to egrep, which selects lines matching '[AP]' followed by a space,
#--> any character, any amount of whitespace, 'SELECT', and a trailing space.

 sed -e 's/^T .*\[AP\?\] .\s*SELECT/SELECT/' -e 's/$/;/' |
#--> The lines are piped to the stream editor, which is meant to trim the
#--> beginning of any line beginning with 'T', a space, an unlimited sequence
#--> of characters followed by the a literal string [AP?] (seems like a typo)
#--> a space, any one character, and any amount of whitespace up to an
#--> occurrence 'SELECT', appending the line with a semicolon.
 
 ssh $1 -- 'sudo parallel --recend "\n" -j16 --spreadstdin mysql github_production -f -ss'
#--> These lines are then piped to ssh (with the address specified as the
#--> first parameter of the script), which passes the piped data over the
#--> ssh connection. On the remote server, the data is piped to GNU parallel,
#--> which splits the input line-by-line, passing one at a time to 16
#--> simultaneous invocations of the `mysql` client command, specifying
#--> the `github_production` database, ignoring SQL errors, squelching
#--> output with two `-s` flags.
```

> How would you improve it?

 As to improvements (without changing its present functionality too much):

   - We can put the `set` flags in the shebang. Might as well.

   - The script effectively executes the same regex three times, which is computationally expensive and redundant. The `egrep` (which is now deprecated for `grep -E`) part can be eliminated entirely.

   - The script will prompt for a login and password for `ssh`, and for a password again to `sudo` on the remote server. Its also bad form (IMHO) to change user within a script — that is, `sudo exec` — particularly since this script will be prompting for a password several times, and it may be unclear as to which password (the host or the remote server) it wants. Instead, the script itself should be executed with `sudo`.

   - I'd probably prefer to use a series of individual commands which redirect to and from `fd`s, so that the script will exit if any individual command fails, as `set -o pipefail` does not mean the script will break when a command in the pipeline fails, it simply changes the exit status of the pipeline, but it won't stop further execution of commands in the pipeline. But we'll leave that for now.

   - Lets `set -x` as well, so we can see whats going on in here.


 So maybe:
 
 ```bash
 #!/bin/bash -exo pipefail
 exec ngrep -lqP ' ' -W single -d bond0 'T.*\[.*\]\s*SELECT' 'dst port 3306' |
   sed 's|.*\(SELECT.*\)|\1;|' | ssh "root@$1" -- \
  "parallel --recend '\n' -j16 --spreadstdin -- mysql github_production -fss"
 ```

> What is the purpose of this script?


As to what it **does**:

It seems as though the idea here is to replicate incoming MySQL commands sent to the host (where the script is run) on the remote server. But it seems like a bizarre way to do this... Why only `SELECT` commands? What happens if there are nested commands (since newlines in requests are being stripped)? What if the `SELECT` commands are `SELECT INTO`s? Why is this being piped over SSH (as opposed to `netcat`, or mounting the remote server as an NFS share, which would be much more efficient)? Why are SQL errors being ignored, and output being squelched? Why are we using this ngrep tool, as opposed to `tcpdump`?

There are more effective ways to replicate, slave, or hotcopy a database. Reproducing SQL commands could be done by having mysqld output a more verbose log, and one could avoid grepping through the raw interface. And why the 16 parallel jobs, each executing only one command? I'm unconvinced that the overhead of `parallel`s `--spreadstdin` and job control, with multiple jobs being executed one command at a time, would be any faster than simply piping all the commands to a single instance of `mysql`.

~~And what about the `'\[AP\?\] .\s*'` business? It seems it would not match what is intended, making _all_ the the SQL gibberish.~~ _I see now that this works, but only in **GNU** sed. Which is not great for portability, but OK._


So to take a stab at its **purpose**:

I think might be meant to be a quick and dirty way to burn-in a new database server. After replicating the configuration and database on the remote server, the commands are being grepped this way from a server in production where you can't take down `mysqld` to change logging parameters. The parallel jobs are used to _intentionally_ put more load on the server, and exercise the CPU to capacity on all cores. SQL errors are ignored because they don't matter much, and neither does the output.

If this **is** what its for, I still think there might be better ways to do this (i.e., better excerise the NIC with multiple connections calling these commands remotely), but perhaps its good enough as it is for your purposes? Am I close?

## Section 2

> The following areas map to technologies we use on a regular basis at GitHub. Experience in all of these areas is not a prerequisite for working here. We'd like to know how many of these overlap with your skill set so that we can tailor our interview questions if we move forward in the process.

> Please assess your experience in the following areas on a 1-5 scale, where (1) is "no knowledge or experience" and (5) is "extensive professional experience". If you're not sure, feel free to leave it blank. Just place the number next to the corresponding areas listed here:

``````````````````````````````````````````````````````````````````````````````
 - system administration                                     5
   - puppet                                                  2 
   - ubuntu                                                  4
   - debian packages                                         4
   - raid                                                    5 # ha!
   - new hardware burn-in testing                            4
 - virtualization                                            5 # There's more
   - lxc                                                     2 # to it than
   - xen/kvm                                                 3 # these!
   - esx                                                     5
   - aws                                                     5
 - troubleshooting                                           5
   - debuggers (~~gdb~~, lldb)                               2
   - profilers (perf, oprofile, perftools, strace)           3 # dtrace?
   - network flow (tcpdump, pcap)                            3
 - large system design                                       4
   - unix processes and threads                              4
   - sockets                                                 4
   - signals                                                 4
   - mysql                                                   3
   - redis                                                   2 # but learning!
   - elasticsearch                                           1
 - coding                                                    4
   - comp-sci fundamentals (data structures, big-O notation) 4
   - git usage                                               4
   - git internals                                           4
   - c programming                                           3
   - shell scripting                                         5
   - ruby programming                                        4 # In light of:
   - rails                                                   1
   - javascript                                              2
   - coffeescript                                            2
 - networking                                                4
   - TCP/UDP                                                 4 
   - bgp                                                     2
   - juniper                                                 2
   - arista                                                  1
   - DDoS mitigation strategies and tools                    2
   - transit setup and troubleshooting                       3 # no peering!?
 - operational experience                                    4
   - reading and debugging code you’ve never seen before     5
   - handling urgent incidents when on-call                  5
   - helping other engineers understand and navigate systems 5
   - handling large scale production incidents /coordination 4
``````````````````````````````````````````````````````````````````````````````