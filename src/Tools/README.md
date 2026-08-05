# src/Tools

Third-party binaries DONUT deploys to remote machines. Neither one is committed
here, and neither may be redistributed, so both are fetched by the launcher's
first-run bootstrap (`src/Launcher/Bootstrap.cs`) instead.

| Tool | Licence position | How it arrives |
|------|------------------|----------------|
| `psexec.exe` | Sysinternals forbids redistribution | Downloaded, Microsoft signature verified, installed to `System32`. Workers invoke it from `PATH`. |
| `wiztree64.exe` | Free for personal use only. Commercial use needs a paid supporter or Enterprise code, and **bundling it into another application needs a paid Distribution License** | Downloaded, Antibody Software signature verified, staged into this folder inside the extracted app tree. |

## wiztree64.exe (required for the Storage scan)

The **Storage** action deploys this binary to the target's
`C:\temp\DONUT\`, runs a fast MFT scan of `C:` as SYSTEM via PsExec, and copies
the resulting `folders.csv` back to parse the largest folders.

The bootstrap downloads the portable zip from <https://diskanalyzer.com/download>,
keeps only `WizTree64.exe`, and writes it into this folder inside the **installed**
app tree (`...\DONUT\app\src\Tools\`). It **skips the download when the file already
exists**, so a copy you place there yourself wins and survives later launches. Do
that when your copy is registered with your supporter code, because a fresh download
is unregistered.

WizTree is not embedded into `Donut.Launcher.exe`: its EULA forbids incorporating
it into other software without a paid **Distribution License subscription**. If you
hold one, re-adding an `EmbeddedResource` for it in `Donut.Launcher.csproj` is the
supported way to ship it in the MSI.

`ExecutionService.DeployWizTree` resolves it relative to `SourceRoot`. If it is
missing the scan fails with a clear "Bundled wiztree64.exe not found" message and
nothing else is affected.

:::caution
Using WizTree in a business requires a purchased licence regardless of how the
binary got onto the machine. The automatic download is a convenience, not a
licence. See <https://diskanalyzer.com/donate>.
:::

### How it's invoked (headless)

```
wiztree64.exe "C:" /export="C:\temp\DONUT\folders.csv" /admin=1 ^
  /exportfolders=1 /exportfiles=0 /sortby=1 /exportmaxdepth=4
```

`/admin=1` is the fast MFT scan; with `/export` WizTree scans and self-exits. The
exact command lives in `ExecutionService.BuildScanCommand` so it can be swapped for
a pure-PowerShell folder walk if session-0 (non-interactive SYSTEM) invocation
proves unreliable on a given machine.
