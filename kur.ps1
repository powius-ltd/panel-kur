# Panel tek satirla kurulum (Windows, PowerShell 5.1 uyumlu). Herkese acik depodan alinir; sir tasimaz: musteriye ozel olan yalniz PANEL_KOD'dur.
#
#   $env:PANEL_KOD='<kod>'; irm <adres>/kur.ps1 | iex
#
# Kod: <kN>-<salt okunur GitHub anahtari>. Anahtar yalniz api.github.com'a gider; yonlendirme elle izlenir (-MaximumRedirection 0) ve ikinci
# istek anahtarsizdir (src/lib/setup/update/github.ts ile ayni kural). Anahtar hicbir ciktiya, gunluge ya da adrese yazilmaz.
# Akis: kodu coz -> son surumu oku -> zip + SHA256SUMS indir -> ozeti dogrula -> yalniz paketin kendi dosyalarini C:\panel'e koy -> Kur.cmd.
# PANEL_KUR_KURU=1: yalniz plani yazar; hicbir sey indirmez / yazmaz. PANEL_KUR_DEPO=owner/ad: yalniz test icin depo adi.
# PANEL_KUR_YENIDEN=1: C:\panel varsa (.env.local olsun olmasin) onarim yerine YENI paket kurulur; dogrulamadan sonra eski klasor C:\panel-eski-<tarih>'e
# tasinir (ASLA silinmez), eski .env.local yeni kuruluma kopyalanir.
# "iex" ile calistigi icin `exit` YOK (musterinin penceresini kapatir): hatada `throw`. Govde fonksiyonda, son satirda cagrilir.
# Dosya yalniz ASCII (irm 5.1'de kod sayfasini yanlis okuyabilir): Turkce metinler aksansiz.

