# ============================================================
# Concentrate AI - opencode Setup (Windows PowerShell 5.1+ / PowerShell 7+)
# Usage:
#   irm https://raw.githubusercontent.com/AjayK47/concentrate-opencode/main/setup-opencode.ps1 | iex
#
#   # With options:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/AjayK47/concentrate-opencode/main/setup-opencode.ps1))) -Key sk-cn-... -Model claude-sonnet-5-5
#
#   # From a downloaded copy:
#   powershell -ExecutionPolicy Bypass -File setup-opencode.ps1 [-Key <API_KEY>] [-Model <MODEL_ID>] [-NoDefault]
# ============================================================

param(
  [string]$Key = "",
  [string]$Model = "",
  [switch]$NoDefault
)

# Everything runs in a child scope: nothing leaks into the caller's session, and
# failures `return` instead of `exit` (which would close an `irm | iex` window).
& {
  $VERSION = "1.0.0"
  $API_BASE = "https://api.concentrate.ai"
  $DOCS_URL = "https://github.com/AjayK47/concentrate-opencode"
  $PROVIDER_ID = "concentrate"
  $DEFAULT_MODEL = "claude-sonnet-5-5"
  $DEFAULT_SMALL_MODEL = "claude-haiku-4-5"

  $ErrorActionPreference = "Stop"
  $ProgressPreference = "SilentlyContinue"
  # Windows PowerShell 5.1 on older systems defaults to TLS 1.0.
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

  # --- Helpers ---
  function Info($msg) { Write-Host "i  $msg" -ForegroundColor Cyan }
  function Ok($msg)   { Write-Host "+  $msg" -ForegroundColor Green }
  function Warn($msg) { Write-Host "!  $msg" -ForegroundColor Yellow }
  function Fail($msg) { throw [System.Exception]::new($msg) }

  function Confirm-Choice($prompt, $default) {
    $suffix = if ($default -eq "y") { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "  $prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $default }
    return $answer -match "^[Yy]"
  }

  function Read-Secret($prompt) {
    $secure = Read-Host "  $prompt" -AsSecureString
    return (New-Object System.Net.NetworkCredential("", $secure)).Password
  }

  function Get-Masked($value) {
    if ($value.Length -le 12) { return "****" }
    return $value.Substring(0, 8) + "..." + $value.Substring($value.Length - 4)
  }

  # Remove // and /* */ comments and trailing commas, leaving strings intact.
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

  # Returns @{ Data = <object>; HadComments = <bool> }
  function Read-JsonFile($path) {
    if (-not (Test-Path -LiteralPath $path)) { return @{ Data = [pscustomobject]@{}; HadComments = $false } }
    $raw = [System.IO.File]::ReadAllText($path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{ Data = [pscustomobject]@{}; HadComments = $false } }
    $clean = Remove-JsonComments $raw
    return @{ Data = ($clean | ConvertFrom-Json); HadComments = ($clean.Trim() -ne $raw.Trim()) }
  }

  # UTF-8 without BOM: opencode's JSON parser rejects a leading BOM.
  function Write-JsonFile($path, $data) {
    $json = $data | ConvertTo-Json -Depth 32
    [System.IO.File]::WriteAllText($path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
  }

  function Set-Prop($obj, $name, $value) {
    $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
  }

  function Get-StatusCode($err) {
    $resp = $err.Exception.Response
    if ($null -eq $resp) { return $null }
    return [int]$resp.StatusCode
  }

  function Get-Usd($price) {
    if ($null -eq $price -or $null -eq $price.price) { return $null }
    return $price.price.USD
  }

  function ConvertTo-OpencodeModel($m) {
    $routes = @()
    if ($m.providers) { $routes = @($m.providers.PSObject.Properties | ForEach-Object { $_.Value }) }
    $caps = $m.capabilities

    $imageIn = [bool]($caps -and $caps.image_input -and $caps.image_input.supported)
    $pdfIn = [bool]($caps -and $caps.pdf_input -and $caps.pdf_input.supported)
    $thinking = [bool]($caps -and $caps.thinking -and $caps.thinking.supported)
    $effort = [bool]($caps -and $caps.effort -and $caps.effort.supported)

    $toolCall = @($routes | Where-Object { $_.supports -and $_.supports.tools -and $_.supports.tools.function_calling -eq $true }).Count -gt 0
    $temperature = @($routes | Where-Object { $_.supports -and $_.supports.temperature -eq $true }).Count -gt 0
    $routeReasoning = @($routes | Where-Object { $_.supports -and $_.supports.reasoning }).Count -gt 0

    $inputs = @("text")
    if ($imageIn) { $inputs += "image" }
    if ($pdfIn) { $inputs += "pdf" }

    $name = $m.display_name
    if (-not $name) { $name = $m.name }
    if (-not $name) { $name = $m.id }

    $entry = [ordered]@{
      name        = $name
      attachment  = ($inputs.Count -gt 1)
      reasoning   = ($thinking -or $effort -or $routeReasoning)
      tool_call   = $toolCall
      temperature = $temperature
      modalities  = [ordered]@{ input = $inputs; output = @("text") }
    }

    # PowerShell 7 turns ISO date strings into DateTime while parsing.
    $created = $m.created_at
    if ($created -is [datetime]) { $entry.release_date = $created.ToUniversalTime().ToString("yyyy-MM-dd") }
    elseif ($created -and "$created".Length -ge 10) { $entry.release_date = "$created".Substring(0, 10) }

    $context = $m.max_input_tokens
    if (-not $context) { $context = ($routes | ForEach-Object { [long]$_.context_window } | Measure-Object -Maximum).Maximum }
    $output = $m.max_tokens
    if (-not $output) { $output = ($routes | ForEach-Object { [long]$_.max_output_tokens } | Measure-Object -Maximum).Maximum }
    $limit = [ordered]@{}
    if ($context) { $limit.context = $context }
    if ($output) { $limit.output = $output }
    if ($limit.Count -gt 0) { $entry.limit = $limit }

    # Price shown in opencode is per 1M tokens; use the first (primary) route.
    $priced = $routes | Where-Object { $_.pricing } | Select-Object -First 1
    if ($priced) {
      $tokens = @($priced.pricing)[0].tokens
      $cost = [ordered]@{}
      $in = Get-Usd $tokens.input; $out = Get-Usd $tokens.output
      if ($null -ne $in -and $null -ne $out) {
        $cost.input = $in; $cost.output = $out
        if ($tokens.cache) {
          $read = Get-Usd $tokens.cache.read
          if ($null -ne $read) { $cost.cache_read = $read }
          if ($tokens.cache.write) {
            $write = Get-Usd $tokens.cache.write.ephemeral_5m_input_tokens
            if ($null -ne $write) { $cost.cache_write = $write }
          }
        }
        $entry.cost = $cost
      }
    }
    return $entry
  }

  # --- Banner ---
  Write-Host ""
  Write-Host "============================================================"
  Write-Host "  Concentrate AI - opencode Setup  v$VERSION"
  Write-Host "============================================================"
  Write-Host ""

  try {
    # --- Prerequisite checks ---
    $opencodeCmd = Get-Command opencode -ErrorAction SilentlyContinue
    if ($opencodeCmd) {
      Ok "opencode CLI detected"
    } else {
      Warn "opencode CLI not found - configuring anyway."
      Write-Host "     Install it with: npm install -g opencode-ai   (or see https://opencode.ai)" -ForegroundColor DarkGray
    }

    $homeDir = [Environment]::GetFolderPath("UserProfile")
    $configRoot = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $homeDir ".config" }
    $dataRoot = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $homeDir ".local\share" }
    $configDir = Join-Path $configRoot "opencode"
    $dataDir = Join-Path $dataRoot "opencode"
    $authFile = Join-Path $dataDir "auth.json"

    # opencode merges opencode.json then opencode.jsonc; edit whichever exists,
    # preferring .jsonc since it wins the merge.
    $configFile = Join-Path $configDir "opencode.jsonc"
    if (-not (Test-Path -LiteralPath $configFile)) { $configFile = Join-Path $configDir "opencode.json" }

    # --- Get API key ---
    $apiKey = $Key
    if (-not $apiKey -and $env:CONCENTRATE_API_KEY) {
      Info "Found existing CONCENTRATE_API_KEY in environment: $(Get-Masked $env:CONCENTRATE_API_KEY)"
      if (Confirm-Choice "Use existing key?" "y") { $apiKey = $env:CONCENTRATE_API_KEY }
    }
    if (-not $apiKey -and (Test-Path -LiteralPath $authFile)) {
      try {
        $stored = (Read-JsonFile $authFile).Data.$PROVIDER_ID.key
        if ($stored) {
          Info "Found existing Concentrate key in opencode: $(Get-Masked $stored)"
          if (Confirm-Choice "Use existing key?" "y") { $apiKey = $stored }
        }
      } catch {}
    }
    if (-not $apiKey) {
      Write-Host ""
      Write-Host "  Get your API key at: https://concentrate.ai/api-keys"
      Write-Host ""
      $apiKey = Read-Secret "Enter your Concentrate API key"
    }
    $apiKey = "$apiKey".Trim()
    if (-not $apiKey) { Fail "API key cannot be empty." }

    # --- Verify API key ---
    Write-Host ""
    Info "Verifying API key..."
    $headers = @{ Authorization = "Bearer $apiKey" }
    $body = '{"model":"bluelobster/gpt-oss-20b","input":[{"role":"user","content":"test"}],"max_output_tokens":1}'
    try {
      $null = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$API_BASE/v1/responses" -Headers $headers -ContentType "application/json" -Body $body
    } catch {
      $code = Get-StatusCode $_
      if ($null -eq $code) { Fail "Could not reach $API_BASE. Check your internet connection." }
      if ($code -eq 401 -or $code -eq 403) { Fail "Invalid API key. Check your key at https://concentrate.ai/settings/api-keys" }
      if ($code -eq 402) { Fail "Your API key is valid but has no credits left. Top up at https://concentrate.ai" }
      Fail "API verification failed (HTTP $code)."
    }
    Ok "API key verified"

    # --- Fetch model catalog ---
    Info "Fetching model catalog..."
    try {
      $catalog = Invoke-RestMethod -UseBasicParsing -Uri "$API_BASE/v1/models/" -Headers $headers
    } catch {
      Fail "Could not fetch the model catalog from $API_BASE/v1/models/."
    }
    $models = [ordered]@{}
    foreach ($m in @($catalog.data)) {
      if ($m.id) { $models[$m.id] = ConvertTo-OpencodeModel $m }
    }
    if ($models.Count -eq 0) { Fail "Unexpected response from $API_BASE/v1/models/." }
    Ok "Found $($models.Count) models"

    # --- Choose default model ---
    $setDefault = $false
    $defaultModel = $Model
    if ($Model) {
      $setDefault = $true
    } elseif (-not $NoDefault) {
      Write-Host ""
      if (Confirm-Choice "Make Concentrate opencode's default provider?" "y") {
        $setDefault = $true
        $defaultModel = Read-Host "  Default model [$DEFAULT_MODEL]"
        if ([string]::IsNullOrWhiteSpace($defaultModel)) { $defaultModel = $DEFAULT_MODEL }
      }
    }

    # --- Configure opencode ---
    Write-Host ""
    Info "Configuring opencode..."
    New-Item -ItemType Directory -Force -Path $configDir, $dataDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    if (Test-Path -LiteralPath $configFile) { Copy-Item -LiteralPath $configFile -Destination "$configFile.backup.$stamp" }
    if (Test-Path -LiteralPath $authFile) { Copy-Item -LiteralPath $authFile -Destination "$authFile.backup.$stamp" }

    try {
      $loaded = Read-JsonFile $configFile
    } catch {
      Fail "Could not parse $configFile. Fix it or move it aside, then re-run."
    }
    $config = $loaded.Data
    if (-not $config.PSObject.Properties['$schema']) { Set-Prop $config '$schema' "https://opencode.ai/config.json" }
    if (-not $config.provider) { Set-Prop $config "provider" ([pscustomobject]@{}) }
    Set-Prop $config.provider $PROVIDER_ID ([ordered]@{
      npm     = "@ai-sdk/openai-compatible"
      name    = "Concentrate"
      env     = @("CONCENTRATE_API_KEY")
      options = [ordered]@{ baseURL = "https://api.concentrate.ai/v1" }
      models  = $models
    })

    $notes = @()
    if ($setDefault) {
      if ($models.Contains($defaultModel)) {
        Set-Prop $config "model" "$PROVIDER_ID/$defaultModel"
        if ($models.Contains($DEFAULT_SMALL_MODEL)) { Set-Prop $config "small_model" "$PROVIDER_ID/$DEFAULT_SMALL_MODEL" }
        $notes += "OK Default model set to $PROVIDER_ID/$defaultModel"
      } else {
        $notes += "WARN Model '$defaultModel' is not in the catalog - default model left unchanged."
      }
    }
    if ($loaded.HadComments) { $notes += "WARN Comments in your config were removed (a backup was saved alongside it)." }

    Write-JsonFile $configFile $config
    Ok "Provider added ($configFile)"

    # Store the key the same way `opencode auth login` does.
    $auth = [pscustomobject]@{}
    if (Test-Path -LiteralPath $authFile) { try { $auth = (Read-JsonFile $authFile).Data } catch {} }
    Set-Prop $auth $PROVIDER_ID ([ordered]@{ type = "api"; key = $apiKey })
    Write-JsonFile $authFile $auth
    Ok "API key stored ($authFile)"

    foreach ($note in $notes) {
      if ($note.StartsWith("OK ")) { Ok $note.Substring(3) } else { Warn $note.Substring(5) }
    }

    foreach ($other in @((Join-Path $configDir "opencode.json"), (Join-Path $configDir "config.json"))) {
      if ($other -ne $configFile -and (Test-Path -LiteralPath $other) -and (Select-String -LiteralPath $other -SimpleMatch "`"$PROVIDER_ID`"" -Quiet)) {
        Warn "$other also mentions `"$PROVIDER_ID`" and is merged with $configFile - remove it there to avoid stale models."
      }
    }

    # --- Health check ---
    Write-Host ""
    Info "Running health check..."
    if ($opencodeCmd) {
      $listed = 0
      try { $listed = @(& opencode models $PROVIDER_ID 2>$null | Where-Object { "$_" -like "$PROVIDER_ID/*" }).Count } catch {}
      if ($listed -gt 0) { Ok "opencode sees $listed Concentrate models" }
      else { Warn "opencode did not list any Concentrate models - run: opencode models $PROVIDER_ID" }
    } else {
      Ok "API connection healthy"
    }

    # --- Summary ---
    $shownModel = if ($setDefault -and $models.Contains($defaultModel)) { $defaultModel } else { $DEFAULT_MODEL }
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "  Setup Complete!" -ForegroundColor Green
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "  What was configured:"
    Write-Host ""
    Write-Host "    + $configFile  (provider `"$PROVIDER_ID`", $($models.Count) models)" -ForegroundColor Green
    Write-Host "    + $authFile  (API key)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next steps:"
    Write-Host ""
    Write-Host "  1. Launch opencode:"
    Write-Host "       opencode" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  2. Pick a Concentrate model with /models, or start with one directly:"
    Write-Host "       opencode -m $PROVIDER_ID/$shownModel" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Re-run this script anytime to pick up new models." -ForegroundColor DarkGray
    Write-Host "  Docs: $DOCS_URL" -ForegroundColor DarkGray
    Write-Host ""
  } catch {
    Write-Host "x  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
  }
}
