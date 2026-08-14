using namespace System.Windows.Controls
using namespace System.Windows.Threading
using namespace System.Collections.Generic
using namespace Donut.Mvvm
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\..\Core\RunspaceManager.psm1"
using module "..\..\Core\PoolScriptJob.psm1"
using module "..\..\Services\ActiveDirectoryService.psm1"
using module "..\..\Models\PersonLens.psm1"
using module "..\..\Models\AdSearchResult.psm1"
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

    The search timers are 100ms debounce / 60ms poll, and both are back at those values
    after a raise to 250/150 that cost more than it saved. The debounce was raised on the
    theory that typing re-fanned-out and the superseded shells held the lane (AbortSearch
    cancels through BeginStop, which is asynchronous); that was argued, never measured, and
    it charged every completed search a flat +150ms - on the interactive path, above the
    150ms bar the same change set for whether an optimization is worth its complexity.
    The poll raise was simply wrong: SearchPollTimer starts only when a fan-out begins and
    stops when the last job lands, so it never ticks while idle and a fast tick costs
    nothing, while a slow one is dead time before the dropdown paints AND inflates the
    per-forest elapsed, which is measured when the poll notices rather than when the job
    finished. Raise the debounce again only on log evidence: the fan-out count per search
    and the (superseded) marker are there to provide it.

    DescribeSearchTiming splits each leg into queue / search / rows / notice from the
    worker's AdTiming record, so the next call here is made on numbers - a total alone
    cannot separate the directory from the machinery around it. That is how the render
    below was found: all four forests finished within 27ms of each other, yet their totals
    spread across 465ms, because each landed leg re-rendered the whole dropdown on the UI
    thread before the next was even read. PollSearch renders once per tick for that reason.

    There is no "Add as a machine" row, and Enter can never fabricate a machine. It acts
    on real rows only - the top-ranked computer when any matched, else the top user - so
    a pattern prefix like "cap-" adds an actual CAP- machine instead of a junk "cap-"
    card (the add row's failure mode that got it removed). The one non-row Enter is a
    pasted list: 2+ tokens split on whitespace/commas go through OnSearch, which is how
    several machines are added at once. A picked computer lands on the machine pane
    directly (the pick is the add) and the dropdown closes, like a user pick.

    Cancelling the other forests once one answers would NOT be an optimization: the
    forests hold disjoint populations, so a cancelled forest's people never enter the pool
    AdSearchRank orders - the strongest match overall can live in the slowest forest, and
    which people appear (including the row Enter pre-selects) would depend on which forest
    won the race. Cancel-on-supersede is the legitimate form and AbortSearch already does it.

    ResolveOwners keeps exactly one batch in flight, and the batch is deliberate. The
    agent serves owner requests inline on its 150ms serve loop, so a second parent job
    would queue behind the first for no extra throughput while holding a second of the
    three interactive runspaces - the lane a Lens pick needs to dispatch immediately.
    It reaps on the Lens poll tick rather than owning a timer, since both wait on the
    same agent.
    $Home is a duck-typed back-reference to HomePresenter (a typed import would be a
    using-module cycle); the complete machine-side seam is: Resolution.PrefetchIp,
    EnsureRow, StartInventory, MoveRowToTop. Event-handler scriptblocks capture
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
    # Set by MainPresenter to pop the shell's QR overlay, null until wired so it no-ops.
    [object] $OnShowQr
    # Set by MainPresenter to open the reset-password overlay, null until wired like OnShowQr.
    [object] $OnShowReset
    [TextBox] $SearchBar               # the dual-use GoogleSearchBar (finder wiring only)

    # AD live-search (search-bar dropdown: computers + locked-out users)
    [ActiveDirectoryService] $AdService
    # System.Windows.Controls.Primitives.Popup. Its rows render via binding.
    [object]          $SearchPopup
    # The dropdown ListBox. SelectedIndex follows the search bar's Down/Up keys.
    [object]          $ResultsList
    [DispatcherTimer] $SearchDebounce
    [DispatcherTimer] $SearchPollTimer
    [int]             $SearchToken = 0
    [List[hashtable]] $SearchJobs          # in-flight @{ Ps; Handle; Token }
    [HashSet[string]] $ForestsWarned       # toast once per dead forest, not per keystroke
    [List[hashtable]] $AdWarmJobs          # one-shot startup AD warm jobs (results discarded)
    # Accumulated rows for the current token (forests stream in).
    [List[object]]    $SearchResults
    [HashSet[string]] $SearchSeen          # dedupe keys (Kind|Domain|Sam) for the current token
    # The popup shows ~8 at a time, and each extra row costs ~3ms on the UI thread.
    [int]             $MaxDropdownRows = 15
    hidden [bool]     $DeactivateWired = $false   # hooked once, see WireWindowDeactivate
    [List[hashtable]] $UnlockJobs          # in-flight @{ Ps; Handle; Upn }
    [DispatcherTimer] $UnlockPollTimer

    # Pool jobs mid-async-stop, disposed by the reaper once each goes terminal.
    [List[object]]    $StoppingJobs
    [DispatcherTimer] $ReapTimer

    # User Lens: a pick runs LensLookupWorker over the persistent de-elevated agent.
    [PersonLensViewModel] $LensVm          # bound to the detail pane in Person mode
    [List[hashtable]]     $LensJobs         # in-flight @{ Ps; Handle; Token }
    [object]              $OwnerJob         # the one in-flight machine-owner batch, or $null
    [object]              $SoftwareJob      # the one in-flight software lookup, or $null
    hidden [string]       $SoftwareKey = '' # the pick whose software the reap may apply
    # identity -> @{ At; Json }, memory only beside LensCache (no secrets, same lifetime).
    hidden [hashtable] $SoftwareCache = @{}
    [DispatcherTimer]     $LensPollTimer
    [int]                 $LensToken = 0    # newest pick wins, stale results are discarded
    # Startup agent warm-up @{ Ps; Handle; StartedAt }, reaped on the first pick.
    [object]              $LensWarmJob
    # Extra -WarmOnly runs so every interactive runspace parses the worker graph early.
    hidden [List[hashtable]] $LensWarmExtras
    # identity -> @{ At; Json }, memory only: it holds BitLocker keys and must never hit disk.
    hidden [hashtable] $LensCache = @{}
    [timespan] $LensCacheTtl = [timespan]::FromMinutes(15)
    # Longer than every in-worker timeout (60s, 45s), so those report the real reason.
    [timespan] $LensDeadline = [timespan]::FromSeconds(90)

    FinderPresenter(
        [AppConfig]$config,
        [HomeViewModel]$homeVm,
        [LogService]$logger,
        [ToastService]$toasts,
        [DialogPresenter]$dialogs,
        [object]$homePresenter
    ) {
        $this.Config = $config
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
        $this.ForestsWarned = [HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        # Every ms here is dead time before the search starts (see .NOTES for the 250ms try).
        $this.SearchDebounce = [DispatcherTimer]::new()
        $this.SearchDebounce.Interval = [TimeSpan]::FromMilliseconds(100)
        $this.SearchDebounce.Add_Tick({ $presenter.RunAdSearch() }.GetNewClosure())
        # Gated on SearchJobs, so it never ticks while idle and its interval is paint latency.
        $this.SearchPollTimer = [DispatcherTimer]::new()
        $this.SearchPollTimer.Interval = [TimeSpan]::FromMilliseconds(60)
        $this.SearchPollTimer.Add_Tick({ $presenter.PollSearch() }.GetNewClosure())
        $this.UnlockJobs = [List[hashtable]]::new()
        $this.UnlockPollTimer = [DispatcherTimer]::new()
        $this.UnlockPollTimer.Interval = [TimeSpan]::FromMilliseconds(150)
        $this.UnlockPollTimer.Add_Tick({ $presenter.PollUnlock() }.GetNewClosure())

        # Reaper for async-stopped pool jobs, running only while some are pending.
        $this.StoppingJobs = [List[object]]::new()
        $this.ReapTimer = [DispatcherTimer]::new()
        $this.ReapTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $this.ReapTimer.Add_Tick({ $presenter.ReapStoppingJobs() }.GetNewClosure())

        # User Lens: one shared VM (reused per pick) + a poll timer for the lookups.
        $this.LensVm = [PersonLensViewModel]::new()
        $this.LensJobs = [List[hashtable]]::new()
        $this.LensWarmExtras = [List[hashtable]]::new()
        $this.LensPollTimer = [DispatcherTimer]::new()
        # Gated on in-flight lookups, so a fast tick is free and it halves partial paint lag.
        $this.LensPollTimer.Interval = [TimeSpan]::FromMilliseconds(100)
        $this.LensPollTimer.Add_Tick({ $presenter.PollLens() }.GetNewClosure())
    }

    # The ActionBar namescope holds the finder's controls, composed by HomePresenter first.
    [void] Initialize([System.Windows.FrameworkElement]$view) {
        $this.ViewContent = $view
        $this.SearchBar = $this.ViewContent.FindName('GoogleSearchBar')
        $this.SearchPopup = $this.ViewContent.FindName('SearchResultsPopup')
        $this.ResultsList = $this.ViewContent.FindName('SearchResultsList')

        $presenter = $this
        if ($this.SearchBar) {
            $this.SearchBar.Add_TextChanged({ $presenter.OnSearchTextChanged() }.GetNewClosure())
            $this.SearchBar.Add_PreviewKeyDown({
                    param($s, $e)
                    switch ([string]$e.Key) {
                        'Escape' { $presenter.CloseSearchPopup(); $e.Handled = $true }
                        'Down' { $presenter.MoveHighlight(1); $e.Handled = $true }
                        'Up' { $presenter.MoveHighlight(-1); $e.Handled = $true }
                        'Return' { $presenter.CommitSelection(); $e.Handled = $true }
                    }
                }.GetNewClosure())
            # Focus moving into the dropdown must not close it, or its buttons lose the click.
            $this.SearchBar.Add_LostKeyboardFocus({
                    param($s, $e)
                    $child = if ($presenter.SearchPopup) { $presenter.SearchPopup.Child } else { $null }
                    $inPopup = $null -ne $child -and
                    $e.NewFocus -is [System.Windows.Media.Visual] -and
                    $child.IsAncestorOf($e.NewFocus)
                    if (-not $inPopup) { $presenter.CloseSearchPopup() }
                }.GetNewClosure())
            # A WPF Popup floats above other apps' windows, so it must close with deactivation.
            if ($this.SearchBar.IsLoaded) { $this.WireWindowDeactivate() }
            else { $this.SearchBar.Add_Loaded({ $presenter.WireWindowDeactivate() }.GetNewClosure()) }
        }
    }

    # GetWindow returns null before the visual tree attaches, so wire once from Initialize.
    [void] WireWindowDeactivate() {
        if ($this.DeactivateWired -or $null -eq $this.SearchBar) { return }
        $win = [System.Windows.Window]::GetWindow($this.SearchBar)
        if ($null -eq $win) { return }
        $this.DeactivateWired = $true
        $presenter = $this
        $win.Add_Deactivated({ $presenter.CloseSearchPopup() }.GetNewClosure())
    }

    # Moves the highlight by $dir, skipping header rows and wrapping. Opens a closed dropdown.
    [void] MoveHighlight([int]$dir) {
        if ($null -eq $this.ResultsList -or $null -eq $this.SearchPopup) { return }
        $items = $this.HomeVm.SearchResults
        $count = $items.Count
        if ($count -eq 0) { return }
        if (-not $this.SearchPopup.IsOpen) { $this.SearchPopup.IsOpen = $true }

        $idx = $this.ResultsList.SelectedIndex
        for ($step = 0; $step -lt $count; $step++) {
            $idx += $dir
            if ($idx -lt 0) { $idx = $count - 1 }
            elseif ($idx -ge $count) { $idx = 0 }
            if (-not $items[$idx].IsHeader) { break }
        }
        if ($idx -ge 0 -and $idx -lt $count -and -not $items[$idx].IsHeader) {
            $this.ResultsList.SelectedIndex = $idx
            $this.ResultsList.ScrollIntoView($items[$idx])
        }
    }

    # With no highlighted row, only a pasted list (2+ tokens) adds anything. See .NOTES.
    [void] CommitSelection() {
        if ($this.SearchPopup -and $this.SearchPopup.IsOpen -and $null -ne $this.ResultsList) {
            $sel = $this.ResultsList.SelectedItem
            if ($null -ne $sel -and -not $sel.IsHeader -and $null -ne $sel.PickCommand) {
                $sel.PickCommand.Execute($null)
                return
            }
        }
        $text = if ($this.SearchBar) { $this.SearchBar.Text.Trim() } else { '' }
        if (@($text -split '[\s,]+' | Where-Object { $_ }).Count -ge 2) { $this.Home.OnSearch() }
    }

    # Tears the Lens agent down through the pool worker, so the UI never parse-loads
    # PersonLensService. The Closed handler awaits $global:LensTeardownJob.
    [void] OnAppClosing() {
        try {
            $global:LensTeardownJob = $this.StartLensWorker(@{ StopAgent = $true })
        }
        catch {
            $this.Logger.LogException("Lens agent teardown could not start", $_)
        }
    }

    # Thin seams over the shared PoolScriptJob mechanics. The timers stay owned here.
    hidden [hashtable] StartPoolScript([string]$scriptPath, [hashtable]$parameters) {
        return [PoolScriptJob]::Start($scriptPath, $parameters)
    }

    # Starts LensLookupWorker on the pool with the shared site and root arguments.
    hidden [hashtable] StartLensWorker([hashtable]$extra) {
        $worker = Join-Path $this.Config.SourceRoot 'Scripts\LensLookupWorker.ps1'
        return $this.StartPoolScript($worker, $extra + @{
                SiteServer = $this.Config.GetAdminServiceHost()
                SourceRoot = $this.Config.SourceRoot
            })
    }

    hidden [void] DisposeJob([object]$ps) {
        if ([PoolScriptJob]::DisposeSafe($ps, $this.StoppingJobs, $this.Logger)) {
            if (-not $this.ReapTimer.IsEnabled) { $this.ReapTimer.Start() }
        }
    }

    hidden [void] ReapStoppingJobs() {
        if ([PoolScriptJob]::ReapStopping($this.StoppingJobs, $this.Logger)) {
            $this.ReapTimer.Stop()
        }
    }

    # One throwaway search per forest primes the worker graph and each forest's LDAP bind.
    [void] WarmAdSearch() {
        $worker = Join-Path $this.Config.SourceRoot 'Scripts\AdSearchWorker.ps1'
        foreach ($domain in $this.AdService.Domains) {
            try {
                # 'zzz' is a throwaway prefix: it warms the bind, results are discarded.
                $warm = $this.StartPoolScript($worker, @{ Domains = @($domain); Prefix = 'zzz' })
                $warm.Domain = $domain
                $this.AdWarmJobs.Add($warm)
            }
            catch {
                $this.Logger.LogException("AD search warm-up could not start for '$domain'", $_)
            }
        }
    }

    # Disposes the startup AD warm jobs. Their results are never read.
    hidden [void] ReapAdWarm() {
        if ($null -eq $this.AdWarmJobs -or $this.AdWarmJobs.Count -eq 0) { return }
        foreach ($j in @($this.AdWarmJobs)) { $this.DisposeJob($j.Ps) }
        $this.AdWarmJobs.Clear()
    }

    # Never blocks. The handle is reaped on the first pick, and failures are logged then.
    [void] WarmLens() {
        try {
            $this.LensWarmJob = $this.StartLensWorker(@{ WarmOnly = $true })
            # A pick dispatches two jobs onto any free runspace, so every runspace must
            # already hold the worker graph. The agent mutex makes the extras near no-ops.
            for ($i = 1; $i -lt [RunspaceManager]::InteractiveSize; $i++) {
                $this.LensWarmExtras.Add($this.StartLensWorker(@{ WarmOnly = $true }))
            }
        }
        catch {
            $this.Logger.LogException("Lens agent warm-up could not start", $_)
        }
    }

    # One request for the whole list, one in flight at a time. See .NOTES.
    [void] ResolveOwners([string[]]$machines, [object]$onResolved) {
        if (@($machines).Count -eq 0 -or $null -ne $this.OwnerJob) { return }
        try {
            $job = $this.StartLensWorker(@{ OwnerOf = @($machines) })
            $job.OnResolved = $onResolved
            $job.Count = @($machines).Count
            $this.OwnerJob = $job
            $this.LensPollTimer.Start()
        }
        catch {
            $this.Logger.LogException('Owner lookup could not start', $_)
        }
    }

    # Hands back @{ machine = owner }, and a failed batch just leaves the cards unnamed.
    hidden [void] ReapOwners() {
        $job = $this.OwnerJob
        if ($null -eq $job -or -not $job.Handle.IsCompleted) { return }
        $this.OwnerJob = $null
        try {
            $json = (@($job.Ps.EndInvoke($job.Handle)) -join '')
            if ($json) {
                $bundle = $json | ConvertFrom-Json
                if ($bundle.error) { $this.Logger.LogWarning("Owner lookup: $($bundle.error)") }
                $map = @{}
                foreach ($row in @($bundle.owners)) {
                    if ($row.owner) { $map[[string]$row.name] = [string]$row.owner }
                }
                # Per-machine cost decides whether this ever stops being one serial batch.
                $ms = [long]([datetime]::UtcNow - [datetime]$job.StartedAt).TotalMilliseconds
                $each = if ($job.Count -gt 0) { [long]($ms / $job.Count) } else { 0 }
                $this.Logger.LogDebug("Owner batch: $($job.Count) machine(s) in $($ms)ms (~$($each)ms each), $($map.Count) named")
                if ($job.OnResolved -and $map.Count -gt 0) { & $job.OnResolved $map }
            }
        }
        catch { $this.Logger.LogException('Owner lookup result could not be read', $_) }
        finally { $this.DisposeJob($job.Ps) }
    }

    # The pick's parallel software lookup: a cache hit applies at once, else one job runs.
    hidden [void] StartSoftwareLookup([string]$identity, [string]$sam, [string]$cacheKey) {
        $this.SoftwareKey = $cacheKey
        $cached = $this.SoftwareCache[$cacheKey]
        if ($null -ne $cached -and
            ([datetime]::UtcNow - [datetime]$cached.At) -lt $this.LensCacheTtl) {
            $parsed = [LensDeployment]::ParseBundle([string]$cached.Json)
            $rows = [LensDeployment]::FilterByCollection(@($parsed.Rows),
                $this.Config.GetLensSoftwareCollectionFilter())
            $this.LensVm.ApplySoftware($rows, [string]$parsed.Error)
            return
        }
        # Newest pick wins here too, so a stale in-flight lookup is dropped, not awaited.
        if ($null -ne $this.SoftwareJob) {
            $this.DisposeJob($this.SoftwareJob.Ps)
            $this.SoftwareJob = $null
        }
        try {
            $job = $this.StartLensWorker(@{ Sam = $sam; SoftwareFor = $identity })
            $job.Key = $cacheKey
            $this.SoftwareJob = $job
            $this.LensPollTimer.Start()
        }
        catch { $this.Logger.LogException('Software lookup could not start', $_) }
    }

    # Milliseconds the worker sat queued on the pool before its first statement ran.
    hidden [long] QueuedMs([hashtable]$job) {
        try {
            foreach ($rec in $job.Ps.Streams.Information) {
                if ($rec.Tags -notcontains 'WorkerStart') { continue }
                $started = ([datetime]$rec.MessageData).ToUniversalTime()
                return [long]($started - [datetime]$job.StartedAt).TotalMilliseconds
            }
        }
        catch { }
        return -1
    }

    # Applies the software rows once the parallel lookup lands (newest pick only).
    hidden [void] ReapSoftware() {
        $job = $this.SoftwareJob
        if ($null -eq $job -or -not $job.Handle.IsCompleted) { return }
        $this.SoftwareJob = $null
        try {
            $json = (@($job.Ps.EndInvoke($job.Handle)) -join '')
            $parsed = [LensDeployment]::ParseBundle($json)
            $ms = [long]([datetime]::UtcNow - [datetime]$job.StartedAt).TotalMilliseconds
            $rowCount = @($parsed.Rows).Count
            $queued = $this.QueuedMs($job)
            $this.Logger.LogDebug(
                "Software lookup for '$($job.Key)': $rowCount row(s) in ${ms}ms (queued ${queued}ms)")
            if ($parsed.Error) { $this.Logger.LogWarning("Software lookup: $($parsed.Error)") }
            elseif ($json) {
                $this.SoftwareCache[[string]$job.Key] = @{ At = [datetime]::UtcNow; Json = $json }
            }
            if ([string]$job.Key -eq $this.SoftwareKey) {
                # The config filter narrows at render time, so the cache stays unfiltered.
                $rows = [LensDeployment]::FilterByCollection(@($parsed.Rows),
                    $this.Config.GetLensSoftwareCollectionFilter())
                $this.LensVm.ApplySoftware($rows, [string]$parsed.Error)
            }
        }
        catch { $this.Logger.LogException('Software lookup result could not be read', $_) }
        finally { $this.DisposeJob($job.Ps) }
    }

    # Reap the startup agent warm job (logs its result: '' = started, else the reason).
    hidden [void] ReapLensWarm() {
        if ($null -eq $this.LensWarmJob) { return }
        $job = $this.LensWarmJob
        $this.LensWarmJob = $null
        try {
            if ($job.Handle.IsCompleted) {
                # No elapsed here: this fires on the first pick, so it would time the user.
                $reason = (@($job.Ps.EndInvoke($job.Handle)) -join '')
                if ($reason) { $this.Logger.LogWarning("Lens agent warm-up: $reason") }
                else { $this.Logger.LogInfo('Lens agent warmed and ready.') }
            }
            # A hung warm agent must stop asynchronously or it blocks the UI thread.
            $this.DisposeJob($job.Ps)
        }
        catch { $this.DisposeJob($job.Ps) }
        # The extra runspace warms carry no result worth reading, so they just retire.
        foreach ($extra in @($this.LensWarmExtras)) { $this.DisposeJob($extra.Ps) }
        $this.LensWarmExtras.Clear()
    }

    # --- AD live search (search-bar dropdown) ---

    # Closes the dropdown when the prefix is too short to search.
    [void] OnSearchTextChanged() {
        $text = if ($this.SearchBar) { $this.SearchBar.Text } else { '' }
        if ([string]::IsNullOrWhiteSpace($text) -or
            $text.Trim().Length -lt $this.AdService.MinPrefix) {
            $this.SearchDebounce.Stop()
            $this.AbortSearch()
            $this.CloseSearchPopup()
            return
        }
        # Drop stale AD hits so they can't linger under the new text.
        $this.AbortSearch()
        $this.RenderDropdown()
        $this.SearchDebounce.Stop()
        $this.SearchDebounce.Start()
    }

    # Stales the token so a late forest result can't re-open the dropdown.
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

        # Drop the previous keystroke's jobs so a new search can't stack behind stale ones.
        $this.AbortSearch()

        $this.SearchToken++
        $token = $this.SearchToken

        # One job per forest, so the dropdown isn't gated on the slowest forest's round-trip.
        $worker = Join-Path $this.Config.SourceRoot 'Scripts\AdSearchWorker.ps1'
        foreach ($domain in $this.AdService.Domains) {
            try {
                $job = $this.StartPoolScript($worker, @{ Domains = @($domain); Prefix = $prefix })
                $job.Token = $token
                $job.Domain = $domain
                $job.Prefix = $prefix
                $this.SearchJobs.Add($job)
            }
            catch {
                $this.Logger.LogException("AD search could not start for '$domain'", $_)
            }
        }
        # How often this fires while typing says whether the debounce is doing its job.
        $this.Logger.LogDebug("AD search fan-out '$prefix': $($this.SearchJobs.Count) forest(s)")
        if ($this.SearchJobs.Count -gt 0) { $this.SearchPollTimer.Start() }
        else { $this.CloseSearchPopup() }
    }

    # True means the forest could not answer at all, which is not the same as no matches.
    hidden [bool] ReportForestFailure([object]$job) {
        $stream = $job.Ps.Streams.Warning
        if ($stream.Count -eq 0) { return $false }
        foreach ($w in $stream) { $this.Logger.LogWarning("AD search: $($w.Message)") }
        $stream.Clear()
        # Once per forest per session: an unreachable forest would otherwise nag per keystroke.
        if ($this.ForestsWarned.Add([string]$job.Domain) -and $this.Toasts) {
            $this.Toasts.ShowWarning('Directory Search',
                "$($job.Domain) did not answer, so its people and machines are missing from these results.")
        }
        return $true
    }

    # Splits a leg into the spans that sum to its total, empty without AdTiming. See .NOTES.
    hidden [string] DescribeSearchTiming([object]$job) {
        $stamped = $null
        foreach ($info in $job.Ps.Streams.Information) {
            if ($info.Tags -contains 'AdTiming') { $stamped = [string]$info.MessageData; break }
        }
        if ([string]::IsNullOrWhiteSpace($stamped)) { return '' }
        $parts = $stamped -split ' '
        if ($parts.Count -ne 3) { return '' }

        $begun = [datetime]::new([long]$parts[0], [System.DateTimeKind]::Utc)
        $ended = [datetime]::new([long]$parts[2], [System.DateTimeKind]::Utc)
        $searchMs = [long]$parts[1]
        # Neither runspace side sees both: queue is pool slot plus compile, notice is poll lag.
        $queue = [long]($begun - [datetime]$job.StartedAt).TotalMilliseconds
        $rowMs = [long](($ended - $begun).TotalMilliseconds) - $searchMs
        $notice = [long]([datetime]::UtcNow - $ended).TotalMilliseconds
        return " (queue $queue, search $searchMs, rows $rowMs, notice $notice)"
    }

    # Folds each landed forest into the current token's union. Stale tokens are discarded.
    [void] PollSearch() {
        $landed = $false
        foreach ($job in @($this.SearchJobs)) {
            if (-not $job.Handle.IsCompleted) { continue }
            $results = @()
            try { $results = @($job.Ps.EndInvoke($job.Handle)) }
            catch { $this.Logger.LogException("AD search failed", $_) }
            # Measured from dispatch, so it counts pool queue wait as well as the round trip.
            $ms = [long]([datetime]::UtcNow - [datetime]$job.StartedAt).TotalMilliseconds
            # Both stream reads go before DisposeJob, since no contract promises them after.
            $failed = $this.ReportForestFailure($job)
            $timing = $this.DescribeSearchTiming($job)
            $this.DisposeJob($job.Ps)
            [void]$this.SearchJobs.Remove($job)
            $stale = if ($job.Token -ne $this.SearchToken) { ' (superseded)' } else { '' }
            $outcome = if ($failed) { 'FAILED' } else { "$($results.Count) hit(s)" }
            $this.Logger.LogDebug("AD search $($job.Domain) '$($job.Prefix)': $($ms)ms$timing, $outcome$stale")
            if ($job.Token -ne $this.SearchToken) { continue }
            foreach ($row in $results) {
                $key = "$($row.Kind)|$($row.Domain)|$($row.SamAccountName)"
                if ($this.SearchSeen.Add($key)) { $this.SearchResults.Add($row) }
            }
            $landed = $true
        }
        # Once per tick, not per landed forest: per-leg renders put ~450ms on the last forest.
        if ($landed) {
            $renderAt = [datetime]::UtcNow
            $drawn = $this.RenderDropdown()
            $renderMs = [long]([datetime]::UtcNow - $renderAt).TotalMilliseconds
            $this.Logger.LogDebug("AD dropdown render: $drawn drawn of $($this.SearchResults.Count) pooled in $($renderMs)ms")
        }
        if ($this.SearchJobs.Count -eq 0) { $this.SearchPollTimer.Stop() }
    }

    # A header row, so the hint can't be picked or reached by the arrow keys.
    hidden [void] AddOverflowHint([object]$items, [int]$total) {
        $hidden = $total - $this.MaxDropdownRows
        if ($hidden -le 0) { return }
        $items.Add([SearchRowViewModel]::Header("+$hidden MORE - KEEP TYPING TO NARROW"))
    }

    # Returns the drawn item count, which the cap divorces from the pooled count.
    [int] RenderDropdown() {
        $text = if ($this.SearchBar) { $this.SearchBar.Text.Trim() } else { '' }
        if ($text.Length -lt $this.AdService.MinPrefix) { $this.CloseSearchPopup(); return 0 }

        $presenter = $this
        # A case-insensitive clash with a property breaks assignment inside PS class methods.
        $items = [System.Collections.Generic.List[object]]::new()

        $raw = $this.SearchResults.ToArray()
        $computers = [AdSearchRank]::Order(@($raw | Where-Object { $_.Kind -eq 'Computer' }), $text)
        $users = [AdSearchRank]::Order(@($raw | Where-Object { $_.Kind -eq 'User' }), $text)
        $firstUserIndex = -1

        $firstComputerIndex = -1
        if ($computers.Count -gt 0) {
            $items.Add([SearchRowViewModel]::Header('COMPUTERS'))
            $firstComputerIndex = $items.Count   # the next item added is the top-ranked computer
            foreach ($c in ($computers | Select-Object -First $this.MaxDropdownRows)) {
                $vm = [SearchRowViewModel]::FromResult($c)
                $cap = [string]$c.Name
                $pick = { param($p) $presenter.OnPickComputer($cap) }.GetNewClosure()
                $vm.PickCommand = [RelayCommand]::new([System.Action[object]]$pick)
                $items.Add($vm)
            }
            $this.AddOverflowHint($items, $computers.Count)
        }
        if ($users.Count -gt 0) {
            $items.Add([SearchRowViewModel]::Header('USERS'))
            $firstUserIndex = $items.Count   # the next item added is the first user row
            foreach ($u in ($users | Select-Object -First $this.MaxDropdownRows)) {
                $vm = [SearchRowViewModel]::FromResult($u)
                # Clicking a user row opens the Lens (its directory + SCCM devices).
                $capU = $u
                $pickU = { param($p) $presenter.OnPickUser($capU) }.GetNewClosure()
                $vm.PickCommand = [RelayCommand]::new([System.Action[object]]$pickU)
                if ($vm.CanUnlock) {
                    $unlock = { param($p) $presenter.OnUnlockUser($u) }.GetNewClosure()
                    $vm.UnlockCommand = [RelayCommand]::new([System.Action[object]]$unlock)
                }
                if ($vm.CanReset) {
                    $reset = { param($p) $presenter.OnResetPassword($u) }.GetNewClosure()
                    $vm.ResetCommand = [RelayCommand]::new([System.Action[object]]$reset)
                }
                $items.Add($vm)
            }
            $this.AddOverflowHint($items, $users.Count)
        }

        # Nothing matched, so no popup shell and Enter has nothing to act on. See .NOTES.
        if ($items.Count -eq 0) { $this.CloseSearchPopup(); return 0 }

        # One Set, not Clear plus N Adds: each Add invalidates the ListBox layout (~3ms a row).
        $this.HomeVm.Set('SearchResults',
            [System.Collections.ObjectModel.ObservableCollection[object]]::new($items))

        # Pre-select what Enter does: the top-ranked computer, else the top user (see .NOTES).
        $sel = if ($firstComputerIndex -ge 0) { $firstComputerIndex }
        elseif ($firstUserIndex -ge 0) { $firstUserIndex }
        else { -1 }
        if ($this.ResultsList) { $this.ResultsList.SelectedIndex = $sel }
        if ($this.SearchPopup) { $this.SearchPopup.IsOpen = $true }
        return $items.Count
    }

    # The pick is the add: straight onto the machine pane, and the dropdown closes.
    [void] OnPickComputer([string]$name) {
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $this.CloseSearchPopup()
        $vm = $this.Home.EnsureRow($name)
        $this.Home.Resolution.PrefetchIp($name)
        $this.Home.StartInventory($name, $true)
        $this.Home.MoveRowToTop($name)
        # Shared-VM selection, same as OnSearch's flow: shows the new card's detail pane.
        $this.HomeVm.SetSelected($vm)
    }

    # MainPresenter owns the reset card, its pool job, and the toasts.
    [void] OnResetPassword([object]$r) {
        $this.CloseSearchPopup()
        if ($null -ne $r -and $this.OnShowReset) { & $this.OnShowReset $r }
    }

    # Locked user chosen: confirm, unlock against its home domain, toast the result.
    [void] OnUnlockUser([object]$r) {
        $this.CloseSearchPopup()
        if ($null -eq $r) { return }
        $upn = if ([string]::IsNullOrWhiteSpace($r.UserPrincipalName)) { [string]$r.SamAccountName }
        else { [string]$r.UserPrincipalName }

        $confirmed = $this.DialogPresenter.ShowConfirmation(
            "Unlock Account",
            "Unlock the locked-out account '$upn'.",
            @("$([string]$r.SamAccountName)  @  $([string]$r.Domain)"),
            'Unlock', $false
        )
        if (-not $confirmed) { return }

        # Unlock-ADAccount can take a moment, so it runs off the UI thread.
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
            if ($this.Toasts) { $this.Toasts.ShowError("Unlock Failed", "Could not start the unlock for $upn.") }
        }
    }

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
                if ($ok) { $this.Toasts.ShowSuccess("Account Unlocked", $job.Upn) }
                else { $this.Toasts.ShowError("Unlock Failed", "Could not unlock $($job.Upn). Check your rights and connectivity.") }
            }
        }
        if ($this.UnlockJobs.Count -eq 0) { $this.UnlockPollTimer.Stop() }
    }

    # --- User Lens (person -> devices) ---

    # UPN is the best identity, falling back to DOMAIN\SAM or SAM.
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
        # Drop the machine highlight so re-clicking the same machine still re-fires selection.
        if ($this.Home.MachineList) { $this.Home.MachineList.SelectedItem = $null }

        # Re-picking the same person within the TTL renders without a second lookup.
        $cacheKey = $identity.ToLowerInvariant()
        $cached = $this.LensCache[$cacheKey]
        if ($null -ne $cached -and
            ([datetime]::UtcNow - [datetime]$cached.At) -lt $this.LensCacheTtl) {
            $this.LensToken++   # stales any in-flight lookup, its late result is discarded
            $this.LensVm.Apply([PersonLens]::FromJson([string]$cached.Json))
            $this.WireLensDeviceCommands()
            $this.StartSoftwareLookup($identity, [string]$r.SamAccountName, $cacheKey)
            return
        }

        # Newest pick wins: bump the token and drop any in-flight lookup.
        $this.LensToken++
        $token = $this.LensToken
        foreach ($j in @($this.LensJobs)) { $this.DisposeJob($j.Ps) }
        $this.LensJobs.Clear()

        try {
            # The Sam hint lets the child run the SCCM query in parallel with its AD user read.
            $job = $this.StartLensWorker(@{ Identity = $identity; Sam = [string]$r.SamAccountName })
            $job.Token = $token
            $job.Key = $cacheKey
            $job.InfoSeen = 0
            $job.Who = $who   # Apply() blanks DisplayName on an error lens without it
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
        # Dispatched last, so software can never queue ahead of the pick on a full pool.
        $this.StartSoftwareLookup($identity, [string]$r.SamAccountName, $cacheKey)
    }

    # Streams any 'LensPartial' record into the VM before the final bundle lands.
    [void] PollLens() {
        # Shares this tick rather than owning a second timer: all wait on the same agent.
        $this.ReapOwners()
        $this.ReapSoftware()
        foreach ($job in @($this.LensJobs)) {
            # The partial lands before the SCCM/BitLocker crawl, so the pane fills early.
            if ($job.Token -eq $this.LensToken) {
                $stream = $job.Ps.Streams.Information
                while ([int]$job.InfoSeen -lt $stream.Count) {
                    $rec = $stream[[int]$job.InfoSeen]
                    $job.InfoSeen = [int]$job.InfoSeen + 1
                    if ($rec.Tags -contains 'LensPartial') {
                        $at = [datetime]::UtcNow - [datetime]$job.StartedAt
                        $this.Logger.LogDebug(
                            "Lens partial for '$($job.Key)' at $([int]$at.TotalMilliseconds)ms")
                        $this.LensVm.ApplyPartial([PersonLens]::FromJson([string]$rec.MessageData))
                        # Partial 2 carries name-only device rows, so Add must work on them.
                        $this.WireLensDeviceCommands()
                    }
                }
            }
            if (-not $job.Handle.IsCompleted) {
                $this.RetireExpiredLens($job)
                continue
            }
            $json = ''
            try { $json = (@($job.Ps.EndInvoke($job.Handle)) -join '') }
            catch { $this.Logger.LogException("Lens lookup failed", $_) }
            $this.DisposeJob($job.Ps)
            [void]$this.LensJobs.Remove($job)
            if ($job.Token -ne $this.LensToken) { continue }   # a newer pick supersedes this

            # The job is out of LensJobs, so a throw here strands the pane on its placeholder.
            try {
                $lens = [PersonLens]::FromJson($json)
                $this.LensVm.Apply($lens)
                $this.WireLensDeviceCommands()
                $lensMs = [int]([datetime]::UtcNow - [datetime]$job.StartedAt).TotalMilliseconds
                $queued = $this.QueuedMs($job)
                $msg = "Lens lookup for '$($job.Key)': ${lensMs}ms (queued ${queued}ms), " +
                "$($lens.Devices.Count) device(s), $($lens.Errors.Count) error(s)."
                $this.Logger.LogInfo($msg)
                # The agent's cumulative stage marks split the gather like the AD breadcrumb.
                if ($lens.Timings.Count -gt 0) {
                    $stages = @($lens.Timings.GetEnumerator() |
                            ForEach-Object { "$($_.Key) $($_.Value)ms" }) -join ', '
                    $this.Logger.LogDebug("Lens stages for '$($job.Key)': $stages")
                }

                # Cache clean results (memory only, see LensCache) for instant TTL re-picks.
                if ($lens.Errors.Count -eq 0 -and $job.Key) {
                    $this.LensCache[[string]$job.Key] = @{ At = [datetime]::UtcNow; Json = $json }
                }
            }
            catch {
                $this.Logger.LogException("Lens result could not be applied", $_)
                $failed = [PersonLens]::FromError(
                    "The lookup finished but its result could not be displayed: $($_.Exception.Message)")
                $failed.DisplayName = [string]$job.Who
                $this.LensVm.Apply($failed)
            }
        }
        # Owner and software lookups outlive the pick that started them, so they keep it alive.
        if ($this.LensJobs.Count -eq 0 -and $null -eq $this.OwnerJob -and
            $null -eq $this.SoftwareJob) { $this.LensPollTimer.Stop() }
    }

    # A lookup past LensDeadline is never coming back, so retire it with a reason.
    hidden [void] RetireExpiredLens([hashtable]$job) {
        $waited = [datetime]::UtcNow - [datetime]$job.StartedAt
        if ($waited -lt $this.LensDeadline) { return }
        $secs = [int]$waited.TotalSeconds
        $this.Logger.LogWarning("Lens lookup for '$($job.Key)' gave up after ${secs}s with no result.")
        $this.DisposeJob($job.Ps)
        [void]$this.LensJobs.Remove($job)
        if ($job.Token -ne $this.LensToken) { return }   # a newer pick already owns the pane
        $lens = [PersonLens]::FromError(
            "The lookup did not return within ${secs}s. Try again once running jobs finish.")
        $lens.DisplayName = [string]$job.Who
        $this.LensVm.Apply($lens)
    }

    # Each device gets an Add command and a QR command over its latest recovery key.
    hidden [void] WireLensDeviceCommands() {
        $presenter = $this
        foreach ($dev in $this.LensVm.Devices) {
            $capName = [string]$dev.Name
            $add = { param($p) $presenter.OnAddDeviceToList($capName) }.GetNewClosure()
            $dev.AddCommand = [RelayCommand]::new([System.Action[object]]$add)

            $vm = $dev
            $qr = { param($p)
                if ($presenter.OnShowQr -and -not [string]::IsNullOrWhiteSpace($vm.LatestKey)) {
                    & $presenter.OnShowQr $vm.LatestKey $vm.Name
                }
            }.GetNewClosure()
            $dev.ShowQrCommand = [RelayCommand]::new([System.Action[object]]$qr)
        }
    }

    # The Lens person seeds the row's owner, so a name on screen is never re-queried.
    [void] OnAddDeviceToList([string]$wsid) {
        if ([string]::IsNullOrWhiteSpace($wsid)) { return }
        $this.Home.EnsureRow($wsid, [string]$this.LensVm.DisplayName)
        $this.Home.Resolution.PrefetchIp($wsid)
        $this.Home.StartInventory($wsid, $true)
        $this.Home.MoveRowToTop($wsid)
        if ($this.Toasts) { $this.Toasts.ShowInfo($wsid, "Added to the machine list.") }
    }

    [void] CloseSearchPopup() {
        if ($this.SearchPopup) { $this.SearchPopup.IsOpen = $false }
        if ($this.ResultsList) { $this.ResultsList.SelectedIndex = -1 }
    }

    # Nudging the offset is what forces WPF to recompute the popup's placement.
    [void] RepositionSearchPopup() {
        if ($null -eq $this.SearchPopup -or -not $this.SearchPopup.IsOpen) { return }
        $cur = $this.SearchPopup.HorizontalOffset
        $this.SearchPopup.HorizontalOffset = $cur + 1
        $this.SearchPopup.HorizontalOffset = $cur
    }
}
