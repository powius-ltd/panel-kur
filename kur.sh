#!/usr/bin/env bash
# Panel tek satirla kurulum (macOS + Linux). Herkese acik depodan alinir; sir tasimaz: musteriye ozel olan yalniz PANEL_KOD ortam degiskenidir.
#
#   curl -fsSL <adres>/kur.sh | PANEL_KOD=<kod> bash        (Mac)
#   wget -qO- <adres>/kur.sh | PANEL_KOD=<kod> bash         (Ubuntu)
#
# Kod: <kN>-<salt okunur GitHub anahtari>. Anahtar yalniz api.github.com'a gider; yonlendirme elle izlenir ve ikinci istek anahtarsizdir
# (src/lib/setup/update/github.ts ile ayni kural). Anahtar hicbir ciktiya, gunluge, komut satirina ya da adrese yazilmaz.
# Akis: kodu coz -> son surumu oku -> zip + SHA256SUMS indir -> ozeti dogrula -> yalniz paketin kendi dosyalarini ~/panel'e koy -> Kur.
# PANEL_KUR_KURU=1: yalniz plani yazar; hicbir sey indirmez / yazmaz. PANEL_KUR_DEPO=owner/ad: yalniz test icin depo adi.
# PANEL_KUR_YENIDEN=1: ~/panel varsa (.env.local olsun olmasin) onarim yerine YENI paket kurulur; dogrulamadan sonra eski klasor ~/panel-eski-<tarih>'e
# tasinir (ASLA silinmez), eski .env.local (varsa) yeni kuruluma kopyalanir; klasor yoksa bayrak etkisiz.
# Govde fonksiyonlarda, son satir main: yarim inen betik calismaz. macOS bash 3.2 uyumlu (ilişkisel dizi ve mapfile yok).

DEPO_SAHIBI="powius-ltd"
API_HOST="api.github.com"
TMP=""
TOKEN=""
HAVE=""
HTTP_STATUS=0
HTTP_LOCATION=""

say() { printf '%s\n' "$*"; }
dur() { printf '\n%s\n' "$*" >&2; exit 1; }

temizle() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; TMP=""; }

http_hata() {
  case "$1" in
    401) dur 'Kurulum kodu kabul edilmedi (yanlış ya da süresi dolmuş olabilir). Kuran ekipten yenisini iste.' ;;
    403) dur 'GitHub isteği reddetti (kodun yetkisi yetmiyor ya da istek sınırına takıldın). Biraz sonra tekrar dene; sürerse kuran ekibe haber ver.' ;;
    404) dur 'Paket deposu bulunamadı, kodun erişimi yok ya da henüz yayımlanmış bir sürüm yok. Kodu kuran ekiple kontrol et.' ;;
    *)   dur "GitHub beklenmedik bir yanıt verdi ($1). Biraz sonra tekrar dene." ;;
  esac
}

# http_get <adres> <cikti> <anahtarli 1|0> <accept>: yonlendirme TAKIP EDILMEZ. HTTP_STATUS / HTTP_LOCATION doldurur; aga ulasilamazsa 1 doner.
# Anahtar komut satirina girmez (ps'te gorunmez): yalniz yalnizca-sahibi-okur gecici yapilandirma dosyasindan okunur.
http_get() {
  local url=$1 out=$2 auth=$3 accept=$4 hdr="$TMP/yanit.baslik" conf="$TMP/yetki.conf"
  : > "$hdr"; HTTP_STATUS=0; HTTP_LOCATION=""
  if [ "$HAVE" = curl ]; then
    local args=(-sS --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 1200 --max-filesize 419430400 -o "$out" -D "$hdr" -H "Accept: $accept" -A panel-kur)
    if [ "$auth" = 1 ]; then
      printf 'header = "Authorization: Bearer %s"\nheader = "X-GitHub-Api-Version: 2022-11-28"\n' "$TOKEN" > "$conf"
      args+=(-K "$conf")
    fi
    curl "${args[@]}" "$url" >/dev/null 2>&1 || true
  else
    local args=(-nv -S --https-only --secure-protocol=TLSv1_2 --max-redirect=0 --tries=3 --timeout=30 -U panel-kur -O "$out" "--header=Accept: $accept")
    if [ "$auth" = 1 ]; then
      printf 'header = Authorization: Bearer %s\nheader = X-GitHub-Api-Version: 2022-11-28\n' "$TOKEN" > "$conf"
      args+=("--config=$conf")
    fi
    wget "${args[@]}" "$url" >/dev/null 2>"$hdr" || true
  fi
  HTTP_STATUS=$(awk '/^ *HTTP\//{ s = $2 } END { print s + 0 }' "$hdr")
  HTTP_LOCATION=$(awk 'tolower($1) == "location:" { print $2 }' "$hdr" | tail -n 1 | tr -d '\r')
  rm -f "$conf"
  [ "$HTTP_STATUS" -gt 0 ]
}

