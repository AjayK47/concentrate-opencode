# Concentrate AI - opencode Uninstall (Windows PowerShell 5.1+ / PowerShell 7+)
# Removes the provider, default model and stored key added by setup-opencode.ps1.
# CONCENTRATE_API_KEY is left alone, since other Concentrate integrations share it.
# Usage:
#   irm https://raw.githubusercontent.com/AjayK47/concentrate-opencode/main/uninstall-opencode.ps1 | iex

& {
  $PROVIDER_ID = "concentrate"
  $ErrorActionPreference = "Stop"

  function Info($msg) { Write-Host ">  $msg" -ForegroundColor Yellow }
  function Ok($msg)   { Write-Host "+  $msg" -ForegroundColor Green }
  function Err($msg)  { Write-Host "x  $msg" -ForegroundColor Red }

  function Remove-JsonComments([string]$text) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0; $n = $text.Length
    while ($i -lt $n) {
      $c = $text[$i]
      if ($c -eq '"') {
        $j = $i + 1
        while ($j -lt $n -and $text[$j] -ne '"') { if ($text[$j] -eq '\') { $j += 2 } else { $j += 1 } }
        [void]$sb.Append($text.Substring($i, [Math]::Min($j + 1, $n) - $i))
        $i = $j + 1
      } elseif ($c -eq '/' -and $i + 1 -lt $n -and $text[$i + 1] -eq '/') {
        while ($i -lt $n -and $text[$i] -ne "`n") { $i++ }
      } elseif ($c -eq '/' -and $i + 1 -lt $n -and $text[$i + 1] -eq '*') {
        $end = $text.IndexOf("*/", $i + 2)
        if ($end -lt 0) { $i = $n } else { $i = $end + 2 }
      } else {
        [void]$sb.Append($c); $i++
      }
    }
    return [regex]::Replace($sb.ToString(), ",(\s*[}\]])", '$1')
  }

  function Read-JsonFile($path) {
    $raw = [System.IO.File]::ReadAllText($path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]@{} }
    return (Remove-JsonComments $raw) | ConvertFrom-Json
  }

  function Write-JsonFile($path, $data) {
    $json = $data | ConvertTo-Json -Depth 32
    [System.IO.File]::WriteAllText($path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
  }

  Write-Host ""
  Write-Host "Concentrate AI - opencode Uninstall"
  Write-Host ""

  $homeDir = [Environment]::GetFolderPath("UserProfile")
  $configRoot = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $homeDir ".config" }
  $dataRoot = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $homeDir ".local\share" }
  $configDir = Join-Path $configRoot "opencode"
  $authFile = Join-Path (Join-Path $dataRoot "opencode") "auth.json"
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"

  # --- Remove provider and default model from every global config file ---
  Info "Cleaning opencode config..."
  $cleaned = $false
  foreach ($name in @("opencode.jsonc", "opencode.json", "config.json")) {
    $file = Join-Path $configDir $name
    if (-not (Test-Path -LiteralPath $file)) { continue }
    if (-not (Select-String -LiteralPath $file -SimpleMatch $PROVIDER_ID -Quiet)) { continue }
    try {
      $config = Read-JsonFile $file
      $changed = $false
      if ($config.provider -and $config.provider.PSObject.Properties[$PROVIDER_ID]) {
        $config.provider.PSObject.Properties.Remove($PROVIDER_ID)
        if (@($config.provider.PSObject.Properties).Count -eq 0) { $config.PSObject.Properties.Remove("provider") }
        $changed = $true
      }
      foreach ($key in @("model", "small_model")) {
        if ("$($config.$key)".StartsWith("$PROVIDER_ID/")) {
          $config.PSObject.Properties.Remove($key)
          $changed = $true
        }
      }
      if ($changed) {
        Copy-Item -LiteralPath $file -Destination "$file.backup.$stamp"
        Write-JsonFile $file $config
        Ok "$file cleaned"
        $cleaned = $true
      }
    } catch {
      Err "Could not parse $file - left unchanged"
    }
  }
  if (-not $cleaned) { Ok "No opencode config needed cleaning" }

  # --- Remove stored API key ---
  if ((Test-Path -LiteralPath $authFile) -and (Select-String -LiteralPath $authFile -SimpleMatch "`"$PROVIDER_ID`"" -Quiet)) {
    Info "Removing stored API key..."
    try {
      Copy-Item -LiteralPath $authFile -Destination "$authFile.backup.$stamp"
      $auth = Read-JsonFile $authFile
      $auth.PSObject.Properties.Remove($PROVIDER_ID)
      Write-JsonFile $authFile $auth
      Ok "$authFile cleaned"
    } catch {
      Err "Could not update $authFile - left unchanged"
    }
  }

  Write-Host ""
  Write-Host "Uninstall complete!" -ForegroundColor Green
  Write-Host ""
  Write-Host "  opencode will use its other configured providers next time it starts."
  Write-Host "  Pick a new default with:"
  Write-Host ""
  Write-Host "  opencode  then  /models" -ForegroundColor Yellow
  Write-Host ""
}
