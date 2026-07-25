# Remote lab: self-hosted diagnostics on the domain test machine

The DC-warm/resolve regression only reproduces on domain-joined Windows
machines. This page sets up a GitHub Actions self-hosted runner on the test
machine so diagnostic runs (`.github/workflows/diagnostics.yml`) can be
triggered remotely and their evidence bundles downloaded — no hands on the box
per iteration.

## Security model (read first)

The main repo is **public**, and GitHub's guidance is to never attach
self-hosted runners to public repositories. So the runner lives on a **private
mirror** (`donut-lab`) instead:

- The runner is registered ONLY on `Danial-Changez/donut-lab` (private).
- The public repo's copy of `diagnostics.yml` is inert — no runner there
  carries its labels.
- Never add `pull_request` / `pull_request_target` triggers to
  `diagnostics.yml`. `push` and `workflow_dispatch` can only be fired by users
  with write access to the mirror.
- Scope the runner to the one repository; don't reuse it elsewhere.

## One-time setup

### 1. The private mirror (already scripted)

```powershell
gh repo create Danial-Changez/donut-lab --private
git remote add lab https://github.com/Danial-Changez/donut-lab.git
git push lab <branch>          # push each branch you want the lab to run
```

### 2. Register the runner on the test machine

On the test machine (as the domain account DONUT normally runs under):
GitHub → `donut-lab` → Settings → Actions → Runners → *New self-hosted runner*
(Windows x64), then:

```powershell
mkdir C:\actions-runner; cd C:\actions-runner
# download + extract per the GitHub page, then:
./config.cmd --url https://github.com/Danial-Changez/donut-lab `
    --token <registration token> --labels donut-lab --unattended
./run.cmd
```

**Run it interactively (`run.cmd`) in the logged-in domain session, not as a
service.** The behaviors under test — Kerberos to the DCs, loopback DCOM/CIM,
Defender/AMSI in the user context, the user profile — live in the interactive
logon type; a Session-0 service is a different experiment. A locked screen is
fine. To survive reboots, register a logon-triggered Scheduled Task:

```powershell
Register-ScheduledTask -TaskName 'donut-lab-runner' `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME") `
    -Action (New-ScheduledTaskAction -Execute 'C:\actions-runner\run.cmd' `
        -WorkingDirectory 'C:\actions-runner')
```

(The service alternative — `./config.cmd ... --runasservice` under the domain
account — works for the test suite but runs in Session 0 with a different
Defender/logon context; use it only knowing that caveat.)

### 3. Machine prerequisites

- Windows 10/11, domain-joined, line of sight to the DCs
- PowerShell 7+ (`pwsh`), git, Pester 5.5+
  (`Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force`)
- A designated **target host** for the resolve/disk phases

## Driving it (what Claude runs from the dev box)

```bash
# keep the mirror current, then trigger
git push lab fix/dc-warm-regression
gh workflow run diagnostics.yml -R Danial-Changez/donut-lab \
    --ref fix/dc-warm-regression -f target-host=<HOST> -f include-disk-scan=true

# watch and collect
gh run list  -R Danial-Changez/donut-lab --workflow=diagnostics.yml -L 5
gh run watch -R Danial-Changez/donut-lab <run-id> --exit-status
gh run download -R Danial-Changez/donut-lab <run-id> -n donut-diagnostics -D ./artifacts
```

Every push to a `fix/**` branch on the mirror also runs the suite plus a
warm+DC-only diagnostic automatically (no target host).

## What a run produces

One `DonutDiag-<machine>-<sha>-<timestamp>.zip` artifact — verdict JSON,
harness `Donut.log`, provenance (commit, pwsh, Defender signature age),
PowerShell/Defender event CSVs, and live runspace stacks if the warm barrier
lapsed. The harness forces its workers' `[DEBUG]` on; but when reproducing in
the **real app**, launch it with `Start-Donut -DebugLog` (or the Settings →
Diagnostics toggle) first — `debugLogging` defaults off, and the tailed app log
is breadcrumb-free without it. Interpreting it and the bisect workflow it feeds:
[testing.md](./testing.md), "Headless diagnostic runs and the empirical bisect
protocol". The wedge probe on its own: `tools/Get-DonutRunspaceStacks.ps1`.