# Yonlendirme yalniz GitHub'in varlik alan adlarina (*.githubusercontent.com, https, kullanici bilgisi / port yok) izinlidir.
izinli_indirme() {
  local re='^https://([A-Za-z0-9-]+\.)+githubusercontent\.com(/|\?|$)'
  [[ $1 =~ $re ]]
}

# indir_varlik <id> <cikti>: once api.github.com (anahtarli), yonlendirmede anahtarsiz.
indir_varlik() {
  local id=$1 out=$2 url auth=1 hop=0
  url="https://$API_HOST/repos/$DEPO/releases/assets/$id"
  while [ "$hop" -le 3 ]; do
    http_get "$url" "$out" "$auth" 'application/octet-stream' || dur 'GitHub'"'"'a ulaşılamadı. İnternet bağlantını kontrol edip tekrar dene.'
    case "$HTTP_STATUS" in
      200) return 0 ;;
      301|302|303|307|308)
        izinli_indirme "$HTTP_LOCATION" || dur 'Dosya izinli olmayan bir adrese yönlendirildi; indirilmedi.'
        url=$HTTP_LOCATION; auth=0; hop=$((hop + 1)) ;;
      *) http_hata "$HTTP_STATUS" ;;
    esac
  done
  dur 'Dosya adresi çok kez yönlendirildi; indirilmedi.'
}

sha256_of() {
  if [ "$OS" = mac ]; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi | tr 'A-F' 'a-f'
}

# Linux'ta unzip varsayilan degil: python3 (yalitilmis). Yol disina cikan / baglanti iceren uye reddedilir; izinler zip'ten.
linux_ac() {
  python3 -I - "$1" "$2" <<'PY'
import os, stat, sys, zipfile
zip_path, dest = sys.argv[1], os.path.realpath(sys.argv[2])
total = 0
with zipfile.ZipFile(zip_path) as z:
    for info in z.infolist():
        target = os.path.realpath(os.path.join(dest, info.filename))
        if not (target == dest or target.startswith(dest + os.sep)):
            sys.exit(3)
        mode = info.external_attr >> 16
        if stat.S_ISLNK(mode):
            sys.exit(3)
        total += info.file_size
        if total > 2 * 1024 ** 3:
            sys.exit(3)
        if info.is_dir():
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with z.open(info) as src, open(target, "wb") as out:
            out.write(src.read())
        os.chmod(target, (mode & 0o777) if (mode & 0o777) else 0o644)
PY
}

paket_ac() {
  if [ "$OS" = mac ]; then ditto -x -k "$1" "$2"; else linux_ac "$1" "$2"; fi
}

# Zip kokunu bulur ("panel/" ya da dogrudan kok): icinde Kur ve <sistem>/paket-kok.txt olmali.
paket_kok_bul() {
  local d
  for d in "$1/panel" "$1"; do
    if [ -f "$d/$OSDIR/paket-kok.txt" ] && [ -f "$d/$KUR" ]; then printf '%s' "$d"; return 0; fi
  done
  return 1
}

