Function Set-PlaceholderLogic {
    param($txt, $placeHolder)
    if ([string]::IsNullOrWhiteSpace($txt.Text) -or $txt.Text -eq $placeHolder) {
        Show-Placeholder $txt $placeHolder
    } else {
        $txt.Tag = $null
    }
    $txt.Add_GotFocus({
        if ($this.Tag -eq "placeholder") {
            $this.Text = ""
            $this.Tag = $null
        }
    })
    $txt.Add_LostFocus({
        if ([string]::IsNullOrWhiteSpace($this.Text)) {
            Show-Placeholder $this $placeHolder
        } elseif ($this.Tag -ne "placeholder") {
            $script:HomeViewText = $this.Text
        }
    })
}

Function Show-Placeholder {
    param($txt, $placeHolder)
    $txt.Text = $placeHolder
    $txt.Tag = "placeholder"
}

Function Initialize-SearchBar {
    param(
        $textBox,
        $wsidFilePath
    )
    if ($wsidFilePath -and (Test-Path $wsidFilePath)) {
        $lines = Get-Content -Path $wsidFilePath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $textBox.Text = $lines -join "`r`n"
    }
}

