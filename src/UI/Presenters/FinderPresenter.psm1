using namespace System.Windows.Controls
using namespace System.Windows.Threading
using namespace System.Collections.Generic
using namespace Donut.Mvvm
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Core\RunspaceManager.psm1"
using module "..\..\Services\ActiveDirectoryService.psm1"
using module "..\..\Models\PersonLens.psm1"
using module ".\DialogPresenter.psm1"
using module ".\ToastService.psm1"
using module "..\ViewModels\HomeViewModel.psm1"
using module "..\ViewModels\SearchRowViewModel.psm1"
using module "..\ViewModels\PersonLensViewModel.psm1"

<#
.SYNOPSIS
    Presenter for the search-bar finder: live multi-forest AD dropdown, inline
    account unlock, and the user Lens (person -> devices).

.DESCRIPTION
    Owns everything behind the Home search bar's dropdown: the debounced per-forest
    AD fan-out (AdSearchWorker on the runspace pool, results streamed per forest),
    inline unlock of locked-out accounts, and the user Lens - picking a user runs a
    lookup over the persistent de-elevated agent (LensLookupWorker on the pool) and
    shows the result in the detail pane via HomeVm.SetPerson. All pool jobs are raw
    PowerShell shells polled on DispatcherTimers (never the AsyncJobPresenter pump).