function Invoke-PanelKur {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  $apiHost = 'api.github.com'
  $owner = 'powius-ltd'
  $hedef = 'C:\panel'

  # TLS 1.2 (PowerShell 5.1 varsayilani eski olabilir; GitHub 1.2 ister).
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { throw 'Bu bilgisayar guvenli baglanti (TLS 1.2) kuramiyor. Windows guncellemelerini yapip tekrar dene.' }

  # Kod ortamdan okunur; hata iletisi kodu ASLA tekrarlamaz.
  $kod = [string]$env:PANEL_KOD
  Remove-Item Env:\PANEL_KOD -ErrorAction SilentlyContinue
  if (-not $kod) { throw 'Kurulum kodu yok. Komutu, kuran ekibin verdigi kodla ($env:PANEL_KOD=...) birlikte oldugu gibi yapistir.' }
  $m = [regex]::Match($kod, '^(k[0-9]{1,2})-(github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{30,})$')
  if (-not $m.Success) { throw 'Kurulum kodu gecerli gorunmuyor (k1-... biciminde olmali). Kodu eksiksiz, oldugu gibi yapistir; olmazsa kuran ekipten yenisini iste.' }
  $kn = $m.Groups[1].Value
  $token = $m.Groups[2].Value
  $kod = $null

  $depo = "$owner/panel-$kn-surum"
  if ($env:PANEL_KUR_DEPO) {
    if ($env:PANEL_KUR_DEPO -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$' -or $env:PANEL_KUR_DEPO.Contains('..')) { throw 'PANEL_KUR_DEPO owner/ad biciminde olmali.' }
    $depo = $env:PANEL_KUR_DEPO
  }

  # Etkilesim: terminal girdisi yoksa (Claude / Codex calistiriyorsa) Kur "sessiz" cagrilir.
  $sessiz = $false
  try { if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) { $sessiz = $true } } catch { $sessiz = $true }
  $kur = Join-Path $hedef 'Kur.cmd'
  $kuru = ($env:PANEL_KUR_KURU -eq '1')
  $yeniden = (($env:PANEL_KUR_YENIDEN -eq '1') -and (Test-Path -LiteralPath $hedef -PathType Container))

  # Kurulu panel ezilmez: .env.local varsa paket inmez, mevcut Kur calisir (onarim).
  if ((Test-Path -LiteralPath (Join-Path $hedef '.env.local')) -and -not $yeniden) {
    if ($kuru) {
      Write-Host "KURU KOSU: panel zaten kurulu ($hedef). Paket indirilmez; mevcut Kur calistirilir (onarim)."
      Write-Host 'Hicbir sey indirilmedi, hicbir dosya yazilmadi.'
      return
    }
    Write-Host "Panel zaten kurulu ($hedef); paket indirilmiyor. Kurulum denetlenip gerekirse onariliyor."
    if (-not (Test-Path -LiteralPath $kur)) { throw "$hedef icinde Kur.cmd yok. Kurulum bozuk gorunuyor; kuran ekibe haber ver." }
    Start-PanelKur $kur $sessiz
    return
  }

  if ($kuru) {
    Write-Host 'KURU KOSU: hicbir sey indirilmedi, hicbir dosya yazilmadi. Yapilacaklar:'
    Write-Host "  1. Kod cozuldu (kanal: $kn). Paket deposu: $depo"
    Write-Host "  2. Son surum okunur, panel-*.zip + SHA256SUMS indirilir (anahtar yalniz $apiHost adresine gider)."
    Write-Host '  3. Ozet (SHA-256) dogrulanir; uyusmazsa hicbir sey kurulmaz.'
    if ($yeniden) { Write-Host "  3b. Eski kurulum ($hedef) C:\panel-eski-<tarih> klasorune tasinir (silinmez); eski .env.local yeni kuruluma kopyalanir." }
    Write-Host "  4. Yalniz paketin kendi dosyalari $hedef klasorune konur."
    Write-Host ('  5. Kur.cmd calistirilir' + $(if ($sessiz) { ' (etkilesimsiz: sessiz).' } else { '.' }))
    return
  }

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('panel-kur-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    Write-Host 'Son surum okunuyor...'
    $r = Get-PanelHttp "https://$apiHost/repos/$depo/releases/latest" $token 'application/vnd.github+json' $null
    if ($r.Status -ne 200) { Stop-PanelHttp $r.Status }
    $rel = $r.Content | ConvertFrom-Json
    $zips = @($rel.assets | Where-Object { $_.name -match '^panel-[A-Za-z0-9._-]+\.zip$' })
    $sums = @($rel.assets | Where-Object { $_.name -eq 'SHA256SUMS' })
    if ($zips.Count -ne 1) { throw 'Surumde tek bir panel zip dosyasi bulunamadi. Kuran ekibe haber ver.' }
    if ($sums.Count -ne 1) { throw 'Surumde SHA256SUMS yok: dosya dogrulanamayacagi icin kurulmaz. Kuran ekibe haber ver.' }
    $zipAd = [string]$zips[0].name

    Write-Host "Indiriliyor: $zipAd"
    $sumsFile = Join-Path $tmp 'SHA256SUMS'
    $zipFile = Join-Path $tmp $zipAd
    Get-PanelAsset $apiHost $depo ([string]$sums[0].id) $token $sumsFile
    Get-PanelAsset $apiHost $depo ([string]$zips[0].id) $token $zipFile
    $token = $null

    $beklenen = $null
    foreach ($line in (Get-Content -LiteralPath $sumsFile)) {
      $lm = [regex]::Match($line.Trim(), '^([0-9a-fA-F]{64}) [ *](.+)$')
      if ($lm.Success -and ($lm.Groups[2].Value -replace '^\./', '') -eq $zipAd) { $beklenen = $lm.Groups[1].Value.ToLower(); break }
    }
    if (-not $beklenen) { throw 'SHA256SUMS icinde bu paketin ozeti yok; kurulmadi.' }
    $gercek = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipFile).Hash.ToLower()
    if ($gercek -ne $beklenen) { throw 'Indirilen dosya dogrulanamadi (ozet tutmuyor); hicbir sey kurulmadi. Internet baglantini kontrol edip tekrar dene; surerse kuran ekibe haber ver.' }
    Write-Host 'Dosya dogrulandi.'

    $ac = Join-Path $tmp 'ac'
    New-Item -ItemType Directory -Force -Path $ac | Out-Null
    try { Expand-Archive -LiteralPath $zipFile -DestinationPath $ac -Force } catch { throw 'Paket acilamadi.' }
    $kok = $null
    foreach ($d in @((Join-Path $ac 'panel'), $ac)) {
      if ((Test-Path -LiteralPath (Join-Path $d 'windows\paket-kok.txt')) -and (Test-Path -LiteralPath (Join-Path $d 'Kur.cmd'))) { $kok = $d; break }
    }
    if (-not $kok) { throw 'Paket beklenen biciminde degil; kurulmadi. Kuran ekibe haber ver.' }

    $eski = $null
    if ($yeniden) {
      $taban = 'C:\panel-eski-' + (Get-Date -Format 'yyyyMMdd-HHmm')
      $eski = $taban
      $n = 2
      while (Test-Path -LiteralPath $eski) { $eski = "$taban-$n"; $n++ }
      try { Move-Item -LiteralPath $hedef -Destination $eski -ErrorAction Stop } catch { throw "Eski kurulum tasinamadi (acik bir pencere ya da program kullaniyor olabilir); hicbir sey degismedi. Eski kurulum $hedef klasorunde duruyor." }
    }

    # YALNIZ paketin kendi dosyalari (windows\paket-kok.txt + panel-recete.json + kanal.env) hedefe kopyalanir.
    $names = @(Get-Content -LiteralPath (Join-Path $kok 'windows\paket-kok.txt') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '[\\/:]' }) + @('panel-recete.json', 'kanal.env')
    try { New-Item -ItemType Directory -Force -Path $hedef | Out-Null } catch { throw "$hedef olusturulamadi (izin?). Kuran ekibe haber ver." }
    foreach ($name in ($names | Select-Object -Unique)) {
      $src = Join-Path $kok $name
      if (Test-Path -LiteralPath $src -PathType Container) {
        robocopy $src (Join-Path $hedef $name) /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Dosyalar $hedef klasorune kopyalanamadi ($name)." }
      } elseif (Test-Path -LiteralPath $src -PathType Leaf) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $hedef $name) -Force
      }
    }
    if ($eski -and (Test-Path -LiteralPath (Join-Path $eski '.env.local'))) {
      try { Copy-Item -LiteralPath (Join-Path $eski '.env.local') -Destination (Join-Path $hedef '.env.local') -Force -ErrorAction Stop } catch { throw "Anahtarlar yeni kuruluma kopyalanamadi. Eski kurulum $eski klasorunde duruyor (silme); kuran ekibe haber ver." }
      Write-Host "Eski kurulum $eski klasorune alindi; anahtarlarin yeni kuruluma tasindi."
    }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host "Panel dosyalari $hedef klasorune konuldu. Kurulum basliyor..."
  Start-PanelKur $kur $sessiz
}

