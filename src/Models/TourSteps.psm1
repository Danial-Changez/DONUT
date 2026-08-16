<#
.SYNOPSIS
    The first-run guided-tour script: an ordered list of steps.

.DESCRIPTION
    Each step is one idea, spotlighting one UI element (TargetKey) with a callout. The
    presenter maps TargetKey to a live control and positions the spotlight and callout,
    and an empty TargetKey is a centered card (the welcome). Six steps per the Guided
    Tour pattern, one concept each, always escapable so it never overwhelms.

.NOTES
    Pure content/data so it can be unit-tested headless; no WPF here.
#>
class TourStep {
    [string] $Title
    [string] $Body
    [string] $TargetKey    # '' = centered welcome, else a control key the presenter resolves
    [string] $Placement    # 'center' | 'below' | 'above' | 'right' | 'left'
}

class TourSteps {
    static [TourStep[]] Build() {
        return @(
            [TourStep]@{
                Title     = 'Welcome to DONUT'
                Body      = 'DONUT runs Dell Command Update on your machines remotely. ' +
                'This tour covers the essentials, and Esc skips it anytime.'
                TargetKey = ''
                Placement = 'center'
            }
            [TourStep]@{
                Title     = 'Add Machines, or Find a Person'
                Body      = 'Search a machine and press Enter to add the top match, or paste several names ' +
                'at once. Search a person instead to open their Lens, with each device''s model, ' +
                'service tag and BitLocker key.'
                TargetKey = 'search'
                Placement = 'below'
            }
            [TourStep]@{
                Title     = 'Pick a Mode, Then Run'
                Body      = 'This pill switches between Scan and Apply. Pick one, then Run a single machine ' +
                'or Run All for the whole list.'
                TargetKey = 'mode'
                Placement = 'below'
            }
            [TourStep]@{
                Title     = 'Your Machines, by Status'
                Body      = 'Machines live here, worst first, so anything failed or needing a reboot rises ' +
                'to the top. Clear removes the ones that are not running.'
                TargetKey = 'list'
                Placement = 'right'
            }
            [TourStep]@{
                Title     = 'Inspect a Machine'
                Body      = 'Select a machine for its inventory, the updates a scan found, a live log, ' +
                'and Storage for its biggest folders.'
                TargetKey = 'detail'
                Placement = 'left'
            }
            [TourStep]@{
                Title     = 'Settings and Admin Rights'
                Body      = 'The gear opens Settings, saved as you change them. Remote work needs administrator ' +
                'rights, so if the title bar reads LIMITED the first fleet action asks once and restarts ' +
                'DONUT. The page icon opens the docs, and ? replays this tour.'
                TargetKey = 'settings'
                Placement = 'below'
            }
        )
    }
}
