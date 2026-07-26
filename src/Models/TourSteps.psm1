<#
.SYNOPSIS
    The first-run guided-tour script: an ordered list of steps.

.DESCRIPTION
    Each step is one idea, spotlighting one UI element (TargetKey) with a callout. The
    presenter maps TargetKey to a live control and positions the spotlight + callout;
    an empty TargetKey is a centered card (the welcome). Kept short (6 steps) per the
    Guided Tour pattern - one concept each, always escapable so it never overwhelms.

.NOTES
    Pure content/data so it can be unit-tested headless; no WPF here.
#>
class TourStep {
    [string] $Title
    [string] $Body
    [string] $TargetKey    # '' = centered welcome; else a control key the presenter resolves
    [string] $Placement    # 'center' | 'below' | 'above' | 'right' | 'left'
}

class TourSteps {
    static [TourStep[]] Build() {
        return @(
            [TourStep]@{
                Title     = 'Welcome to DONUT'
                Body      = "DONUT runs Dell Command Update on your machines, remotely. Here's a 30-second tour of the essentials - skip anytime with Esc."
                TargetKey = ''
                Placement = 'center'
            }
            [TourStep]@{
                Title     = 'Add machines - or find a person'
                Body      = 'Type machine names and press Enter to add them. Or search a person to look them up in AD and open their Lens. Enter shows what it will do - it never guesses wrong.'
                TargetKey = 'search'
                Placement = 'below'
            }
            [TourStep]@{
                Title     = 'Pick a mode, then Run'
                Body      = 'This button cycles between Scan and Apply. Pick one, then Run a single machine or Run all to act on the whole list.'
                TargetKey = 'mode'
                Placement = 'below'
            }
            [TourStep]@{
                Title     = 'Your machines, by status'
                Body      = "Machines you add live here, grouped worst-first - anything needing attention (failed or reboot-needed) rises to the top. Clear removes the settled ones."
                TargetKey = 'list'
                Placement = 'right'
            }
            [TourStep]@{
                Title     = 'Inspect a machine'
                Body      = 'Select a machine to open its detail pane - inventory, the available updates a scan found, a live log, and an on-demand storage scan of its biggest folders.'
                TargetKey = 'detail'
                Placement = 'left'
            }
            [TourStep]@{
                Title     = 'Settings & help'
                Body      = 'The gear opens Settings - keybinds, startup, and options save as you change them. The page icon opens the full docs, and the ? replays this tour.'
                TargetKey = 'settings'
                Placement = 'below'
            }
        )
    }
}