.NOTES
    Extracted from HomePresenter; the two presenters share the HomeViewModel (which
    enforces machine/Lens detail-pane exclusivity) and the dual-use search TextBox
    (the finder wires TextChanged/Escape; HomePresenter's Add flow reads/clears it).
    $Home is a DUCK-TYPED back-reference to HomePresenter (a typed import would be a
    using-module cycle); the complete machine-side seam is: PrefetchIp, EnsureRow,
    StartInventory, MoveRowToTop, UpdateEmptyHint. Event-handler scriptblocks capture
    $presenter, since in a WPF handler $this rebinds to the sender.
#>
class FinderPresenter {
    [AppConfig] $Config
    [System.Windows.FrameworkElement] $ViewContent
    [HomeViewModel] $HomeVm            # shared with HomePresenter (SearchResults + SetPerson)
    [LogService] $Logger
    [ToastService] $Toasts
    [DialogPresenter] $DialogPresenter
    [object] $Home                     # duck-typed HomePresenter back-ref (see .NOTES)
    [TextBox] $SearchBar               # the dual-use GoogleSearchBar (finder wiring only)

    # AD live-search (search-bar dropdown: computers + locked-out users)
    [ActiveDirectoryService] $AdService
    # System.Windows.Controls.Primitives.Popup; its rows render via binding.
    [object]          $SearchPopup
    [DispatcherTimer] $SearchDebounce
    [DispatcherTimer] $SearchPollTimer
    [int]             $SearchToken = 0
    [List[hashtable]] $SearchJobs          # in-flight @{ Ps; Handle; Token }
    [List[hashtable]] $AdWarmJobs          # one-shot startup AD warm jobs (results discarded)
    # Accumulated rows for the current token (forests stream in).
    [List[object]]    $SearchResults
    [HashSet[string]] $SearchSeen          # dedupe keys (Kind|Domain|Sam) for the current token
    [bool]            $SuppressSearch = $false
    [List[hashtable]] $UnlockJobs          # in-flight @{ Ps; Handle; Upn }
    [DispatcherTimer] $UnlockPollTimer

    # User Lens: a pick runs LensLookupWorker over the persistent de-elevated agent;
    # mirrors the search/unlock poll pattern.
    [PersonLensViewModel] $LensVm          # bound to the detail pane in Person mode
    [List[hashtable]]     $LensJobs         # in-flight @{ Ps; Handle; Token }
    [DispatcherTimer]     $LensPollTimer
    [int]                 $LensToken = 0    # newest pick wins; stale results are discarded
    # Startup agent warm-up @{ Ps; Handle }, reaped on the first pick.
    [object]              $LensWarmJob
    # Per-person result cache: identity -> @{ At; Json }. Memory only - it holds
    # BitLocker keys, so it must never be written to disk.
    hidden [hashtable] $LensCache = @{}
    [timespan] $LensCacheTtl = [timespan]::FromMinutes(15)

    FinderPresenter(
        [AppConfig]$config,
        [System.Windows.FrameworkElement]$view,
        [HomeViewModel]$homeVm,
        [LogService]$logger,
        [ToastService]$toasts,
        [DialogPresenter]$dialogs,
        [object]$homePresenter
    ) {
        $this.Config = $config
        $this.ViewContent = $view
        $this.HomeVm = $homeVm
        $this.Logger = $logger
        $this.Toasts = $toasts
        $this.DialogPresenter = $dialogs
        $this.Home = $homePresenter

        $presenter = $this

        # AD live-finder: debounce typing, search on the pool, poll for completion.
        $this.AdService = [ActiveDirectoryService]::new($this.Config.GetDomains(), $this.Logger)
        $this.SearchJobs = [List[hashtable]]::new()
        $this.AdWarmJobs = [List[hashtable]]::new()
        $this.SearchResults = [List[object]]::new()
        $this.SearchSeen = [HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.SearchDebounce = [DispatcherTimer]::new()
        $this.SearchDebounce.Interval = [TimeSpan]::FromMilliseconds(250)
        $this.SearchDebounce.Add_Tick({ $presenter.RunAdSearch() }.GetNewClosure())
        $this.SearchPollTimer = [DispatcherTimer]::new()
        $this.SearchPollTimer.Interval = [TimeSpan]::FromMilliseconds(120)
        $this.SearchPollTimer.Add_Tick({ $presenter.PollSearch() }.GetNewClosure())
        $this.UnlockJobs = [List[hashtable]]::new()
        $this.UnlockPollTimer = [DispatcherTimer]::new()
        $this.UnlockPollTimer.Interval = [TimeSpan]::FromMilliseconds(150)
        $this.UnlockPollTimer.Add_Tick({ $presenter.PollUnlock() }.GetNewClosure())

        # User Lens: one shared VM (reused per pick) + a poll timer for the lookups.
        $this.LensVm = [PersonLensViewModel]::new()
        $this.LensJobs = [List[hashtable]]::new()
        $this.LensPollTimer = [DispatcherTimer]::new()
        $this.LensPollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $this.LensPollTimer.Add_Tick({ $presenter.PollLens() }.GetNewClosure())
    }

    # Finds the finder's two imperative controls and wires the search-bar events.
    # Called by HomePresenter.Initialize (which owns overall startup ordering).
    [void] Initialize() {
        $this.SearchBar = $this.ViewContent.FindName('GoogleSearchBar')
        $this.SearchPopup = $this.ViewContent.FindName('SearchResultsPopup')

        $presenter = $this
        if ($this.SearchBar) {
            $this.SearchBar.Add_TextChanged({ $presenter.OnSearchTextChanged() }.GetNewClosure())
            $this.SearchBar.Add_PreviewKeyDown({
                    param($s, $e)
                    if ($e.Key -eq 'Escape') { $presenter.CloseSearchPopup() }
                }.GetNewClosure())
        }
    }

    # Tears down the Lens agent via the pool worker so the UI never parse-loads
    # PersonLensService; stashed in $global:LensTeardownJob for the Closed handler to await.
    [void] OnAppClosing() {
        try {
            $worker = Join-Path $this.Config.SourceRoot 'Scripts\LensLookupWorker.ps1'
            $global:LensTeardownJob = $this.StartPoolScript($worker, @{
                    SiteServer = $this.Config.GetAdminServiceHost()
                    SourceRoot = $this.Config.SourceRoot
                    StopAgent  = $true
                })
        }
        catch {
            $this.Logger.LogException("Lens agent teardown could not start", $_)
        }
    }

    # Returns the job envelope the poll loops expect (@{ Ps; Handle }); throws on failure
    # so each call site keeps its own catch/log/toast behavior.
    hidden [hashtable] StartPoolScript([string]$scriptPath, [hashtable]$parameters) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = [RunspaceManager]::GetPool()
        $ps.AddCommand($scriptPath) | Out-Null
        foreach ($k in $parameters.Keys) { $ps.AddParameter($k, $parameters[$k]) | Out-Null }
        return @{ Ps = $ps; Handle = $ps.BeginInvoke() }
    }

    # Best-effort dispose of a pool job's PowerShell handle (logs at debug, never throws).
    hidden [void] DisposeJob([object]$ps) {
        if ($null -eq $ps) { return }
        try { $ps.Dispose() }
        catch { $this.Logger.LogDebug("Job dispose failed: $($_.Exception.Message)") }
    }

    # Fire-and-forget warm: one throwaway search per forest primes the worker graph
    # + each forest's LDAP bind. Never blocks; reaped by the first real search.
    [void] WarmAdSearch() {
        $worker = Join-Path $this.Config.SourceRoot 'Scripts\AdSearchWorker.ps1'
        foreach ($domain in $this.AdService.Domains) {
            try {
                # 'zzz' is a throwaway prefix: it warms the bind, results are discarded.
                $this.AdWarmJobs.Add(
                    $this.StartPoolScript($worker, @{ Domains = @($domain); Prefix = 'zzz' }))
            }
            catch {
                $this.Logger.LogException("AD search warm-up could not start for '$domain'", $_)
            }
        }
    }

    # Disposes the startup AD warm jobs; their results are never read.
    hidden [void] ReapAdWarm() {
        if ($null -eq $this.AdWarmJobs -or $this.AdWarmJobs.Count -eq 0) { return }
        foreach ($j in @($this.AdWarmJobs)) { $this.DisposeJob($j.Ps) }
        $this.AdWarmJobs.Clear()
    }

    # Fire-and-forget: start the persistent de-elevated Lens agent on the pool. Never
    # blocks; the handle is reaped on the first pick, and failures are logged then.
    [void] WarmLens() {
        try {
            $worker = Join-Path $this.Config.SourceRoot 'Scripts\LensLookupWorker.ps1'
            $this.LensWarmJob = $this.StartPoolScript($worker, @{
                    SiteServer = $this.Config.GetAdminServiceHost()
                    SourceRoot = $this.Config.SourceRoot
                    WarmOnly   = $true
                })
        }
        catch {
            $this.Logger.LogException("Lens agent warm-up could not start", $_)
        }
    }

    # Reap the startup agent warm job (logs its result: '' = started, else the reason).
    hidden [void] ReapLensWarm() {
        if ($null -eq $this.LensWarmJob) { return }
        $job = $this.LensWarmJob
        $this.LensWarmJob = $null
        try {
            if ($job.Handle.IsCompleted) {
                $reason = (@($job.Ps.EndInvoke($job.Handle)) -join '')
                if ($reason) { $this.Logger.LogWarning("Lens agent warm-up: $reason") }
                else { $this.Logger.LogInfo("Lens agent warmed and ready.") }
            }
            $job.Ps.Dispose()
        }
        catch { $this.DisposeJob($job.Ps) }
    }

    # --- AD live search (search-bar dropdown) ---

    # Restart the debounce window on each keystroke; close the dropdown when the
    # prefix is too short to search.
    [void] OnSearchTextChanged() {
        if ($this.SuppressSearch) { return }
        $text = if ($this.SearchBar) { $this.SearchBar.Text } else { '' }
        if ([string]::IsNullOrWhiteSpace($text) -or
            $text.Trim().Length -lt $this.AdService.MinPrefix) {
            $this.SearchDebounce.Stop()
            $this.AbortSearch()
            $this.CloseSearchPopup()
            return
        }
        $this.SearchDebounce.Stop()
        $this.SearchDebounce.Start()
    }

    # Cancels the in-flight fan-out: stales the token so a late forest result can't
    # re-open the dropdown, disposes the jobs, stops polling.
    [void] AbortSearch() {
        $this.SearchToken++
        foreach ($job in @($this.SearchJobs)) { $this.DisposeJob($job.Ps) }
        $this.SearchJobs.Clear()
        $this.SearchResults.Clear()
        $this.SearchSeen.Clear()
        $this.SearchPollTimer.Stop()
    }

    # Debounce elapsed: kick a background search on the runspace pool.
    [void] RunAdSearch() {
        $this.SearchDebounce.Stop()
        $this.ReapAdWarm()   # startup warm has served its purpose once a real search runs
        $prefix = if ($this.SearchBar) { $this.SearchBar.Text.Trim() } else { '' }
        if ($prefix.Length -lt $this.AdService.MinPrefix) { $this.CloseSearchPopup(); return }

        # Drop in-flight jobs from the previous keystroke so a new search doesn't
        # stack behind stale ones.
        $this.AbortSearch()

        $this.SearchToken++
        $token = $this.SearchToken

        # Fan out one job per forest and render hits as each lands, instead of
        # waiting on the sum of all forests' LDAP round-trips.
        $worker = Join-Path $this.Config.SourceRoot 'Scripts\AdSearchWorker.ps1'
        foreach ($domain in $this.AdService.Domains) {
            try {
                $job = $this.StartPoolScript($worker, @{ Domains = @($domain); Prefix = $prefix })
                $job.Token = $token
                $this.SearchJobs.Add($job)
            }
            catch {
                $this.Logger.LogException("AD search could not start for '$domain'", $_)
            }
        }
        if ($this.SearchJobs.Count -gt 0) { $this.SearchPollTimer.Start() }
        else { $this.CloseSearchPopup() }
    }

    # Poll the per-forest searches; as each lands, fold its hits into the current token's
    # accumulator and re-render the growing union. Stale-token jobs are discarded.
    [void] PollSearch() {
        foreach ($job in @($this.SearchJobs)) {
            if (-not $job.Handle.IsCompleted) { continue }
            $results = @()
            try { $results = @($job.Ps.EndInvoke($job.Handle)) }
            catch { $this.Logger.LogException("AD search failed", $_) }
            $this.DisposeJob($job.Ps)
            [void]$this.SearchJobs.Remove($job)
            if ($job.Token -ne $this.SearchToken) { continue }
            foreach ($row in $results) {
                $key = "$($row.Kind)|$($row.Domain)|$($row.SamAccountName)"
                if ($this.SearchSeen.Add($key)) { $this.SearchResults.Add($row) }
            }
            $this.RenderAdResults($this.SearchResults.ToArray())
        }
        if ($this.SearchJobs.Count -eq 0) { $this.SearchPollTimer.Stop() }
    }

    # Maps the accumulated hits to display rows (headers + results, one flat list) and
    # swaps them into the bound collection; commands close over the presenter's handlers.
    [void] RenderAdResults([object[]]$results) {
        if ($null -eq $results -or $results.Count -eq 0) { $this.CloseSearchPopup(); return }

        $computers = @($results | Where-Object { $_.Kind -eq 'Computer' })
        $users = @($results | Where-Object { $_.Kind -eq 'User' })

        $presenter = $this
        # $items, not $rows/$searchResults: a local colliding case-insensitively with
        # a property breaks assignment inside PS class methods.
        $items = [System.Collections.Generic.List[object]]::new()
        if ($computers.Count -gt 0) {
            $items.Add([SearchRowViewModel]::Header('COMPUTERS'))
            foreach ($c in $computers) {
                $vm = [SearchRowViewModel]::FromResult($c)
                $cap = [string]$c.Name
                $pick = { param($p) $presenter.OnPickComputer($cap) }.GetNewClosure()
                $vm.PickCommand = [RelayCommand]::new([System.Action[object]]$pick)
                $items.Add($vm)
            }
        }
        if ($users.Count -gt 0) {
            $items.Add([SearchRowViewModel]::Header('USERS'))
            foreach ($u in $users) {
                $vm = [SearchRowViewModel]::FromResult($u)
                # Clicking a user row opens the Lens (its directory + SCCM devices).
                $capU = $u
                $pickU = { param($p) $presenter.OnPickUser($capU) }.GetNewClosure()
                $vm.PickCommand = [RelayCommand]::new([System.Action[object]]$pickU)
                if ($vm.CanUnlock) {
                    $unlock = { param($p) $presenter.OnUnlockUser($u) }.GetNewClosure()
                    $vm.UnlockCommand = [RelayCommand]::new([System.Action[object]]$unlock)
                }
                $items.Add($vm)
            }
        }

        $this.HomeVm.SearchResults.Clear()
        foreach ($item in $items) { $this.HomeVm.SearchResults.Add($item) }
        if ($this.SearchPopup) { $this.SearchPopup.IsOpen = $true }
    }

    # Computer chosen: drop it into the bar so the operator can run the active
    # command (suppressing the re-search the programmatic edit would trigger).
    [void] OnPickComputer([string]$name) {
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $this.CloseSearchPopup()
        $this.SuppressSearch = $true
        if ($this.SearchBar) {
            $this.SearchBar.Text = $name
            $this.SearchBar.CaretIndex = $name.Length
        }
        $this.SuppressSearch = $false
        # Start-early: a picked computer is about to be run - warm its IP now.
        $this.Home.PrefetchIp($name)
    }

    # Locked user chosen: confirm, unlock against its home domain, toast the result.
    [void] OnUnlockUser([object]$r) {
        $this.CloseSearchPopup()
        if ($null -eq $r) { return }
        $upn = if ([string]::IsNullOrWhiteSpace($r.UserPrincipalName)) { [string]$r.SamAccountName }
        else { [string]$r.UserPrincipalName }

        $confirmed = $this.DialogPresenter.ShowConfirmation(
            "Unlock account",
            "Unlock the locked-out account '$upn'?",
            @("$([string]$r.SamAccountName)  @  $([string]$r.Domain)")
        )
        if (-not $confirmed) { return }

        # Run the unlock OFF the UI thread (Unlock-ADAccount can take a moment);
        # toast the result when the pool job completes.
        try {
            $worker = Join-Path $this.Config.SourceRoot 'Scripts\AdUnlockWorker.ps1'
            $job = $this.StartPoolScript($worker,
                @{ Sam = [string]$r.SamAccountName; Domain = [string]$r.Domain })
            $job.Upn = $upn
            $this.UnlockJobs.Add($job)
            $this.UnlockPollTimer.Start()
            if ($this.Toasts) { $this.Toasts.ShowInfo("Unlocking...", $upn) }
        }
        catch {
            $this.Logger.LogException("Unlock could not start for $upn", $_)
            if ($this.Toasts) { $this.Toasts.ShowError("Unlock failed", "Could not start unlock for $upn.") }
        }
    }

    # Poll in-flight unlocks; toast success/failure on completion.
    [void] PollUnlock() {
        foreach ($job in @($this.UnlockJobs)) {
            if (-not $job.Handle.IsCompleted) { continue }
            $ok = $false
            try {
                $res = @($job.Ps.EndInvoke($job.Handle))
                $ok = [bool]($res | Select-Object -Last 1)
            }
            catch { $this.Logger.LogException("Unlock failed for $($job.Upn)", $_) }
            $this.DisposeJob($job.Ps)
            [void]$this.UnlockJobs.Remove($job)
            if ($this.Toasts) {
                if ($ok) { $this.Toasts.ShowSuccess("Account unlocked", $job.Upn) }
                else { $this.Toasts.ShowError("Unlock failed", "Could not unlock $($job.Upn) (check rights / connectivity).") }
            }
        }
        if ($this.UnlockJobs.Count -eq 0) { $this.UnlockPollTimer.Stop() }
    }

    # --- User Lens (person -> devices) ---

    # A user was picked: show the Lens loading in the detail pane, then run the de-elevated
    # lookup on the pool. UPN is the best identity; falls back to DOMAIN\SAM or SAM.
    [void] OnPickUser([object]$r) {
        if ($null -eq $r) { return }
        $identity =
        if (-not [string]::IsNullOrWhiteSpace($r.UserPrincipalName)) { [string]$r.UserPrincipalName }
        elseif (-not [string]::IsNullOrWhiteSpace($r.Domain) -and
            -not [string]::IsNullOrWhiteSpace($r.SamAccountName)) {
            "$($r.Domain)\$($r.SamAccountName)"
        }
        else { [string]$r.SamAccountName }
        if ([string]::IsNullOrWhiteSpace($identity)) { return }
        $who = if (-not [string]::IsNullOrWhiteSpace($r.DisplayName)) { [string]$r.DisplayName }
        else { $identity }

        $this.ReapLensWarm()   # startup agent warm has served its purpose once a real pick runs
        $this.CloseSearchPopup()
        $this.LensVm.SetLoading($who)
        $this.HomeVm.SetPerson($this.LensVm)

        # Session cache: re-picking the same person within the TTL renders instantly
        # instead of re-running the de-elevated lookup.
        $cacheKey = $identity.ToLowerInvariant()
        $cached = $this.LensCache[$cacheKey]
        if ($null -ne $cached -and
            ([datetime]::UtcNow - [datetime]$cached.At) -lt $this.LensCacheTtl) {
            $this.LensToken++   # stales any in-flight lookup; its late result is discarded
            $this.LensVm.Apply([PersonLens]::FromJson([string]$cached.Json))
            $this.WireLensDeviceCommands()
            return
        }

        # Newest pick wins: bump the token and drop any in-flight lookup.
        $this.LensToken++
        $token = $this.LensToken
        foreach ($j in @($this.LensJobs)) { $this.DisposeJob($j.Ps) }
        $this.LensJobs.Clear()

        try {
            $worker = Join-Path $this.Config.SourceRoot 'Scripts\LensLookupWorker.ps1'
            # Sam hint: lets the child start the SCCM affinity query in parallel with
            # its AD user read instead of waiting to resolve the SAM first.
            $job = $this.StartPoolScript($worker, @{
                    Identity   = $identity
                    SiteServer = $this.Config.GetAdminServiceHost()
                    SourceRoot = $this.Config.SourceRoot
                    Sam        = [string]$r.SamAccountName
                })
            $job.Token = $token
            $job.Key = $cacheKey
            $job.InfoSeen = 0
            $job.StartedAt = [datetime]::UtcNow
            $this.LensJobs.Add($job)
            $this.LensPollTimer.Start()
        }
        catch {
            $this.Logger.LogException("Lens lookup could not start for $identity", $_)
            $this.LensVm.SetLoading($who)
            $this.LensVm.Set('IsLoading', $false)
            $this.LensVm.Set('HasError', $true)
            $this.LensVm.Set('StatusText', "Could not start the lookup: $_")
        }
    }

    # Poll the in-flight lens lookup: mid-flight, stream any 'LensPartial' Information
    # record into the VM; on completion parse the bundle, populate, wire, and cache.
    [void] PollLens() {
        foreach ($job in @($this.LensJobs)) {
            # The partial (directory facts) arrives on the Information stream before the
            # SCCM/BitLocker crawl finishes - apply it so the pane fills early.
            if ($job.Token -eq $this.LensToken) {
                $stream = $job.Ps.Streams.Information
                while ([int]$job.InfoSeen -lt $stream.Count) {
                    $rec = $stream[[int]$job.InfoSeen]
                    $job.InfoSeen = [int]$job.InfoSeen + 1
                    if ($rec.Tags -contains 'LensPartial') {
                        $this.LensVm.ApplyPartial([PersonLens]::FromJson([string]$rec.MessageData))
                        # Partial 2 carries name-only device rows - make Add work on them.
                        $this.WireLensDeviceCommands()
                    }
                }
            }
            if (-not $job.Handle.IsCompleted) { continue }
            $json = ''
            try { $json = (@($job.Ps.EndInvoke($job.Handle)) -join '') }
            catch { $this.Logger.LogException("Lens lookup failed", $_) }
            $this.DisposeJob($job.Ps)
            [void]$this.LensJobs.Remove($job)
            if ($job.Token -ne $this.LensToken) { continue }   # a newer pick supersedes this

            $lens = [PersonLens]::FromJson($json)
            $this.LensVm.Apply($lens)
            $this.WireLensDeviceCommands()
            $lensMs = [int]([datetime]::UtcNow - [datetime]$job.StartedAt).TotalMilliseconds
            $this.Logger.LogInfo("Lens lookup for '$($job.Key)' completed in ${lensMs}ms ($($lens.Devices.Count) device(s), $($lens.Errors.Count) error(s)).")

            # Cache clean results (memory only; see LensCache) for instant TTL re-picks.
            if ($lens.Errors.Count -eq 0 -and $job.Key) {
                $this.LensCache[[string]$job.Key] = @{ At = [datetime]::UtcNow; Json = $json }
            }
        }
        if ($this.LensJobs.Count -eq 0) { $this.LensPollTimer.Stop() }
    }

    # Wires each Lens device's Add command to drop its WSID into the machine list.
    hidden [void] WireLensDeviceCommands() {
        $presenter = $this
        foreach ($dev in $this.LensVm.Devices) {
            $capName = [string]$dev.Name
            $add = { param($p) $presenter.OnAddDeviceToList($capName) }.GetNewClosure()
            $dev.AddCommand = [RelayCommand]::new([System.Action[object]]$add)
        }
    }

    # A Lens device was added: drop its WSID into the machine list via HomePresenter's
    # Add/pick flow (row + IP prefetch + inventory + move-to-top). The Lens stays open.
    [void] OnAddDeviceToList([string]$wsid) {
        if ([string]::IsNullOrWhiteSpace($wsid)) { return }
        $this.Home.EnsureRow($wsid)
        $this.Home.PrefetchIp($wsid)
        $this.Home.StartInventory($wsid, $true)
        $this.Home.MoveRowToTop($wsid)
        $this.Home.UpdateEmptyHint()
        if ($this.Toasts) { $this.Toasts.ShowInfo($wsid, "Added $wsid to the machine list.") }
    }

    [void] CloseSearchPopup() {
        if ($this.SearchPopup) { $this.SearchPopup.IsOpen = $false }
    }

    # Nudges the open popup's offset to force WPF to recompute its placement
    # relative to the (now-moved) search box. No-op when the popup is closed.
    [void] RepositionSearchPopup() {
        if ($null -eq $this.SearchPopup -or -not $this.SearchPopup.IsOpen) { return }
        $cur = $this.SearchPopup.HorizontalOffset
        $this.SearchPopup.HorizontalOffset = $cur + 1
        $this.SearchPopup.HorizontalOffset = $cur
    }
}
