# Pull Request (PR) Template

## Pull Request Title
Say what changed as a short sentence in the commit voice, not a label.
For example, "the machine card counts its updates properly".

## Description
- What changed and why. A few lines is enough.
- Link the docs page or the decisions entry when one moved with the change.

## Type of Change
<!-- Note: Use 'x' or 'X' to fill in the checkboxes where applicable. -->
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Documentation update

## How It Was Verified
CI runs the format check, lint, both test suites, and the Release build on
every PR, so a green run covers those. Check what CI cannot see:
- [ ] New or changed logic carries tests, and `tools\Invoke-Tests.ps1` passes locally
- [ ] UI change previewed with `tools\Show-View.ps1` (capture in Screenshots below)
- [ ] Installer or update change exercised with a new MSI on a lab machine
- [ ] Fleet actions validated on an Analyst workstation

## Checklist
- [ ] I followed the project structure and the coding style (`docs/development/coding-style.md`)
- [ ] I updated the docs where behaviour changed (the UI reference for UI rules)
- [ ] I resolved any errors or warnings produced by my change

## Screenshots
Attach a capture for anything visual. `tools\Show-View.ps1 -Screenshot` renders
any view, the composed main window (`-Main`), or the error dialog
(`-ErrorDialog`) without launching the app.

## Additional Notes
Anything reviewers should know: deliberate shortcuts, open questions, follow-ups.