# YALNIZ paketin kendi dosyalari (<sistem>/paket-kok.txt + panel-recete.json + kanal.env) hedefe kopyalanir.
paket_kopyala() {
  local kok=$1 name
  mkdir -p "$HEDEF" || dur "$HEDEF oluşturulamadı."
  while IFS= read -r name || [ -n "$name" ]; do
    name=$(printf '%s' "$name" | tr -d '\r')
    case "$name" in ''|*/*|*:*|.|..) continue ;; esac
    if [ -e "$kok/$name" ]; then cp -Rp "$kok/$name" "$HEDEF/" || dur "Dosyalar $HEDEF klasörüne kopyalanamadı ($name)."; fi
  done < <(cat "$kok/$OSDIR/paket-kok.txt"; printf '\npanel-recete.json\nkanal.env\n')
}

# Eski kurulumun yeni adi: ~/panel-eski-<YYYYAAGG-SSDD>; doluysa sonuna -2, -3 ...
eski_adi() {
  local base="$HOME/panel-eski-$(date +%Y%m%d-%H%M)" ad n=2
  ad=$base
  while [ -e "$ad" ]; do ad="$base-$n"; n=$((n + 1)); done
  printf '%s' "$ad"
}

kur_calistir() {
  unset PANEL_KOD TOKEN
  if [ "$TTY_VAR" = 1 ]; then
    exec /bin/bash "$HEDEF/$KUR" ${PANEL_KUR_SESSIZ:+sessiz} </dev/tty
  fi
  exec /bin/bash "$HEDEF/$KUR" sessiz </dev/null
}

main() {
  set +x
  umask 077
  [ "$(id -u)" != 0 ] || dur 'Bu komutu sudo ya da yönetici olarak çalıştırma. Aynı komutu sudo olmadan yeniden çalıştır.'

  case "$(uname -s)" in
    Darwin) OS=mac; OSDIR=mac; KUR=Kur.command ;;
    Linux)  OS=linux; OSDIR=linux; KUR=Kur.sh ;;
    *) dur 'Bu kurulum yalnız macOS ve Linux içindir (Windows için kur.ps1).' ;;
  esac

  # Kod: ortamdan; komut satirina girmez. Hata iletisi kodu ASLA tekrarlamaz.
  local kod=${PANEL_KOD:-} re='^(k[0-9]{1,2})-(github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{30,})$' kn=""
  [ -n "$kod" ] || dur 'Kurulum kodu yok. Komutu, kuran ekibin verdiği kodla (PANEL_KOD=...) birlikte olduğu gibi yapıştır.'
  if [[ $kod =~ $re ]]; then kn=${BASH_REMATCH[1]}; TOKEN=${BASH_REMATCH[2]}; else dur 'Kurulum kodu geçerli görünmüyor (k1-... biçiminde olmalı). Kodu eksiksiz, olduğu gibi yapıştır; olmazsa kuran ekipten yenisini iste.'; fi
  unset PANEL_KOD

  DEPO="$DEPO_SAHIBI/panel-$kn-surum"
  if [ -n "${PANEL_KUR_DEPO:-}" ]; then
    [[ $PANEL_KUR_DEPO =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]] && [[ $PANEL_KUR_DEPO != *..* ]] || dur 'PANEL_KUR_DEPO owner/ad biçiminde olmalı.'
    DEPO=$PANEL_KUR_DEPO
  fi

  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || dur 'Ana klasör bulunamadı.'
  HEDEF="$HOME/panel"
  printf '%s' "$HEDEF" | grep -Eq '^/[A-Za-z0-9_./-]+$' || dur "Ana klasörünün yolu ($HOME) özel karakter içeriyor (boşluk, Türkçe harf); panel bu yola kurulamaz. Bilgisayarı yöneten kişiye danış."

  TTY_VAR=0
  if ( : </dev/tty ) 2>/dev/null && [ -z "${PANEL_KUR_SESSIZ:-}" ]; then TTY_VAR=1; fi

  # PANEL_KUR_YENIDEN=1 ve $HEDEF klasoru var (.env.local olsun olmasin): onarim dalina girilmez, yeni paket indirilip eskinin yerine kurulur (eski yedeklenir).
  local yeniden=0
  if [ "${PANEL_KUR_YENIDEN:-}" = 1 ] && [ -d "$HEDEF" ]; then yeniden=1; fi

  # Kurulu panel ezilmez: .env.local varsa paket inmez, mevcut Kur calisir (onarim).
  if [ -f "$HEDEF/.env.local" ] && [ "$yeniden" != 1 ]; then
    if [ "${PANEL_KUR_KURU:-}" = 1 ]; then
      say "KURU KOŞU: panel zaten kurulu ($HEDEF). Paket indirilmez; mevcut Kur çalıştırılır (onarım)."
      say 'Hiçbir şey indirilmedi, hiçbir dosya yazılmadı.'
      return 0
    fi
    say "Panel zaten kurulu ($HEDEF); paket indirilmiyor. Kurulum denetlenip gerekirse onarılıyor."
    [ -f "$HEDEF/$KUR" ] || dur "$HEDEF içinde $KUR yok. Kurulum bozuk görünüyor; kuran ekibe haber ver."
    kur_calistir
  fi

  if [ "${PANEL_KUR_KURU:-}" = 1 ]; then
    say 'KURU KOŞU: hiçbir şey indirilmedi, hiçbir dosya yazılmadı. Yapılacaklar:'
    say "  1. Kod çözüldü (kanal: $kn). Paket deposu: $DEPO"
    say "  2. Son sürüm okunur, panel-*.zip + SHA256SUMS indirilir (anahtar yalnız $API_HOST'a gider)."
    say '  3. Özet (SHA-256) doğrulanır; uyuşmazsa hiçbir şey kurulmaz.'
    if [ "$yeniden" = 1 ]; then say "  3b. Eski kurulum ($HEDEF) $HOME/panel-eski-<tarih> klasörüne taşınır (silinmez); eski .env.local yeni kuruluma kopyalanır."; fi
    say "  4. Yalnız paketin kendi dosyaları $HEDEF klasörüne konur."
    say "  5. $KUR çalıştırılır$([ "$TTY_VAR" = 1 ] || printf ' (etkileşimsiz: sessiz)')."
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then HAVE=curl
  elif command -v wget >/dev/null 2>&1; then HAVE=wget
  else dur 'curl ya da wget bulunamadı. Bilgisayarı yöneten kişiden birini kurmasını iste.'; fi
  # Kur'un kendisi (linux/kur.sh, Claude yukleyicisi) curl ister: betik wget ile inse de curl'suz Ubuntu'da Kur yarida kalir; bastan soyle.
  if [ "$OS" = linux ]; then command -v curl >/dev/null 2>&1 || dur 'Bu bilgisayarda curl yok. Terminal'"'"'e sudo apt install -y curl yaz, şifreni gir, sonra kurulum komutunu yeniden yapıştır.'; fi
  if [ "$OS" = linux ]; then command -v python3 >/dev/null 2>&1 || dur 'python3 bulunamadı (paketi açmak için gerekli). Bilgisayarı yöneten kişiden kurmasını iste.'; fi

  TMP=$(mktemp -d "${TMPDIR:-/tmp}/panel-kur.XXXXXX") || dur 'Geçici klasör açılamadı.'
  trap 'temizle' EXIT
  trap 'temizle; exit 1' INT TERM HUP

  say 'Son sürüm okunuyor...'
  http_get "https://$API_HOST/repos/$DEPO/releases/latest" "$TMP/surum.json" 1 'application/vnd.github+json' || dur 'GitHub'"'"'a ulaşılamadı. İnternet bağlantını kontrol edip tekrar dene.'
  [ "$HTTP_STATUS" = 200 ] || http_hata "$HTTP_STATUS"

  # Varlik kimlikleri: her varligin adresi ".../releases/assets/<id>" ile baslar; ondan sonraki ilk "name" varligin adidir (JSON ayristirici gerekmez).
  local liste zipid zipad sumid
  liste=$(tr -d '\r\n' < "$TMP/surum.json" | sed 's#"url": *"https://api\.github\.com/repos/[^"]*/releases/assets/#\
@@#g' | sed -n 's/^@@\([0-9][0-9]*\)"[^}]*"name": *"\([^"]*\)".*/\1 \2/p')
  zipid=$(printf '%s\n' "$liste" | awk '$2 ~ /^panel-[A-Za-z0-9._-]+\.zip$/ { print $1 }')
  zipad=$(printf '%s\n' "$liste" | awk '$2 ~ /^panel-[A-Za-z0-9._-]+\.zip$/ { print $2 }')
  sumid=$(printf '%s\n' "$liste" | awk '$2 == "SHA256SUMS" { print $1 }')
  [ "$(printf '%s\n' "$zipid" | grep -c .)" = 1 ] || dur 'Sürümde tek bir panel zip dosyası bulunamadı. Kuran ekibe haber ver.'
  [ "$(printf '%s\n' "$sumid" | grep -c .)" = 1 ] || dur 'Sürümde SHA256SUMS yok: dosya doğrulanamayacağı için kurulmaz. Kuran ekibe haber ver.'

  say "İndiriliyor: $zipad"
  indir_varlik "$sumid" "$TMP/SHA256SUMS"
  indir_varlik "$zipid" "$TMP/$zipad"

  local beklenen gercek
  beklenen=$(awk -v f="$zipad" '{ n = $2; sub(/^\*/, "", n); sub(/^\.\//, "", n); if (length($1) == 64 && n == f) { print $1; exit } }' "$TMP/SHA256SUMS" | tr 'A-F' 'a-f')
  [ -n "$beklenen" ] || dur 'SHA256SUMS içinde bu paketin özeti yok; kurulmadı.'
  gercek=$(sha256_of "$TMP/$zipad")
  if [ "$gercek" != "$beklenen" ]; then
    dur 'İndirilen dosya doğrulanamadı (özet tutmuyor); hiçbir şey kurulmadı. İnternet bağlantını kontrol edip tekrar dene; sürerse kuran ekibe haber ver.'
  fi
  say 'Dosya doğrulandı.'

  mkdir -p "$TMP/ac" || dur 'Geçici klasör açılamadı.'
  paket_ac "$TMP/$zipad" "$TMP/ac" || dur 'Paket açılamadı.'
  local kok
  kok=$(paket_kok_bul "$TMP/ac") || dur 'Paket beklenen biçimde değil; kurulmadı. Kuran ekibe haber ver.'
  local eski=""
  if [ "$yeniden" = 1 ]; then
    eski=$(eski_adi)
    mv "$HEDEF" "$eski" || dur "Eski kurulum taşınamadı; hiçbir şey değişmedi. Eski kurulum $HEDEF klasöründe duruyor."
  fi
  paket_kopyala "$kok"
  if [ -n "$eski" ] && [ -f "$eski/.env.local" ]; then
    cp -p "$eski/.env.local" "$HEDEF/.env.local" || dur "Anahtarlar yeni kuruluma kopyalanamadı. Eski kurulum $eski klasöründe duruyor (silme); kuran ekibe haber ver."
    say "Eski kurulum $eski klasörüne alındı; anahtarların yeni kuruluma taşındı."
  fi
  temizle
  trap - EXIT INT TERM HUP
  say "Panel dosyaları $HEDEF klasörüne konuldu. Kurulum başlıyor..."
  kur_calistir
}

main "$@"
