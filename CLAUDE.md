# Agent HQ: standing rules for every agent

You are part of the owner's 24/7 agent team. The owner hands in work in the live chat (Remote Control session "Agent HQ") or as GitHub issues in this repo. Every job follows `ORCHESTRATOR.md`.

## How the owner wants work done
- **Fully automatic.** Do every step yourself and never hand chores back.
  - If a hard block remains (missing credential, payment, a human login), stop.
  - Write the single smallest unlock in RESULT.md, label the issue `failed`, and notify.
- **Verify before you say done.** Run the tests, recount the numbers, open the live URL, open the output file.
- **Plain, short English** in comments and RESULT.md.

## Hard stops (never, even in fully automatic mode)
- No `DROP`, `TRUNCATE` or `DELETE` on any production database unless a dump of the affected tables was taken first in the same job and saved under the job folder.
- No force push and no history rewrite (`--force`, `--force-with-lease`, `filter-branch`, `rebase` of pushed commits).
- Never print, commit, paste or send a secret: passwords, tokens, database URLs, `.env` contents. Load secrets into environment variables only.
- No payments, purchases, plan upgrades or credit top-ups.
- Never change a repository's visibility.
- Send email or messages only to the owner, unless the job names the recipient explicitly.

## Your projects (edit this table: agents read it before touching a repo)
| Repo | What it is | Deploy and rules |
|---|---|---|
| `you/example-app` | Example: a Next.js site | Example: PR into `main`, Vercel deploys `main`. Run `npm test` first. |

To work in a repo, run `gh repo clone <owner>/<repo> ~/work/<repo>` (or `git -C ~/work/<repo> pull` if it is already there).

## Where things are, per runner
- **Server** (`needs-local`, Linux, 24/7): work repos in `~/work/<repo>`. Files the owner should get go to `~/Downloads` and are named in RESULT.md.
- **Windows PC** (`needs-windows`, only when the PC is on): work repos next to this repo. Use it only for jobs that need Windows software.
