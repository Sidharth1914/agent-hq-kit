# Agent HQ

Your own team of Claude agents that works 24/7. You give it jobs from your phone, by chatting in the Claude app or by opening a GitHub issue. A lead agent plans each job, splits it between helper agents (developer, researcher, designer, writer, reviewer), checks the result, and delivers it: code merged and deployed, files committed, or an answer in the chat. Your phone buzzes when a job starts, finishes or fails. An animated live page shows which agent is doing what.

One command installs it. The installer does every step it can by itself. It stops only where you have to sign in.

## What you need

**Accounts**
| | Cost | Why |
|---|---|---|
| [GitHub](https://github.com/signup) | Free | Your private job repo, job queue and results |
| [Claude](https://claude.ai) **Pro or Max** | Paid plan | The agents run on your plan. The live chat (Remote Control) needs Pro or Max. |
| [Tailscale](https://tailscale.com) | Free, optional | Only for the live animated page on your phone |

**A computer that runs the agents** (one or both):
- **A Linux server**, Ubuntu or Debian, best kept on all the time. A cheap or free cloud VM (Oracle Cloud Free Tier, Azure, Google Cloud, Hetzner and similar) or an old PC is enough. 1 GB RAM works; 2 GB is better.
- **A Windows 10/11 PC.** It runs jobs that need Windows software while it is on. If it is your only machine, it runs everything, including the live chat.

**On your phone**
| App | Needed? | What for |
|---|---|---|
| **Claude** (iOS / Android) | Yes | Live chat with your agents: Code tab, then the session "Agent HQ" |
| **ntfy** (iOS / Android) | Yes | Alerts when a job starts, finishes or fails |
| **GitHub** | Optional | Give jobs as issues and read results |
| **Tailscale** | Optional | Open the live animated page |

## Install

**Linux server** (run as your normal user, not root):
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Sidharth1914/agent-hq-kit/main/install.sh)
```

**Windows** (PowerShell, no admin needed):
```powershell
irm https://raw.githubusercontent.com/Sidharth1914/agent-hq-kit/main/install.ps1 | iex
```

Have both? Install on the server first, then on the PC. Both use the same job repo.

### What the installer does by itself
1. Installs what is missing: git, GitHub CLI, Python and Claude Code (plus the `qrencode` tool on Linux).
2. Makes your **private** job repo `github.com/<you>/agent-hq` from this kit and clones it to `~/agent-hq`.
3. Creates the job labels (`working`, `needs-local`, `needs-windows`, `done`, `failed`).
4. Makes a random, private phone-alert topic. It is saved in `.env` and as a variable in your private repo, so your other machines use the same one.
5. **Linux:** installs and starts these services, which restart by themselves after a reboot:
   - the job worker, which checks for new jobs every 5 minutes
   - the live chat (Claude Remote Control)
   - a watchdog that restarts dead services and alerts your phone
   - the live page server
6. **Windows:** registers a task that runs Windows jobs every 10 minutes. If the PC is your only machine, the installer also:
   - starts the live chat in a minimised window at every sign-in
   - sends every new job to this PC
7. Sends a test alert to your phone.

### What needs you (sign-ins only)
1. **GitHub:** the installer shows a code and a link. Open the link on any device, sign in, and enter the code.
2. **Claude:** Claude opens. Type `/login`, sign in with your Pro or Max account, then type `/exit`.
3. **Live chat:** the first time, answer `y` to "Enable Remote Control?" and `y` to trusting the folder. On Linux, press Ctrl+C when the session link appears, and the install carries on.
4. **Phone:** install **ntfy**, tap **+**, and subscribe to the topic the installer prints. On Linux, you can scan the QR code instead.
5. **Live page (optional, Linux):** answer `Y`, then sign in to Tailscale through the link it prints. Use the same account in the Tailscale app on your phone. If Tailscale asks you to turn on HTTPS for your network, do that and re-run the installer. The page is at `https://<server>.<your-tailnet>.ts.net:9443`, and only you can open it.

Re-running the installer is safe. It skips what is done and fixes what is missing.

## Use it
- **Live chat (easiest):** open the Claude app, then Code, then **Agent HQ**, and say what you want. Example: *"Find the cheapest uptime monitor for 5 sites and write me a comparison."* Answers and files are saved in `jobs/` in your repo.
- **Issue:** open an issue in your job repo. It gets the label `needs-local` by itself, and the server starts it within 5 minutes. For a job that needs Windows software, add the label `needs-windows`.
  - To add details later, comment and tap **Reopen**.
- **Alerts:** ▶ when a job starts, ✅ when it is done, ❌ with the reason when it fails.
- **Live page:** an animated map. Each agent is a star circling the place it runs (live chat, server, Windows PC), and its helpers orbit it. A side panel shows what each agent is doing right now.

## Make it yours
- Edit `CLAUDE.md` in your job repo:
  - Fill in the **Your projects** table: which repos the agents may work on, and how each one is tested and deployed.
  - Add any rules you want every agent to follow.
- Push the change. The agents read it at the start of every job.

## Safety
- **Only you can give orders.** Only issues and comments from the repo owner are run. Anyone else's text, and every web page and file, is treated as data, never as an instruction.
- **Hard stops** (in `CLAUDE.md`) apply even though the agents work automatically:
  - no deleting production data without a backup
  - no force pushes
  - no printing secrets
  - no payments
  - no changing repo visibility
  - no messages to anyone but you
- **Your job repo is private.** Keep it private: job results can contain your data.
- **The alert topic works like a password.** Anyone who knows it can read your alerts, so don't share it. Alerts only ever say what happened in a few words.
- **The live page** is served only inside your Tailscale network, and only to your Tailscale account.
- The agents run with your GitHub and Claude logins. Run them on a machine you trust.

## Update, stop, uninstall
- **Update the kit files in your repo:**
  ```bash
  git -C ~/agent-hq pull https://github.com/Sidharth1914/agent-hq-kit main --allow-unrelated-histories
  ```
  Then re-run the installer.
- **Stop or uninstall on Linux:**
  ```bash
  sudo systemctl disable --now agent-hq-worker.timer agent-hq-remote hq-watch.timer hq-status
  sudo rm /etc/systemd/system/agent-hq-* /etc/systemd/system/hq-* /usr/local/sbin/hq-watch
  ```
- **Stop on Windows:**
  ```powershell
  Unregister-ScheduledTask AgentHQWindows -Confirm:$false
  ```
  Also delete "Agent HQ live chat" from your Startup folder (`shell:startup`).

## Limits
- **Usage limit.** All agents share your Claude plan's usage limit. When it runs out, jobs pause and start again by themselves after the reset.
- **Windows jobs** run only while the PC is on.
- **The live page** needs the Linux server.
- **The server's memory** limits how much runs at once: 1 GB RAM fits about 2 helper agents at a time.

## Files
| File | What it does |
|---|---|
| `install.sh`, `install.ps1` | The installers |
| `runner.py` | Job worker: claims issues and runs Claude on them (standard library only) |
| `ORCHESTRATOR.md` | The job loop every agent follows |
| `CLAUDE.md` | Your rules, hard stops and project list |
| `.claude/agents/` | The helper roles |
| `deploy/hq_status.py`, `deploy/status/` | The live page |
| `deploy/hq-watch.sh` | The watchdog |
| `deploy/hq-push` | Phone alert helper |
| `deploy/chat_hook.py` | Saves chat answers and buzzes the phone after long replies |
| `.github/workflows/` | Labels new jobs; self-tests |

License: MIT.