# Kur.cmd: etkilesim yoksa "sessiz" (Enter / pause beklemez). PANEL_KOD ortamdan zaten silindi.
function Start-PanelKur([string]$kur, [bool]$sessiz) {
  if ($sessiz) { & cmd.exe /c $kur sessiz } else { & cmd.exe /c $kur }
}

# Tek HTTP istegi, yonlendirme TAKIP EDILMEZ (-MaximumRedirection 0). Durum, Location ve (OutFile yoksa) govde doner; aga ulasilamazsa throw.
function Get-PanelHttp([string]$url, [string]$token, [string]$accept, [string]$outFile) {
  $headers = @{ Accept = $accept; 'User-Agent' = 'panel-kur' }
  if ($token) { $headers['Authorization'] = "Bearer $token"; $headers['X-GitHub-Api-Version'] = '2022-11-28' }
  $args2 = @{ Uri = $url; Headers = $headers; MaximumRedirection = 0; UseBasicParsing = $true; TimeoutSec = 900 }
  if ($outFile) { $args2['OutFile'] = $outFile }
  try {
    $resp = Invoke-WebRequest @args2
    return [pscustomobject]@{ Status = [int]$resp.StatusCode; Location = $null; Content = $(if ($outFile) { $null } else { [string]$resp.Content }) }
  } catch {
    $e = $_.Exception
    if ($e.Response) {
      # 3xx / 4xx: 5.1'de WebException (WebHeaderCollection), PowerShell 7'de HttpResponseException; ikisinde de GetValues var.
      $loc = $null
      try { $loc = [string](@($e.Response.Headers.GetValues('Location'))[0]) } catch { $loc = $null }
      return [pscustomobject]@{ Status = [int]$e.Response.StatusCode; Location = $loc; Content = $null }
    }
    throw "GitHub'a ulasilamadi. Internet baglantini kontrol edip tekrar dene."
  }
}

function Stop-PanelHttp([int]$status) {
  if ($status -eq 401) { throw 'Kurulum kodu kabul edilmedi (yanlis ya da suresi dolmus olabilir). Kuran ekipten yenisini iste.' }
  if ($status -eq 403) { throw 'GitHub istegi reddetti (kodun yetkisi yetmiyor ya da istek sinirina takildin). Biraz sonra tekrar dene; surerse kuran ekibe haber ver.' }
  if ($status -eq 404) { throw 'Paket deposu bulunamadi, kodun erisimi yok ya da henuz yayimlanmis bir surum yok. Kodu kuran ekiple kontrol et.' }
  throw "GitHub beklenmedik bir yanit verdi ($status). Biraz sonra tekrar dene."
}

# Varlik indirme: once api.github.com (anahtarli), yonlendirmede YALNIZ *.githubusercontent.com'a ve anahtarsiz (en cok 3 yonlendirme).
function Get-PanelAsset([string]$apiHost, [string]$depo, [string]$id, [string]$token, [string]$outFile) {
  if ($id -notmatch '^[0-9]+$') { throw 'Surum bilgisi okunamadi.' }
  $url = "https://$apiHost/repos/$depo/releases/assets/$id"
  $auth = $token
  for ($hop = 0; $hop -le 3; $hop++) {
    $r = Get-PanelHttp $url $auth 'application/octet-stream' $outFile
    if ($r.Status -eq 200) { return }
    if (@(301, 302, 303, 307, 308) -contains $r.Status) {
      if (-not $r.Location -or $r.Location -notmatch '^https://([A-Za-z0-9-]+\.)+githubusercontent\.com(/|\?|$)') { throw 'Dosya izinli olmayan bir adrese yonlendirildi; indirilmedi.' }
      $url = $r.Location
      $auth = $null
      continue
    }
    Stop-PanelHttp $r.Status
  }
  throw 'Dosya adresi cok kez yonlendirildi; indirilmedi.'
}

Invoke-PanelKur
