# ============================================================
#  사진 이름을 "촬영 주소 (번호) 위도, 경도" 로 바꾸는 프로그램
#  - 사진 속 GPS 좌표 -> 카카오 지도 지번주소 -> 파일 이름
#  - 실행은 photo_rename.bat 을 더블클릭하세요
#  - 메뉴: 1 이름 바꾸기 / 2 되돌리기 / 3 지도(카카오 지도) / 4 폴더 정리
#  - 1·4번은 현재 폴더 + 하위 폴더 1단계를 함께 처리 (사진은 자기 폴더에 그대로). 캐시·로그가 없어도 동작
# ============================================================
param([string]$FolderArg = '')

$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
[Threading.Thread]::CurrentThread.CurrentCulture = $inv
Add-Type -AssemblyName System.Drawing

# ---- 바꾸고 싶을 때만 수정하세요 ----
$NewestFirst = $false      # $false = 가장 오래된 사진이 (1)   /   $true = 가장 최근 사진이 (1)
# 카카오 키를 여기에 직접 적어 두면 따로 묻거나 txt로 저장하지 않습니다. (따옴표 안에 키만 붙여넣기)
# 비워 두면 처음 실행할 때 물어보고 kakao_api_key.txt / kakao_js_key.txt 에 저장합니다.
# 주의: 키가 적힌 이 파일을 남에게 보내거나 인터넷에 올리면 키가 같이 노출됩니다.
$KakaoRestKey = 'b86ae5671277276728a3b40a1daf6b25'        # REST API 키 (주소 조회용)
$KakaoJsKey   = '3cee8237a39ce9a6fd5e6679220f48ba'        # JavaScript 키 (지도용)
# -------------------------------------

$utf8    = New-Object System.Text.UTF8Encoding($false)
$utf8bom = New-Object System.Text.UTF8Encoding($true)
$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$keyFile   = Join-Path $here 'kakao_api_key.txt'
$cacheFile = Join-Path $here 'address_cache.txt'
$script:apiKey = ''
$script:cache  = @{}
$script:lastFail = ''
$script:withCoord = $true   # 파일 이름에 좌표를 넣을지 (메뉴에서 고름)

# 이미 "주소 (번호)" 또는 "주소 (번호) 위도, 경도" 형식으로 바뀐 파일 이름
# (예전 버그로 이름 맨 앞에 붙은 '닫기 ' 는 있어도 주소로 인식하지 않고 떼어 냄)
$namePattern = '^(?:닫기\s+)?(?<addr>[가-힣].*\d) \((?<n>\d+)\)(?: -?\d+\.\d+, -?\d+\.\d+)?$'

# ---------------- 공통 ----------------
function Read-Choice([string]$prompt, $valid) {
    while ($true) {
        $v = (Read-Host $prompt).Trim()
        if ($valid -contains $v) { return $v }
        Write-Host '  목록에 있는 번호를 입력하세요.' -ForegroundColor Yellow
    }
}

# 파일 이름에 좌표를 넣을지 묻기 (1=넣기 True, 2=빼기 False)
function Read-CoordChoice([string]$note = '') {
    Write-Host ''
    Write-Host "파일 이름에 좌표를 넣을까요?$note"
    Write-Host '  1  넣기   예) ○○리 123-4 (1) 37.123456, 127.123456.jpg'
    Write-Host '  2  빼기   예) ○○리 123-4 (1).jpg'
    return ((Read-Choice '번호' @('1', '2')) -eq '1')
}

function Read-Folder([string]$arg) {
    $def = if ($arg) { $arg.Trim().Trim('"') } else { $here }
    while ($true) {
        Write-Host ''
        Write-Host "사진 폴더: $def" -ForegroundColor Cyan
        $in = (Read-Host '  맞으면 Enter / 다른 폴더면 경로 붙여넣기').Trim().Trim('"')
        if (-not $in) { $in = $def }
        if (Test-Path -LiteralPath $in -PathType Container) { return (Resolve-Path -LiteralPath $in).ProviderPath }
        Write-Host '  폴더를 찾을 수 없습니다. 다시 입력하세요.' -ForegroundColor Yellow
    }
}

# ---------------- API 키 ----------------
function Clean-Key([string]$k) {
    $k = $k.Trim().Trim('"').Trim("'").Trim()
    $k = $k -replace '^(?i)KakaoAK\s+', ''
    return $k.Trim()
}

function Load-Key {
    if ($KakaoRestKey) { $k0 = Clean-Key $KakaoRestKey; if ($k0) { return $k0 } }
    if (Test-Path -LiteralPath $keyFile) { return (Clean-Key ([IO.File]::ReadAllText($keyFile))) }
    # 이전 버전(설정.txt / kakao_key.txt)에 저장된 키가 있으면 가져옴
    $old = Join-Path $here '설정.txt'
    if (Test-Path -LiteralPath $old) {
        foreach ($line in [IO.File]::ReadAllLines($old, $utf8)) {
            if ($line -match '^\s*API키\s*=\s*(.+)$') { $k = Clean-Key $matches[1]; if ($k) { return $k } }
        }
    }
    $older = Join-Path $here 'kakao_key.txt'
    if (Test-Path -LiteralPath $older) { return (Clean-Key ([IO.File]::ReadAllText($older))) }
    return ''
}

function Get-StatusCode($err) {
    try { return [int]$err.Exception.Response.StatusCode } catch { return 0 }
}

function Get-ErrorBody($err) {
    try { if ($err.ErrorDetails -and $err.ErrorDetails.Message) { return [string]$err.ErrorDetails.Message } } catch { }
    try {
        $resp = $err.Exception.Response
        if ($resp) {
            $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $t = $sr.ReadToEnd(); $sr.Dispose()
            return $t
        }
    } catch { }
    return ''
}

function Get-ApiHint([int]$code, [string]$body) {
    if ($body -match 'ip mismatched') {
        return "이 PC의 IP가 키의 [호출 허용 IP 주소]에 등록되어 있지 않습니다.`n  -> 카카오 개발자 사이트 > REST API 키 > [호출 허용 IP 주소]를 비우거나 이 PC의 IP를 추가하세요."
    }
    if ($body -match 'limit has been exceeded' -or $body -match '"code"\s*:\s*-10') {
        return '카카오 무료 사용량을 모두 썼습니다. 이미 조회한 주소는 저장되어 있어 나중에 이어서 할 수 있습니다.'
    }
    if ($code -eq 429) { return '요청이 너무 많습니다(429). 잠시 후 다시 실행하세요. 이미 조회한 주소는 저장되어 있습니다.' }
    if ($code -eq 401 -or $code -eq 403) {
        return "인증 실패입니다. 확인하세요.`n  1) REST API 키여야 합니다 (JavaScript 키, 네이티브 앱 키는 안 됨)`n  2) 카카오 개발자 사이트 [카카오맵] > [사용 설정] 이 ON 인지`n  3) 키를 복사할 때 앞뒤에 다른 글자가 섞이지 않았는지"
    }
    if ($code -eq 0) { return '카카오 서버에 연결하지 못했습니다. 인터넷 연결/방화벽을 확인하세요.' }
    return '알 수 없는 오류입니다.'
}

# 결과: 'ok' / 'key'(키를 다시 입력하면 해결될 수 있음) / 'other'
function Test-ApiKey {
    $url = 'https://dapi.kakao.com/v2/local/geo/coord2address.json?x=126.9779692&y=37.566535&input_coord=WGS84'
    try {
        [void](Invoke-RestMethod -Uri $url -Method Get -Headers @{ Authorization = "KakaoAK $($script:apiKey)" })
        return 'ok'
    } catch {
        $code = Get-StatusCode $_
        $body = Get-ErrorBody $_
        Write-Host ''
        Write-Host "  카카오 응답: HTTP $code" -ForegroundColor Red
        if ($body) { Write-Host "  서버 메시지: $body" -ForegroundColor Red }
        Write-Host ('  ' + (Get-ApiHint $code $body)) -ForegroundColor Yellow
        if (($code -eq 401 -or $code -eq 403) -and ($body -notmatch 'ip mismatched')) { return 'key' }
        return 'other'
    }
}

function Ensure-ApiKey {
    $script:apiKey = Load-Key
    while ($true) {
        if (-not $script:apiKey) {
            Write-Host ''
            Write-Host '카카오 REST API 키가 필요합니다. (한 번만 입력하면 저장됩니다)' -ForegroundColor Yellow
            Write-Host '  developers.kakao.com > 내 앱 > [앱 키] > REST API 키 복사  /  [카카오맵] 사용 설정 ON'
            $in = Clean-Key (Read-Host '  키 붙여넣기 (그만하려면 Enter)')
            if (-not $in) { Write-Host 'API 키가 없어 종료합니다.' -ForegroundColor Red; return $false }
            $script:apiKey = $in
        }
        Write-Host 'API 키 확인 중...' -NoNewline
        $r = Test-ApiKey
        if ($r -eq 'ok') {
            Write-Host ' 정상' -ForegroundColor Green
            if (-not $KakaoRestKey) { [IO.File]::WriteAllText($keyFile, $script:apiKey, $utf8) }
            return $true
        }
        if ($r -eq 'key') { $script:apiKey = ''; continue }
        return $false
    }
}

function Get-Address([double]$lat, [double]$lon) {
    $key = ('{0:F6},{1:F6}' -f $lat, $lon)
    if ($script:cache.ContainsKey($key)) { return $script:cache[$key] }

    $url = "https://dapi.kakao.com/v2/local/geo/coord2address.json?x=$lon&y=$lat&input_coord=WGS84"
    for ($t = 1; $t -le 4; $t++) {
        try {
            $res = Invoke-RestMethod -Uri $url -Method Get -Headers @{ Authorization = "KakaoAK $($script:apiKey)" }
            $addr = $null
            if ($res.documents -and $res.documents.Count -gt 0) {
                $d = $res.documents[0]
                if ($d.address -and $d.address.address_name) { $addr = $d.address.address_name }
                elseif ($d.road_address -and $d.road_address.address_name) { $addr = $d.road_address.address_name }
            }
            if ($addr) {
                $addr = ($addr -replace '[\\/:*?"<>|]', '-') -replace '\s+', ' '
                $addr = $addr.Trim()
                $script:cache[$key] = $addr
                [IO.File]::AppendAllText($cacheFile, "$key`t$addr`r`n", $utf8)
                Start-Sleep -Milliseconds 60
            } else { $script:lastFail = '카카오가 이 좌표의 주소를 돌려주지 않음 (도로·하천·필지 밖 등)' }
            return $addr
        } catch {
            $code = Get-StatusCode $_
            $body = Get-ErrorBody $_
            if ($code -eq 401 -or $code -eq 403 -or $code -eq 429 -or ($body -match 'limit has been exceeded')) {
                throw (Get-ApiHint $code $body)
            }
            if ($code -eq 400) { $script:lastFail = "HTTP 400 $body"; return $null }
            $script:lastFail = "통신 오류 HTTP $code"
            Start-Sleep -Seconds (2 * $t)
        }
    }
    return $null
}

# 사진 모으기: 선택한 폴더 + 그 바로 아래 하위 폴더(1단계)의 JPG
function Get-Photos([string]$root) {
    $list = New-Object System.Collections.Generic.List[object]
    $dirs = @(Get-Item -LiteralPath $root) + @(Get-ChildItem -LiteralPath $root -Directory)
    foreach ($d in $dirs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File)) {
            if ($f.Extension -match '^\.jpe?g$' -and $f.Name -notlike '__tmp_*') { $list.Add($f) }
        }
    }
    return $list.ToArray()
}

# ---------------- 사진 정보 (GPS 확인 + 촬영시각) ----------------
function Get-Rationals([byte[]]$bytes) {
    $out = @()
    for ($i = 0; ($i + 7) -lt $bytes.Length; $i += 8) {
        $n = [BitConverter]::ToUInt32($bytes, $i)
        $d = [BitConverter]::ToUInt32($bytes, $i + 4)
        if ($d -eq 0) { $out += 0.0 } else { $out += ([double]$n / [double]$d) }
    }
    return ,$out
}

# Status: GPS있음 / GPS없음 / EXIF없음 / 읽기실패
function Get-PhotoInfo($file) {
    $info = [pscustomobject]@{ Status = '읽기실패'; Lat = $null; Lon = $null; Taken = $null }
    $fs = $null; $img = $null
    try {
        $fs  = [IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
        $img = [System.Drawing.Image]::FromStream($fs, $false, $false)
        $ids = $img.PropertyIdList
        if ($ids.Count -eq 0) { $info.Status = 'EXIF없음' }
        else {
            $info.Status = 'GPS없음'
            if (($ids -contains 2) -and ($ids -contains 4)) {
                $la = Get-Rationals ($img.GetPropertyItem(2).Value)
                $lo = Get-Rationals ($img.GetPropertyItem(4).Value)
                if ($la.Count -ge 3 -and $lo.Count -ge 3) {
                    $lat = $la[0] + $la[1] / 60 + $la[2] / 3600
                    $lon = $lo[0] + $lo[1] / 60 + $lo[2] / 3600
                    if ($ids -contains 1) { if ([char]($img.GetPropertyItem(1).Value[0]) -eq 'S') { $lat = -$lat } }
                    if ($ids -contains 3) { if ([char]($img.GetPropertyItem(3).Value[0]) -eq 'W') { $lon = -$lon } }
                    if (-not ($lat -eq 0 -and $lon -eq 0)) { $info.Lat = $lat; $info.Lon = $lon; $info.Status = 'GPS있음' }
                }
            }
            if ($ids -contains 36867) {
                $s = [Text.Encoding]::ASCII.GetString($img.GetPropertyItem(36867).Value).Trim([char]0).Trim()
                try {
                    $dt = [datetime]::ParseExact($s, 'yyyy:MM:dd HH:mm:ss', $inv)
                    if ($ids -contains 37521) {
                        $ss = [Text.Encoding]::ASCII.GetString($img.GetPropertyItem(37521).Value).Trim([char]0).Trim()
                        if ($ss -match '^\d+$') { $dt = $dt.AddMilliseconds([double]('0.' + $ss) * 1000) }
                    }
                    $info.Taken = $dt
                } catch { }
            }
        }
    } catch { $info.Status = '읽기실패' }
    finally {
        if ($img) { $img.Dispose() }
        if ($fs)  { $fs.Dispose() }
    }

    if (-not $info.Taken) {
        if ($file.BaseName -match '(\d{8})_(\d{6})') {
            try { $info.Taken = [datetime]::ParseExact($matches[1] + $matches[2], 'yyyyMMddHHmmss', $inv) } catch { }
        }
        if (-not $info.Taken) { $info.Taken = $file.LastWriteTime }
    }
    return $info
}

# ---------------- 안전한 이름 변경 (임시 이름을 거쳐 충돌 방지) ----------------
function Invoke-Moves($pairs) {
    $tmps = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($p in $pairs) {
        $i++
        if ($i % 50 -eq 0 -or $i -eq $pairs.Count) { Write-Progress -Activity '이름 변경 중 (1/2)' -Status "$i / $($pairs.Count)" -PercentComplete ([int](100 * $i / $pairs.Count)) }
        $dir = Split-Path -Parent $p.To
        $tmp = Join-Path $dir ('__tmp_' + [guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension($p.To))
        try {
            [IO.File]::Move($p.From, $tmp)
            $tmps.Add([pscustomobject]@{ Tmp = $tmp; To = $p.To; From = $p.From })
        } catch {
            Write-Host "  실패: $($p.From) : $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    $i = 0; $ok = 0
    foreach ($x in $tmps) {
        $i++
        if ($i % 50 -eq 0 -or $i -eq $tmps.Count) { Write-Progress -Activity '이름 변경 중 (2/2)' -Status "$i / $($tmps.Count)" -PercentComplete ([int](100 * $i / $tmps.Count)) }
        try {
            [IO.File]::Move($x.Tmp, $x.To); $ok++
        } catch {
            Write-Host "  실패(원래 이름으로 복구 시도): $($x.To) : $($_.Exception.Message)" -ForegroundColor Red
            try { [IO.File]::Move($x.Tmp, $x.From) } catch { Write-Host "  복구 실패! 임시이름 파일: $($x.Tmp)" -ForegroundColor Red }
        }
    }
    Write-Progress -Activity '이름 변경' -Completed
    return $ok
}

$mapTemplate = @'
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>사진 위치 지도 (카카오맵)</title>
<style>
  html, body, #map { height: 100%; margin: 0; }
  body { font-family: 'Malgun Gothic', 'Apple SD Gothic Neo', sans-serif; }
  .box { position: absolute; z-index: 1000; background: rgba(255,255,255,.95); border-radius: 6px; box-shadow: 0 1px 5px rgba(0,0,0,.4); font-size: 12px; line-height: 1.6; padding: 6px 8px; }
  #nm { left: 10px; top: 10px; max-width: 220px; }
  #lay { right: 10px; top: 10px; }
  #info { left: 10px; bottom: 24px; max-width: 40vw; font-size: 13px; line-height: 1.5; padding: 8px 12px; word-break: break-all; }
  #detail { user-select: text; -webkit-user-select: text; cursor: auto; right: 10px; top: 120px; width: 300px; max-height: calc(100% - 260px); overflow: auto; display: none; font-size: 13px; padding: 8px 10px; }
  #err { left: 50%; top: 30%; transform: translateX(-50%); width: 420px; max-width: 90vw; display: none; font-size: 14px; padding: 12px 16px; }
  #err code { background: #eee; padding: 1px 4px; }
  .pop b { display: block; margin-bottom: 2px; word-break: break-all; }
  .pop a { margin-right: 8px; }
  .jb { padding-bottom: 12px; pointer-events: none; }
  .jb span { display: block; white-space: nowrap; background: rgba(255,255,255,.9); border: 1px solid #999; border-radius: 3px; padding: 0 4px; font-size: 11px; font-weight: bold; color: #222; }
  .jb i { font-weight: normal; color: #c62828; }
  .pin { box-sizing: border-box; border: 1.5px solid #fff; border-radius: 50%; color: #fff; font-size: 11px; font-weight: bold; display: flex; align-items: center; justify-content: center; opacity: .92; cursor: pointer; box-shadow: 0 0 2px rgba(0,0,0,.4); }
  .ring { width: 28px; height: 28px; box-sizing: border-box; border: 3px solid #ffb300; border-radius: 50%; pointer-events: none; }
</style>
</head>
<body>
<div id="map"></div>

<div id="nm" class="box">
  <div id="nm_t"></div>
  <label><input type="checkbox" id="nm_only"> 이름 없는 사진만 보기</label><br>
  <button type="button" id="nm_prev">◀ 이전</button> <button type="button" id="nm_next">다음 ▶</button> <span id="nm_pos"></span>
  <details style="margin-top:4px"><summary style="cursor:pointer">목록</summary><div id="nm_list" style="max-height:160px;overflow:auto"></div></details>
</div>

<div id="lay" class="box">
  <label><input type="radio" name="mt" value="road" checked> 일반 지도</label>
  <label><input type="radio" name="mt" value="sky"> 스카이뷰(위성)</label><br>
  <label><input type="checkbox" id="ly_dist"> 지적편집도 (필지 경계)</label><br>
  <label><input type="checkbox" id="ly_lab" checked> 지번 표시</label>
  <label><input type="checkbox" id="ly_ph" checked> 사진 위치</label>
</div>

<div id="detail" class="box"></div>
<div id="info" class="box"></div>
<div id="err" class="box"></div>

<script>
var D = __DATA__;
function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
function $(id) { return document.getElementById(id); }

var started = false;
var map, ring;
var pos = [];           // 사진별 좌표(LatLng)
var pinOvs = [];        // 화면에 그린 핀(점/묶음)
var labelOvs = [];      // 지번 글자
var curList = [];       // 겹친 점 목록
var onlyNone = false;   // true면 이름 없는 사진만 보임
var showPhotos = true;
var showLabels = true;
var noneIdx = [];       // 이름에 주소가 없는 사진 번호(촬영 시각 순)
var noneCur = -1;
var GR = 14;            // 이 거리(화면 픽셀) 안에 있는 사진은 한 핀으로 묶음 (멀리서나 가까이서나 같은 규칙)

// ---- 카카오 지도 불러오기 (키/도메인이 틀리면 안내 상자를 보여줌) ----
function showErr() {
  if (started) { return; }
  var e = $('err');
  e.style.display = 'block';
  e.innerHTML = '<b>카카오 지도를 불러오지 못했습니다.</b><ol style="margin:6px 0;padding-left:20px">' +
    '<li>저장된 키가 <b>JavaScript 키</b>인지 확인 (REST API 키는 안 됩니다)</li>' +
    '<li>카카오 개발자 사이트 [플랫폼 키] &gt; JavaScript 키 &gt; [JavaScript SDK 도메인]에 <code>http://localhost:8765</code> 등록</li>' +
    '<li>[카카오맵] &gt; [사용 설정]이 ON인지</li><li>인터넷 연결</li></ol>' +
    '<button type="button" onclick="return resetKey();">저장된 JavaScript 키 지우기</button> <span id="errmsg" style="font-size:12px"></span>';
}
function resetKey() {
  fetch('/resetkey', { method: 'POST', body: JSON.stringify({ token: D.token }) })
    .then(function (r) { return r.json(); })
    .then(function (res) { $('errmsg').textContent = res.ok ? '지웠습니다. PowerShell 창에서 Enter로 닫고 다시 실행하면 키를 새로 묻습니다.' : res.msg; })
    .catch(function () { $('errmsg').textContent = '실패: PowerShell 창이 닫혔는지 확인하세요.'; });
  return false;
}
var sdk = document.createElement('script');
sdk.src = 'https://dapi.kakao.com/v2/maps/sdk.js?appkey=' + encodeURIComponent(D.jskey) + '&autoload=false';
sdk.onload = function () {
  if (window.kakao && kakao.maps && kakao.maps.load) { kakao.maps.load(startMap); } else { showErr(); }
};
sdk.onerror = showErr;
document.head.appendChild(sdk);
setTimeout(showErr, 10000);

// ---- 핀 그리기: 가까운 사진은 한 핀으로 묶음. 모양은 항상 같음 ----
//  빨강 = 묶음 안 모든 사진 이름에 주소 있음, 파랑 = 이름에 주소 없는 사진이 하나라도 있음, 숫자 = 사진 장수(1장이면 숫자 없음)
function byTime(x, y) { return D.photos[x].t < D.photos[y].t ? -1 : (D.photos[x].t > D.photos[y].t ? 1 : 0); }
function pinSize(g) {
  if (g.m.length === 1) { return g.none ? 18 : 12; }
  return Math.round(22 + Math.min(14, Math.log(g.m.length) / Math.LN2 * 3));
}
function findGroup(cells, pt) {
  var cx = Math.floor(pt.x / GR), cy = Math.floor(pt.y / GR);
  for (var a = -1; a <= 1; a++) {
    for (var b = -1; b <= 1; b++) {
      var arr = cells[(cx + a) + ',' + (cy + b)];
      if (!arr) { continue; }
      for (var k = 0; k < arr.length; k++) {
        var dx = arr[k].x - pt.x, dy = arr[k].y - pt.y;
        if (dx * dx + dy * dy <= GR * GR) { return arr[k]; }
      }
    }
  }
  return null;
}
function bestJibun(g) {
  var cnt = {}, best = '', bc = 0;
  g.m.forEach(function (i) { var j = D.photos[i].j; if (j) { cnt[j] = (cnt[j] || 0) + 1; if (cnt[j] > bc) { bc = cnt[j]; best = j; } } });
  return best;
}
function drawPin(g) {
  var size = pinSize(g), el = document.createElement('div');
  el.className = 'pin';
  el.style.cssText = 'width:' + size + 'px;height:' + size + 'px;background:' + (g.none ? '#1e88e5' : '#e53935') + ';';
  if (g.m.length > 1) { el.textContent = String(g.m.length); }
  el.addEventListener('click', function (e) { e.stopPropagation(); onPin(g); });
  var o = new kakao.maps.CustomOverlay({ position: g.ll, content: el, xAnchor: 0.5, yAnchor: 0.5, zIndex: g.none ? 3 : 2, clickable: true });
  o.setMap(map);
  pinOvs.push(o);
}
// 화면에 보이는 사진을 묶어서 핀과 지번 글자를 다시 그림 (지도 이동/확대, 필터, 이름 변경 때마다)
function refreshView() {
  pinOvs.forEach(function (o) { o.setMap(null); }); pinOvs = [];
  labelOvs.forEach(function (o) { o.setMap(null); }); labelOvs = [];
  var proj = map.getProjection(), bnd = map.getBounds(), sw = bnd.getSouthWest(), ne = bnd.getNorthEast();
  var dl = (ne.getLat() - sw.getLat()) * 0.1, dg = (ne.getLng() - sw.getLng()) * 0.1;
  var lo0 = sw.getLng() - dg, lo1 = ne.getLng() + dg, la0 = sw.getLat() - dl, la1 = ne.getLat() + dl;
  var groups = [], cells = {};
  D.photos.forEach(function (p, i) {
    if (onlyNone && p.r) { return; }
    if (p.la < la0 || p.la > la1 || p.lo < lo0 || p.lo > lo1) { return; }
    var pt = proj.containerPointFromCoords(pos[i]);
    var g = findGroup(cells, pt);
    if (!g) {
      g = { x: pt.x, y: pt.y, m: [], sla: 0, slo: 0, minx: pt.x, maxx: pt.x, miny: pt.y, maxy: pt.y, none: false };
      groups.push(g);
      var key = Math.floor(pt.x / GR) + ',' + Math.floor(pt.y / GR);
      (cells[key] = cells[key] || []).push(g);
    }
    g.m.push(i); g.sla += p.la; g.slo += p.lo;
    if (pt.x < g.minx) { g.minx = pt.x; } if (pt.x > g.maxx) { g.maxx = pt.x; }
    if (pt.y < g.miny) { g.miny = pt.y; } if (pt.y > g.maxy) { g.maxy = pt.y; }
    if (!p.r) { g.none = true; }
  });
  groups.forEach(function (g) {
    g.ll = new kakao.maps.LatLng(g.sla / g.m.length, g.slo / g.m.length);
    g.ext = Math.max(g.maxx - g.minx, g.maxy - g.miny);
    if (showPhotos) { drawPin(g); }
  });
  if (!showLabels || map.getLevel() > 4) { return; }
  // 지번 글자: 사진이 많은 핀부터, 이미 놓인 글자와 겹치면 건너뜀 (확대하면 나타남)
  var placed = [];
  groups.slice().sort(function (a, b) { return b.m.length - a.m.length; }).slice(0, 400).forEach(function (g) {
    var best = bestJibun(g);
    if (!best) { return; }
    var plain = best + (g.m.length > 1 ? ' (' + g.m.length + ')' : '');
    var w = plain.length * 7 + 14, h = 18, r = pinSize(g) / 2 + 2;
    var pt = proj.containerPointFromCoords(g.ll);
    var box = { l: pt.x - w / 2, r: pt.x + w / 2, t: pt.y - r - h, b: pt.y - r };
    for (var k = 0; k < placed.length; k++) {
      var q = placed[k];
      if (box.l < q.r && box.r > q.l && box.t < q.b && box.b > q.t) { return; }
    }
    placed.push(box);
    var txt = esc(best) + (g.m.length > 1 ? ' <i>(' + g.m.length + ')</i>' : '');
    var o = new kakao.maps.CustomOverlay({ position: g.ll, content: '<div class="jb" style="padding-bottom:' + Math.round(r) + 'px"><span>' + txt + '</span></div>', xAnchor: 0.5, yAnchor: 1, zIndex: 5 });
    o.setMap(map);
    labelOvs.push(o);
  });
}

// ---- 사진 상세 (오른쪽 상자) ----
// 입력칸에 미리 넣어 둘 주소: 이 사진의 주소, 없으면 가장 가까운 사진의 주소에서 지번만 뺀 것
function suggestAddr(i) {
  var p = D.photos[i];
  if (p.a) { return p.a; }
  var best = null, bd = 1e9;
  D.photos.forEach(function (q, j) {
    if (j === i || !q.a) { return; }
    var d = Math.pow(q.la - p.la, 2) + Math.pow(q.lo - p.lo, 2);
    if (d < bd) { bd = d; best = q; }
  });
  return best ? best.a.replace(/(산\s*)?\d+(-\d+)?$/, '') : '';
}
function rnKey(e, i) { e.stopPropagation(); if (e.key === 'Enter') { return doRename(i); } return true; }
function doRename(i) {
  var el = $('rn'), msg = $('rnmsg');
  var addr = el.value.trim().replace(/^[^가-힣]*닫기\s*/, '');
  if (!addr) { msg.style.color = '#c62828'; msg.textContent = '주소를 입력하세요.'; return false; }
  msg.style.color = '#555'; msg.textContent = '바꾸는 중...';
  fetch('/rename', { method: 'POST', body: JSON.stringify({ token: D.token, i: i, addr: addr }) })
    .then(function (r) { return r.json(); })
    .then(function (res) {
      if (!res.ok) { msg.style.color = '#c62828'; msg.textContent = res.msg; return; }
      var p = D.photos[i];
      var wasNone = !p.r;
      var pp = noneIdx.indexOf(i);
      p.n = res.name; p.a = res.addr; p.j = res.jibun; p.done = true; p.r = 1;
      (res.others || []).forEach(function (o) { var q = D.photos[o.i]; q.n = o.name; q.a = o.addr; q.j = o.jibun; q.r = 1; });
      collectNone();
      if (wasNone && pp >= 0) { noneCur = pp - 1; }
      if (!noneIdx.length && onlyNone) { onlyNone = false; $('nm_only').checked = false; }
      refreshView();
      refreshNone();
      showDetail(i, curList.length > 1);
    })
    .catch(function () { msg.style.color = '#c62828'; msg.textContent = '실패: PowerShell 창이 닫혔는지 확인하세요.'; });
  return false;
}
function detailHtml(i, back) {
  var p = D.photos[i];
  var c = p.la.toFixed(6) + ', ' + p.lo.toFixed(6);
  var kakao_url = 'https://map.kakao.com/link/map/' + encodeURIComponent('사진') + ',' + p.la + ',' + p.lo;
  var rn = '<details' + (p.r ? '' : ' open') + ' style="margin-top:6px"><summary style="cursor:pointer">이름 직접 바꾸기</summary>' +
    '<div style="margin-top:4px">주소를 지번까지 입력:<br>' +
    '<input id="rn" type="text" value="' + esc(suggestAddr(i)) + '" style="width:100%;box-sizing:border-box" onkeydown="return rnKey(event,' + i + ');">' +
    '<button type="button" onclick="return doRename(' + i + ');" style="margin-top:4px">이름 바꾸기</button> <span id="rnmsg" style="font-size:12px"></span></div></details>';
  return '<div class="pop"><a href="#" onclick="return closeDetail();" style="float:right;margin:0">✕ 닫기</a>' +
    (back ? '<a href="#" onclick="return showList();">&larr; 목록으로</a><br>' : '') +
    (p.done ? '<div style="color:#2e7d32;font-weight:bold">✔ 이름을 바꿨습니다</div>' : '') +
    (!p.r ? '<div style="color:#1565c0;font-weight:bold">이름에 주소가 없는 사진</div>' : '') +
    '<b>' + esc(p.n) + '</b>' + (p.a ? esc(p.a) + '<br>' : '') + esc(p.t) + '<br>' + c + '<br>' +
    '<img src="' + esc(p.u) + '" loading="lazy" style="max-width:270px;max-height:200px;display:block;margin:4px 0">' +
    '<a href="' + esc(p.u) + '" target="_blank">사진 크게 보기</a>' +
    '<a href="https://www.google.com/maps?q=' + p.la + ',' + p.lo + '" target="_blank">구글맵에서 보기</a>' +
    '<a href="' + kakao_url + '" target="_blank">카카오맵에서 보기</a>' + rn + '</div>';
}
function listHtml() {
  var h = '<div class="pop"><a href="#" onclick="return closeDetail();" style="float:right;margin:0">✕ 닫기</a>' +
    '<b>이 위치의 사진 ' + curList.length + '장</b>(눌러서 선택)' +
    '<div style="max-height:200px;overflow:auto;margin-top:4px">';
  curList.forEach(function (i) {
    var p = D.photos[i];
    h += '<a href="#" onclick="return showDetail(' + i + ', true);" style="display:block;margin:2px 0">' + esc(p.t) + ' · ' + esc(p.n) + '</a>';
  });
  return h + '</div></div>';
}
function selectPhoto(i) { ring.setPosition(pos[i]); ring.setMap(map); }
function showDetail(i, back) {
  var d = $('detail');
  d.innerHTML = detailHtml(i, back);
  d.style.display = 'block';
  selectPhoto(i);
  return false;
}
function showList() {
  var d = $('detail');
  d.innerHTML = listHtml();
  d.style.display = 'block';
  return false;
}
function closeDetail() { $('detail').style.display = 'none'; ring.setMap(null); return false; }

// ---- 핀 누르기: 1장이면 상세 / 거의 같은 자리면 목록 / 넓게 흩어진 묶음이면 그 사진들이 보이게 확대 ----
function onPin(g) {
  var list = g.m.slice().sort(byTime);
  if (list.length === 1) { curList = list; showDetail(list[0], false); return; }
  if (g.ext <= 6 || map.getLevel() <= 1) { curList = list; showList(); selectPhoto(list[0]); return; }
  var b = new kakao.maps.LatLngBounds();
  list.forEach(function (i) { b.extend(pos[i]); });
  map.setBounds(b, 90, 90, 90, 90);
}

// ---- 이름 없는 사진 찾기 상자 ----
function collectNone() {
  noneIdx = [];
  D.photos.forEach(function (p, i) { if (!p.r) { noneIdx.push(i); } });
  noneIdx.sort(function (x, y) { var a = D.photos[x].t, b = D.photos[y].t; return a < b ? -1 : (a > b ? 1 : 0); });
}
function openPhoto(i) {
  if (map.getLevel() > 3) { map.setLevel(3); }
  map.setCenter(pos[i]);
  curList = [i];
  showDetail(i, false);
  refreshNone();
}
function goNone(step) {
  if (!noneIdx.length) { return; }
  if (noneCur < 0) { noneCur = step > 0 ? 0 : noneIdx.length - 1; }
  else { noneCur = (noneCur + step + noneIdx.length) % noneIdx.length; }
  openPhoto(noneIdx[noneCur]);
}
function openNone(i) { noneCur = noneIdx.indexOf(i); openPhoto(i); return false; }
function refreshNone() {
  var t = $('nm_t'), ps = $('nm_pos'), ls = $('nm_list');
  t.innerHTML = noneIdx.length ? '이름에 주소 없는 사진 <b style="color:#1565c0">' + noneIdx.length + '</b>장 (파란 점)' : '<span style="color:#2e7d32">이름 없는 사진 없음 ✔</span>';
  ps.textContent = (noneIdx.length && noneCur >= 0) ? (noneCur + 1) + ' / ' + noneIdx.length : '';
  var h = '';
  noneIdx.forEach(function (i) { var p = D.photos[i]; h += '<a href="#" onclick="return openNone(' + i + ');" style="display:block;margin:2px 0">' + esc(p.t) + ' · ' + esc(p.n) + '</a>'; });
  ls.innerHTML = h;
  $('nm_only').disabled = !noneIdx.length;
}

// ---- 지도 시작 (카카오 SDK가 준비된 뒤 한 번 실행) ----
function startMap() {
  started = true;
  $('err').style.display = 'none';
  pos = D.photos.map(function (p) { return new kakao.maps.LatLng(p.la, p.lo); });
  map = new kakao.maps.Map($('map'), { center: pos[0], level: 4 });
  map.addControl(new kakao.maps.ZoomControl(), kakao.maps.ControlPosition.BOTTOMRIGHT);
  ring = new kakao.maps.CustomOverlay({ content: '<div class="ring"></div>', xAnchor: 0.5, yAnchor: 0.5, zIndex: 20 });

  // 사진이 한 장이면 그 자리로, 여러 장이면 전체가 보이게
  if (pos.length === 1) { map.setLevel(3); map.setCenter(pos[0]); }
  else {
    var b = new kakao.maps.LatLngBounds();
    pos.forEach(function (ll) { b.extend(ll); });
    map.setBounds(b, 70, 70, 70, 70);
  }

  kakao.maps.event.addListener(map, 'idle', refreshView);

  // 지도 종류 / 지적편집도 / 지번 / 사진 위치
  var mts = document.getElementsByName('mt');
  for (var k = 0; k < mts.length; k++) {
    mts[k].onchange = function () {
      map.setMapTypeId(this.value === 'sky' ? kakao.maps.MapTypeId.HYBRID : kakao.maps.MapTypeId.ROADMAP);
    };
  }
  $('ly_dist').onchange = function () {
    if (this.checked) { map.addOverlayMapTypeId(kakao.maps.MapTypeId.USE_DISTRICT); }
    else { map.removeOverlayMapTypeId(kakao.maps.MapTypeId.USE_DISTRICT); }
  };
  $('ly_lab').onchange = function () { showLabels = this.checked; refreshView(); };
  $('ly_ph').onchange = function () { showPhotos = this.checked; refreshView(); };

  $('nm_only').onchange = function () { onlyNone = this.checked; refreshView(); };
  $('nm_prev').onclick = function () { goNone(-1); };
  $('nm_next').onclick = function () { goNone(1); };
  collectNone();
  refreshNone();
  refreshView();
}

$('info').innerHTML = '사진 <b>' + D.photos.length + '</b>장' +
  (D.skipped ? ' (GPS 없는 ' + D.skipped + '장 제외)' : '') +
  '<br><span style="color:#e53935">●</span> 이름에 주소 있음 &nbsp;<span style="color:#1e88e5">●</span> 이름에 주소 없음<br>점을 누르면 사진·주소·좌표가 나옵니다. 확대하면 지번이 보입니다.<br>필지 경계는 오른쪽 위 \"지적편집도\"를 켜세요.';
</script>
</body>
</html>
'@

# ---------------- 사진 위치 지도 (카카오 지도 JavaScript SDK, JavaScript 키 필요) ----------------
function JsStr([string]$s) {
    $s = $s.Replace('\', '\\').Replace('"', '\"').Replace('<', '\u003c').Replace("`r", '').Replace("`n", ' ').Replace("`t", ' ')
    return ('"' + $s + '"')
}

function Load-Cache {
    if (Test-Path -LiteralPath $cacheFile) {
        foreach ($line in [IO.File]::ReadAllLines($cacheFile, $utf8)) {
            $kv = $line -split "`t", 2
            if ($kv.Count -eq 2 -and $kv[1]) { $script:cache[$kv[0]] = $kv[1] }
        }
    }
}

# ---- 카카오 지도(JavaScript SDK)용 JavaScript 키 ----
# 지도는 주소 조회용 REST API 키와 다른 "JavaScript 키"를 씁니다. 지도 서버 주소는 http://localhost:8765 로 고정입니다.
$jsKeyFile = Join-Path $here 'kakao_js_key.txt'
$script:jsKey = ''
$mapPort = 8765

function Ensure-JsKey {
    if ($KakaoJsKey) { $k0 = Clean-Key $KakaoJsKey; if ($k0) { return $k0 } }
    if (Test-Path -LiteralPath $jsKeyFile) {
        $k = Clean-Key ([IO.File]::ReadAllText($jsKeyFile))
        if ($k) { return $k }
    }
    Write-Host ''
    Write-Host '카카오 지도를 쓰려면 JavaScript 키가 필요합니다. (주소 조회용 REST API 키와 다릅니다. 한 번만 입력하면 저장됩니다)' -ForegroundColor Yellow
    Write-Host '  1) developers.kakao.com > 내 애플리케이션 > 앱 선택 > [플랫폼 키] > JavaScript 키 > 키 복사'
    Write-Host "  2) 같은 화면의 [JavaScript SDK 도메인]에 이 주소를 등록:  http://localhost:$mapPort"
    Write-Host '  3) [카카오맵] > [사용 설정]이 ON인지 확인'
    $in = Clean-Key (Read-Host '  JavaScript 키 붙여넣기 (그만하려면 Enter)')
    if (-not $in) { return '' }
    $rest = Load-Key
    if ($rest -and ($in -eq $rest)) {
        Write-Host '  이 값은 REST API 키입니다. 지도에는 JavaScript 키를 넣어야 합니다.' -ForegroundColor Red
        return ''
    }
    [IO.File]::WriteAllText($jsKeyFile, $in, $utf8)
    return $in
}

# 같은 주소 사진을 촬영 시각 순으로 (1), (2)... 다시 매기는 계획 (메뉴 1의 번호 규칙과 같음)
# $exclude: 계획에서 뺄 파일 경로, $extra: 이 주소 모음에 추가로 넣을 파일(FileInfo)
function Get-GroupPlan([string]$dir, [string]$addr, [string]$exclude, $extra) {
    $cand = New-Object System.Collections.Generic.List[object]
    if ($extra) { $cand.Add($extra) }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File)) {
        if ($f.FullName -eq $exclude -or $f.Name -like '__tmp_*') { continue }
        if ($f.BaseName -match $namePattern -and $matches['addr'] -eq $addr) { $cand.Add($f) }
    }
    $recs = New-Object System.Collections.Generic.List[object]
    foreach ($f in $cand) {
        $inf = Get-PhotoInfo $f
        $coord = ''
        if ($script:withCoord) {
            if ($null -ne $inf.Lat) { $coord = ' ' + ([double]$inf.Lat).ToString('F6', $inv) + ', ' + ([double]$inf.Lon).ToString('F6', $inv) }
            elseif ($f.BaseName -match '( -?\d+\.\d+, -?\d+\.\d+)$') { $coord = $matches[1] }
        }
        $recs.Add([pscustomobject]@{ File = $f; Taken = $inf.Taken; Name = $f.Name; Coord = $coord })
    }
    $sorted = @($recs | Sort-Object -Property @{ Expression = 'Taken'; Descending = $NewestFirst }, @{ Expression = 'Name'; Descending = $NewestFirst })
    $out = New-Object System.Collections.Generic.List[object]
    for ($k = 0; $k -lt $sorted.Count; $k++) {
        $r = $sorted[$k]
        $nn = '{0} ({1}){2}{3}' -f $addr, ($k + 1), $r.Coord, $r.File.Extension
        $out.Add([pscustomobject]@{ From = $r.File.FullName; To = (Join-Path $r.File.DirectoryName $nn); Name = $nn; Addr = $addr })
    }
    return $out.ToArray()
}

function Send-Bytes($ctx, [byte[]]$bytes, [string]$type) {
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Get-ItemJson([string]$name, [string]$lat, [string]$lon, [string]$when, [string]$addr, [string]$jibun, [int]$idx, [int]$named = 0) {
    return ('{"n":' + (JsStr $name) + ',"la":' + $lat + ',"lo":' + $lon + ',"t":' + (JsStr $when) + ',"a":' + (JsStr $addr) + ',"j":' + (JsStr $jibun) + ',"r":' + $named + ',"u":"/p/' + $idx + '"}')
}

function Build-MapHtml([string]$root, [int]$skipped, [string]$token, $items) {
    $json = '{"folder":' + (JsStr $root) + ',"skipped":' + $skipped + ',"token":' + (JsStr $token) + ',"jskey":' + (JsStr $script:jsKey) + ',"photos":[' + ($items.ToArray() -join ',') + ']}'
    return $utf8.GetBytes($mapTemplate.Replace('__DATA__', $json))
}

function Invoke-Map([string]$root) {
    $script:jsKey = Ensure-JsKey
    if (-not $script:jsKey) { Write-Host 'JavaScript 키가 없어 지도를 열지 않습니다.' -ForegroundColor Red; return }
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object { $_.Extension -match '^\.jpe?g$' -and $_.Name -notlike '__tmp_*' })
    if ($files.Count -eq 0) { throw '이 폴더(하위 폴더 포함)에 JPG 사진이 없습니다.' }
    Write-Host ''
    Write-Host "사진 $($files.Count)장 읽는 중... (하위 폴더 포함)" -ForegroundColor Cyan
    $items = New-Object System.Collections.Generic.List[string]
    $paths = New-Object System.Collections.Generic.List[string]
    $meta  = New-Object System.Collections.Generic.List[object]
    $skipped = 0
    $unnamed = 0
    # 지번 표시용 주소: 이름에 있는 주소 > 저장된 주소 > (저장된 API 키가 있으면) 카카오 조회
    Load-Cache
    $script:apiKey = Load-Key
    $lookup = [bool]$script:apiKey
    if (-not $lookup) { Write-Host '(저장된 API 키가 없어, 주소를 모르는 사진은 지번이 비어 보일 수 있습니다)' -ForegroundColor DarkGray }
    $i = 0
    foreach ($f in $files) {
        $i++
        if ($i % 20 -eq 0 -or $i -eq $files.Count) { Write-Progress -Activity 'GPS 읽기 / 주소 확인 중' -Status "$i / $($files.Count)" -PercentComplete ([int](100 * $i / $files.Count)) }
        $info = Get-PhotoInfo $f
        if ($info.Status -ne 'GPS있음') { $skipped++; continue }
        $idx = $paths.Count
        $paths.Add($f.FullName)
        $addr = ''
        $named = 0
        if ($f.BaseName -match $namePattern) { $addr = $matches['addr']; $named = 1 }
        else {
            $unnamed++
            $ck = ('{0:F6},{1:F6}' -f $info.Lat, $info.Lon)
            if ($script:cache.ContainsKey($ck)) { $addr = $script:cache[$ck] }
            elseif ($lookup) {
                try { $a2 = Get-Address $info.Lat $info.Lon; if ($a2) { $addr = $a2 } }
                catch { $lookup = $false; Write-Host "  주소 조회를 중단합니다(일부 지번 표시가 빠집니다): $($_.Exception.Message)" -ForegroundColor Yellow }
            }
        }
        $jibun = ''
        if ($addr -match '((?:산\s*)?\d+(?:-\d+)?)$') { $jibun = $matches[1] }
        $lat = ([double]$info.Lat).ToString('F6', $inv)
        $lon = ([double]$info.Lon).ToString('F6', $inv)
        $when = ([datetime]$info.Taken).ToString('yyyy-MM-dd HH:mm', $inv)
        $meta.Add([pscustomobject]@{ Lat = $lat; Lon = $lon; When = $when })
        $items.Add((Get-ItemJson $f.Name $lat $lon $when $addr $jibun $idx $named))
    }
    Write-Progress -Activity 'GPS 읽는 중' -Completed
    if ($items.Count -eq 0) {
        Write-Host 'GPS가 있는 사진이 없습니다. (카톡/메신저로 옮기면 위치가 지워져요. USB로 복사한 원본을 쓰세요)' -ForegroundColor Yellow
        return
    }
    $token = [guid]::NewGuid().ToString('N')
    $htmlBytes = Build-MapHtml $root $skipped $token $items
    $manualLog = ''

    # 내 PC 안에서만 열리는 작은 웹 서버 (카카오 지도는 [JavaScript SDK 도메인]에 등록된 주소 http://localhost:8765 에서만 열림)
    $listener = $null; $port = $mapPort
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://localhost:$port/")
    try { $l.Start(); $listener = $l } catch { try { $l.Close() } catch { } }
    if (-not $listener) { throw "지도용 주소(http://localhost:$port)를 열 수 없습니다. 이전 지도 PowerShell 창이 아직 열려 있을 수 있습니다. 그 창에서 Enter를 눌러 닫거나 PowerShell 창을 모두 닫은 뒤 다시 실행하세요." }

    try {
        $url = "http://localhost:$port/"
        Write-Host ''
        Write-Host "지도를 브라우저로 엽니다 - 사진 $($items.Count)장 표시, GPS 없음 $($skipped)장 제외" -ForegroundColor Green
        if ($unnamed -gt 0) { Write-Host "  이름에 주소가 없는 사진 $($unnamed)장은 파란 점입니다 (지도 왼쪽 위 '이름 없는 사진' 상자에서 찾기)" -ForegroundColor Cyan }
        Write-Host "  지도가 비어 있으면: 카카오 개발자 사이트 [JavaScript SDK 도메인]에 http://localhost:$port 등록 / JavaScript 키 확인" -ForegroundColor DarkGray
        Write-Host '  ※ 다 봤으면 이 창에서 Enter (그때까지 창을 닫지 마세요)' -ForegroundColor Yellow
        Start-Process -FilePath $url

        $task = $listener.GetContextAsync()
        while ($true) {
            if ($task.AsyncWaitHandle.WaitOne(300)) {
                $ctx = $task.Result
                $task = $listener.GetContextAsync()
                try {
                    $path = $ctx.Request.Url.AbsolutePath
                    if ($path -eq '/') { Send-Bytes $ctx $htmlBytes 'text/html; charset=utf-8' }
                    elseif ($path -eq '/resetkey' -and $ctx.Request.HttpMethod -eq 'POST') {
                        $res = '{"ok":false,"msg":"처리하지 못했습니다."}'
                        try {
                            $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
                            $raw = $sr.ReadToEnd(); $sr.Dispose()
                            if ($raw.Length -gt 1000) { throw '요청이 너무 깁니다.' }
                            $req = $raw | ConvertFrom-Json
                            if ([string]$req.token -ne $token) { throw '허용되지 않은 요청입니다. 지도 창을 새로고침하세요.' }
                            if (Test-Path -LiteralPath $jsKeyFile) { Remove-Item -LiteralPath $jsKeyFile -Force }
                            $res = '{"ok":true}'
                            Write-Host '  (JavaScript 키를 지웠습니다. 다음 실행 때 새로 입력하세요)' -ForegroundColor Yellow
                        } catch {
                            $res = '{"ok":false,"msg":' + (JsStr $_.Exception.Message) + '}'
                        }
                        Send-Bytes $ctx ($utf8.GetBytes($res)) 'application/json; charset=utf-8'
                    }
                    elseif ($path -eq '/rename' -and $ctx.Request.HttpMethod -eq 'POST') {
                        $res = '{"ok":false,"msg":"처리하지 못했습니다."}'
                        try {
                            $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
                            $raw = $sr.ReadToEnd(); $sr.Dispose()
                            if ($raw.Length -gt 4000) { throw '요청이 너무 깁니다.' }
                            $req = $raw | ConvertFrom-Json
                            if ([string]$req.token -ne $token) { throw '허용되지 않은 요청입니다. 지도 창을 새로고침하세요.' }
                            $ix = [int]$req.i
                            if ($ix -lt 0 -or $ix -ge $paths.Count) { throw '사진 번호가 올바르지 않습니다.' }
                            $newAddr = ([string]$req.addr -replace '\s+', ' ').Trim()
                            $newAddr = ($newAddr -replace '^[^가-힣]*닫기\s*', '').Trim()   # 복사할 때 딸려 온 '닫기' 글자 제거
                            if ($newAddr -notmatch '^[가-힣].*\d$') { throw '주소는 한글로 시작해서 지번(숫자)으로 끝나야 합니다. 예) ○○도 ○○시 ○○면 ○○리 123-4' }
                            $tk = @($newAddr -split ' ')
                            if ($tk.Count -lt 3 -or $tk[0] -notmatch '(도|시)$') { throw '주소가 "○○도 ○○시 ○○면 ○○리 123-4"처럼 도/시로 시작해야 합니다. (복사할 때 다른 글자가 같이 들어갔는지 확인하세요)' }
                            if ($newAddr.Length -gt 120 -or $newAddr -match '[\\/:*?"<>|]') { throw '주소가 너무 길거나 쓸 수 없는 글자( \ / : * ? " < > | )가 있습니다.' }
                            $old = $paths[$ix]
                            if (-not (Test-Path -LiteralPath $old)) { throw '원본 파일을 찾을 수 없습니다. (다른 곳에서 이름을 바꿨나요?)' }
                            $dir = Split-Path -Parent $old
                            # 같은 주소 사진 전체를 촬영 시각 순으로 다시 번호 매김 (이 사진 포함). 주소를 바꾼 경우 예전 주소 쪽도 빈 번호를 메움
                            $oldAddr = ''
                            if ([IO.Path]::GetFileNameWithoutExtension($old) -match $namePattern) { $oldAddr = $matches['addr'] }
                            $plan = @(Get-GroupPlan $dir $newAddr $old (Get-Item -LiteralPath $old))
                            if ($oldAddr -and ($oldAddr -ne $newAddr)) { $plan += @(Get-GroupPlan $dir $oldAddr $old $null) }
                            $pairs = @($plan | Where-Object { $_.From -ne $_.To })
                            if ($pairs.Count -eq 0) { throw '이미 이 이름입니다.' }
                            $srcSet = @{}
                            foreach ($x in $plan) { $srcSet[$x.From.ToLowerInvariant()] = 1 }
                            foreach ($x in $pairs) {
                                if ((Test-Path -LiteralPath $x.To) -and (-not $srcSet.ContainsKey($x.To.ToLowerInvariant()))) { throw ('같은 이름의 파일이 이미 있습니다: ' + (Split-Path -Leaf $x.To)) }
                            }
                            # 되돌리기용 기록 (2번 메뉴로 되돌릴 수 있음)
                            if (-not $manualLog) {
                                $manualLog = Join-Path $root ('이름변경로그_지도_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv')
                                [IO.File]::WriteAllText($manualLog, ('"OldPath","NewPath"' + "`r`n"), $utf8bom)
                            }
                            foreach ($x in $pairs) {
                                [IO.File]::AppendAllText($manualLog, ('"' + $x.From.Replace('"', '""') + '","' + $x.To.Replace('"', '""') + '"' + "`r`n"), $utf8)
                            }
                            $okMoves = Invoke-Moves $pairs
                            # 지도 데이터 갱신 (실제로 옮겨진 파일만)
                            $oth = New-Object System.Collections.Generic.List[string]
                            $newName = ''
                            foreach ($x in $pairs) {
                                if (-not (Test-Path -LiteralPath $x.To)) { continue }
                                $jx = $paths.IndexOf($x.From)
                                $jb = ''
                                if ($x.Addr -match '((?:산\s*)?\d+(?:-\d+)?)$') { $jb = $matches[1] }
                                if ($jx -ge 0) {
                                    $paths[$jx] = $x.To
                                    $items[$jx] = Get-ItemJson $x.Name $meta[$jx].Lat $meta[$jx].Lon $meta[$jx].When $x.Addr $jb $jx 1
                                    if ($jx -ne $ix) { $oth.Add('{"i":' + $jx + ',"name":' + (JsStr $x.Name) + ',"addr":' + (JsStr $x.Addr) + ',"jibun":' + (JsStr $jb) + '}') }
                                }
                                if ($x.From -eq $old) { $newName = $x.Name }
                            }
                            $htmlBytes = Build-MapHtml $root $skipped $token $items
                            if ($okMoves -ne $pairs.Count) { throw '일부 사진 이름을 바꾸지 못했습니다. PowerShell 창의 메시지를 확인하고, 지도 창을 새로고침하세요.' }
                            if (-not $newName) { throw '이름을 바꾸지 못했습니다. PowerShell 창의 메시지를 확인하세요.' }
                            $jb = ''
                            if ($newAddr -match '((?:산\s*)?\d+(?:-\d+)?)$') { $jb = $matches[1] }
                            $res = '{"ok":true,"name":' + (JsStr $newName) + ',"addr":' + (JsStr $newAddr) + ',"jibun":' + (JsStr $jb) + ',"others":[' + ($oth -join ',') + ']}'
                            Write-Host "  (지도에서 이름 변경) $newName  (같은 주소 $($pairs.Count)장 번호 갱신)" -ForegroundColor Green
                        } catch {
                            $res = '{"ok":false,"msg":' + (JsStr $_.Exception.Message) + '}'
                        }
                        Send-Bytes $ctx ($utf8.GetBytes($res)) 'application/json; charset=utf-8'
                    }
                    elseif ($path -match '^/p/(\d+)$' -and [int]$matches[1] -lt $paths.Count) {
                        Send-Bytes $ctx ([IO.File]::ReadAllBytes($paths[[int]$matches[1]])) 'image/jpeg'
                    }
                    else { $ctx.Response.StatusCode = 404; $ctx.Response.Close() }
                } catch { try { $ctx.Response.Abort() } catch { } }
            }
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Enter') { break }
            }
        }
    } finally {
        try { $listener.Stop(); $listener.Close() } catch { }
    }
    Write-Host '지도를 닫았습니다.'
}

# ---------------- 폴더 정리 (주소 단위로 폴더 만들기 / 없애기) ----------------
$levelNames = @('도', '시/군/구', '읍/면/동', '리')

# 주소 -> 단계별 이름 4개 (도, 시/군/구, 읍/면/동, 리). 없는 단계는 빈 글자
function Split-AddressLevels([string]$addr) {
    $t = @($addr -split '\s+' | Where-Object { $_ })
    $n = $t.Count
    # 끝의 지번(123-4 / 산 12-3) 제외
    if ($n -gt 0 -and $t[$n - 1] -match '^산?\d+(-\d+)?$') {
        $n--
        if ($n -gt 0 -and $t[$n - 1] -eq '산') { $n-- }
    }
    $lv = @('', '', '', '')
    if ($n -eq 0) { return ,$lv }
    $lv[0] = $t[0]
    $i = 1
    $gu = New-Object System.Collections.Generic.List[string]
    while ($i -lt $n -and $t[$i] -match '[시군구]$') { $gu.Add($t[$i]); $i++ }
    if ($gu.Count -gt 0) { $lv[1] = ($gu -join ' ') }
    if ($i -lt $n -and $t[$i] -match '[읍면동가]$') { $lv[2] = $t[$i]; $i++ }
    if ($i -lt $n -and $t[$i] -match '리$') { $lv[3] = $t[$i]; $i++ }
    return ,$lv
}

# 고른 단계($level: 1~4)까지의 주소로 폴더 이름을 만듦. 그 단계가 주소에 없으면 있는 곳까지만(Used가 level보다 작음)
function Get-FolderKey([string]$addr, [int]$level) {
    $lv = Split-AddressLevels $addr
    $parts = @()
    $used = 0
    for ($k = 0; $k -lt $level; $k++) {
        if ($lv[$k]) { $parts += $lv[$k]; $used = $k + 1 }
    }
    return [pscustomobject]@{ Name = ($parts -join ' '); Used = $used }
}

# 한 번에 한 단계 이동 (같은 이름이 있으면 덮어쓰지 않고 실패 처리)
function Move-Direct($pairs) {
    $ok = 0
    $i = 0
    foreach ($p in $pairs) {
        $i++
        if ($i % 50 -eq 0 -or $i -eq $pairs.Count) { Write-Progress -Activity '사진 옮기는 중' -Status "$i / $($pairs.Count)" -PercentComplete ([int](100 * $i / $pairs.Count)) }
        try { [IO.File]::Move($p.From, $p.To); $ok++ }
        catch { Write-Host "  실패: $($p.From) : $($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Progress -Activity '사진 옮기는 중' -Completed
    return $ok
}

function Invoke-FolderCreate([string]$root) {
    $files = @(Get-Photos $root)
    if ($files.Count -eq 0) { throw '이 폴더(하위 폴더 1단계 포함)에 JPG 사진이 없습니다.' }
    Write-Host ''
    Write-Host "사진 $($files.Count)장 확인 (현재 폴더 + 하위 폴더 1단계)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '어느 단위로 폴더를 나눌까요?'
    Write-Host '  1  도          예) ○○도'
    Write-Host '  2  시/군/구    예) ○○도 ○○시'
    Write-Host '  3  읍/면/동    예) ○○도 ○○시 ○○면'
    Write-Host '  4  리          예) ○○도 ○○시 ○○면 ○○리'
    $level = [int](Read-Choice '번호' @('1', '2', '3', '4'))

    $plan = New-Object System.Collections.Generic.List[object]
    $noAddr = 0; $fallback = 0; $clash = 0; $badAddr = 0; $okAlready = 0
    foreach ($f in $files) {
        $addr = $null
        if ($f.BaseName -match $namePattern) { $addr = $matches['addr'] }
        if (-not $addr) { $noAddr++; continue }
        if (@($addr -split '\s+')[0] -notmatch '(도|시)$') { $badAddr++; continue }
        $k = Get-FolderKey $addr $level
        if (-not $k.Name) { $noAddr++; continue }
        if ($k.Used -lt $level) { $fallback++ }
        $destDir = Join-Path $root $k.Name
        $to = Join-Path $destDir $f.Name
        if ($to -eq $f.FullName) { $okAlready++; continue }     # 이미 맞는 폴더에 있음
        if (Test-Path -LiteralPath $to) { $clash++; continue }
        $plan.Add([pscustomobject]@{ From = $f.FullName; To = $to; Dir = $destDir; Folder = $k.Name })
    }

    $byFolder = @($plan | Group-Object -Property Folder | Sort-Object -Property Name)
    $newCount = 0
    $created = @{}
    foreach ($g in $byFolder) {
        $d = Join-Path $root $g.Name
        $isNew = -not (Test-Path -LiteralPath $d -PathType Container)
        $created[$d] = $isNew
        if ($isNew) { $newCount++ }
    }

    Write-Host ''
    Write-Host "[폴더 만들기 계획] $($levelNames[$level - 1]) 단위 - 폴더 $($byFolder.Count)개 (새로 만듦 $newCount, 이미 있음 $($byFolder.Count - $newCount)), 옮길 사진 $($plan.Count)장" -ForegroundColor Green
    foreach ($g in ($byFolder | Select-Object -First 20)) {
        $d = Join-Path $root $g.Name
        $tag = if ($created[$d]) { '새 폴더' } else { '기존 폴더' }
        Write-Host ("    {0}   {1}장  ({2})" -f $g.Name, $g.Count, $tag)
    }
    if ($byFolder.Count -gt 20) { Write-Host "    ... 외 $($byFolder.Count - 20)개 폴더" }
    if ($fallback -gt 0) { Write-Host "  주소에 $($levelNames[$level - 1]) 단계가 없는 사진 $($fallback)장은 있는 단계까지만으로 폴더를 만듭니다 (예: 동 지역에는 리가 없음)" }
    if ($noAddr -gt 0) { Write-Host "  이름에 주소가 없어 그대로 둘 사진 $($noAddr)장 (먼저 1번 이름 바꾸기 / 3번 지도에서 직접 지정)" -ForegroundColor Yellow }
    if ($badAddr -gt 0) { Write-Host "  이름의 주소가 도/시로 시작하지 않아 그대로 둘 사진 $($badAddr)장 (이름 확인 필요)" -ForegroundColor Yellow }
    if ($clash -gt 0) { Write-Host "  폴더에 같은 이름이 이미 있어 건너뜀 $($clash)장" -ForegroundColor Yellow }
    if ($okAlready -gt 0) { Write-Host "  이미 맞는 폴더에 있음 $($okAlready)장" }
    if ($plan.Count -gt 0) {
        Write-Host '  예시:'
        $plan | Select-Object -First 3 | ForEach-Object {
            Write-Host ('    ' + (Split-Path -Leaf $_.From))
            Write-Host ('    -> ' + $_.Folder + '\') -ForegroundColor Green
        }
    }
    if ($plan.Count -eq 0) { Write-Host ''; Write-Host '옮길 사진이 없습니다.'; return }

    Write-Host ''
    if ((Read-Host '폴더를 만들고 사진을 옮길까요? (Y=실행, 그 외=취소)') -notmatch '^[Yy]') {
        Write-Host '취소했습니다. (바뀐 것 없음)'; return
    }

    # 실행 전 기록 (되돌리기용)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logPath = Join-Path $root "폴더정리로그_$stamp.csv"
    $plan | ForEach-Object {
        $c = 'N'
        if ($created[$_.Dir]) { $c = 'Y' }
        [pscustomobject]@{ OldPath = $_.From; NewPath = $_.To; Created = $c }
    } | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding UTF8

    $todo = New-Object System.Collections.Generic.List[object]
    foreach ($g in $byFolder) {
        $d = Join-Path $root $g.Name
        try {
            [void][IO.Directory]::CreateDirectory($d)
            foreach ($p in $g.Group) { $todo.Add($p) }
        } catch {
            Write-Host "  폴더를 만들 수 없어 건너뜀: $($g.Name) : $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    $ok = Move-Direct $todo
    # 사진을 다른 폴더로 옮기고 비게 된 하위 폴더는 지움 (현재 폴더 자체는 지우지 않음)
    $emptied = 0
    foreach ($sd in @($plan | ForEach-Object { Split-Path -Parent $_.From } | Sort-Object -Unique)) {
        if ($sd -ne $root -and (Test-Path -LiteralPath $sd -PathType Container)) {
            if (@(Get-ChildItem -LiteralPath $sd -Force).Count -eq 0) {
                try { Remove-Item -LiteralPath $sd; $emptied++ } catch { }
            }
        }
    }
    Write-Host ''
    Write-Host "완료: 사진 $ok / $($plan.Count)장을 폴더로 옮겼습니다. (되돌리려면 4번 > 2번 폴더 없애기)" -ForegroundColor Green
    if ($emptied -gt 0) { Write-Host "  비어 버린 예전 폴더 $($emptied)개를 지웠습니다." }
}

function Invoke-FolderUndo([string]$root) {
    # 기록 파일 없이, 지금 폴더 안 상태를 보고 처리: 바로 아래 하위 폴더의 사진을 현재 폴더로 꺼내고, 빈 폴더를 지움
    $pairs = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $clash = 0
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File)) {
            if ($f.Extension -notmatch '^\.jpe?g$' -or $f.Name -like '__tmp_*') { continue }
            $to = Join-Path $root $f.Name
            if ((Test-Path -LiteralPath $to) -or $seen.ContainsKey($to.ToLowerInvariant())) { $clash++; continue }
            $seen[$to.ToLowerInvariant()] = 1
            $pairs.Add([pscustomobject]@{ From = $f.FullName; To = $to; Dir = $d.FullName })
        }
    }
    $byDir = @($pairs | Group-Object -Property Dir | Sort-Object -Property Name)
    Write-Host ''
    Write-Host "[폴더 없애기 계획] 폴더 $($byDir.Count)개 안의 사진 $($pairs.Count)장을 현재 폴더로 꺼냅니다 (직접 만든 폴더도 포함되니 목록을 확인하세요)" -ForegroundColor Green
    foreach ($g in ($byDir | Select-Object -First 20)) {
        $left = @(Get-ChildItem -LiteralPath $g.Name -Force).Count - $g.Count
        $tag = if ($left -le 0) { '폴더도 삭제' } else { '다른 파일이 있어 폴더는 남김' }
        Write-Host ("    {0}   {1}장  ({2})" -f (Split-Path -Leaf $g.Name), $g.Count, $tag)
    }
    if ($byDir.Count -gt 20) { Write-Host "    ... 외 $($byDir.Count - 20)개 폴더 (비면 함께 삭제)" }
    if ($clash -gt 0) { Write-Host "  현재 폴더에 같은 이름이 이미 있어 건너뜀 $($clash)장" -ForegroundColor Yellow }
    if ($pairs.Count -eq 0) { Write-Host '꺼낼 사진이 없습니다. (하위 폴더에 JPG 사진이 없음)'; return }

    Write-Host ''
    if ((Read-Host '사진을 꺼내고 빈 폴더를 지울까요? (Y=실행, 그 외=취소)') -notmatch '^[Yy]') {
        Write-Host '취소했습니다. (바뀐 것 없음)'; return
    }
    $ok = Move-Direct $pairs
    $removed = 0
    foreach ($g in $byDir) {
        $d = $g.Name
        if (Test-Path -LiteralPath $d -PathType Container) {
            if (@(Get-ChildItem -LiteralPath $d -Force).Count -eq 0) {
                try { Remove-Item -LiteralPath $d; $removed++ } catch { Write-Host "  폴더 삭제 실패: $d" -ForegroundColor Red }
            }
        }
    }
    Write-Host ''
    Write-Host "완료: 사진 $ok / $($pairs.Count)장 꺼냄, 빈 폴더 $($removed)개 삭제" -ForegroundColor Green
    if ($ok -eq $pairs.Count -and $clash -eq 0) {
        foreach ($lg in @(Get-ChildItem -LiteralPath $root -Filter '폴더정리로그_*.csv' -File)) {
            try { Rename-Item -LiteralPath $lg.FullName -NewName ('되돌림완료_' + $lg.Name) } catch { }
        }
    }
}

function Invoke-FolderMenu([string]$root) {
    Write-Host ''
    Write-Host '=== 폴더 정리 ===' -ForegroundColor Cyan
    Write-Host '  (이름에 주소가 붙은 사진만 정리합니다. 폴더 안의 폴더도 같이 봅니다)'
    Write-Host ''
    Write-Host '  1  폴더 만들기 (주소 단위로 사진 나눠 담기)'
    Write-Host '  2  폴더 없애기 (사진을 원래 자리로, 빈 폴더 삭제)'
    $m = Read-Choice '번호' @('1', '2')
    if ($m -eq '1') { Invoke-FolderCreate $root } else { Invoke-FolderUndo $root }
}

# ====================== 메인 ======================
try {
    Write-Host ''
    Write-Host '=== 사진 이름을 촬영 주소로 바꾸기 ===' -ForegroundColor Cyan
    Write-Host '  예) ○○도 ○○시 ○○면 ○○리 123-4 (1) 37.123456, 127.123456.jpg   (좌표는 넣기/빼기 선택)'
    Write-Host '  (이름만 바뀌고 사진은 그대로. 폴더 안의 폴더도 같이 봅니다. 2번으로 되돌릴 수 있어요)'
    Write-Host ''
    Write-Host '  1  이름 바꾸기'
    Write-Host '  2  되돌리기'
    Write-Host '  3  카카오 지도로 보기 (지적편집도·위성, 지도에서 이름 직접 고치기)'
    Write-Host '  4  폴더 정리 (주소 단위로 폴더 만들기 / 없애기)'
    $top = Read-Choice '번호' @('1', '2', '3', '4')

    $root = Read-Folder $FolderArg

    # ---------- 지도 ----------
    if ($top -eq '3') {
        $script:withCoord = Read-CoordChoice '  (지도에서 이름을 직접 바꿀 때 적용)'
        Invoke-Map $root
        return
    }

    # ---------- 폴더 정리 ----------
    if ($top -eq '4') { Invoke-FolderMenu $root; return }

    # ---------- 되돌리기 ----------
    if ($top -eq '2') {
        # 기록은 현재 폴더와 하위 폴더 1단계에서 찾고, 사진은 기록의 경로에 없으면 같은 이름의 파일을 현재 폴더/하위 폴더에서 찾음
        $logDirs = @(Get-Item -LiteralPath $root) + @(Get-ChildItem -LiteralPath $root -Directory)
        $logList = @()
        foreach ($ld in $logDirs) { $logList += @(Get-ChildItem -LiteralPath $ld.FullName -Filter '이름변경로그_*.csv' -File) }
        $latest = $logList | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { throw '이 폴더(하위 폴더 1단계 포함)에 되돌릴 기록(이름변경로그_*.csv)이 없습니다.' }
        Write-Host ''
        $rows = Import-Csv -LiteralPath $latest.FullName -Encoding UTF8
        $byName = @{}
        foreach ($pf in @(Get-Photos $root)) {
            $nk = $pf.Name.ToLowerInvariant()
            if ($byName.ContainsKey($nk)) { $byName[$nk] = '' } else { $byName[$nk] = $pf.FullName }   # 같은 이름이 둘이면 모호하므로 제외
        }
        $pairs = @()
        foreach ($r in $rows) {
            $from = ''
            if (Test-Path -LiteralPath $r.NewPath) { $from = $r.NewPath }
            else {
                $nk = (Split-Path -Leaf $r.NewPath).ToLowerInvariant()
                if ($byName.ContainsKey($nk) -and $byName[$nk]) { $from = $byName[$nk] }
            }
            if ($from) { $pairs += [pscustomobject]@{ From = $from; To = (Join-Path (Split-Path -Parent $from) (Split-Path -Leaf $r.OldPath)) } }
        }
        Write-Host "되돌릴 사진 $($pairs.Count)장 (기록: $($latest.Name))"
        if ($pairs.Count -eq 0) { Write-Host '되돌릴 사진이 없습니다. (이미 되돌렸거나 사진 이름을 직접 바꾼 경우)'; return }
        if ((Read-Host '원래 이름으로 되돌릴까요? (Y/N)') -notmatch '^[Yy]') { Write-Host '취소했습니다.'; return }
        $ok = Invoke-Moves $pairs
        Write-Host ''
        Write-Host "완료: $($ok)장을 원래 이름으로 되돌렸습니다." -ForegroundColor Green
        if ($ok -eq $pairs.Count) { Rename-Item -LiteralPath $latest.FullName -NewName ('되돌림완료_' + $latest.Name) }
        return
    }

    # ---------- 좌표 넣기/빼기 ----------
    $script:withCoord = Read-CoordChoice

    # ---------- API 키 ----------
    if (-not (Ensure-ApiKey)) { return }
    if (Test-Path -LiteralPath $cacheFile) {
        foreach ($line in [IO.File]::ReadAllLines($cacheFile, $utf8)) {
            $kv = $line -split "`t", 2
            if ($kv.Count -eq 2 -and $kv[1]) { $script:cache[$kv[0]] = $kv[1] }
        }
    }

    # ---------- 1단계: GPS 확인 ----------
    $files = @(Get-Photos $root)
    if ($files.Count -eq 0) { throw '이 폴더(하위 폴더 1단계 포함)에 JPG 사진이 없습니다.' }
    Write-Host ''
    Write-Host "사진 $($files.Count)장 확인 중..." -ForegroundColor Cyan

    $infos = @{}
    $i = 0
    foreach ($f in $files) {
        $i++
        if ($i % 20 -eq 0 -or $i -eq $files.Count) { Write-Progress -Activity 'GPS 확인 중' -Status "$i / $($files.Count)" -PercentComplete ([int](100 * $i / $files.Count)) }
        $infos[$f.FullName] = Get-PhotoInfo $f
    }
    Write-Progress -Activity 'GPS 확인 중' -Completed

    $has    = @($files | Where-Object { $infos[$_.FullName].Status -eq 'GPS있음' })
    $noGps  = @($files | Where-Object { $infos[$_.FullName].Status -eq 'GPS없음' })
    $noExif = @($files | Where-Object { $infos[$_.FullName].Status -eq 'EXIF없음' })
    $fail   = @($files | Where-Object { $infos[$_.FullName].Status -eq '읽기실패' })
    $already = @($files | Where-Object { $_.BaseName -match $namePattern })

    Write-Host ''
    Write-Host "[GPS 확인] 사진 $($files.Count)장 중 GPS 있음 $($has.Count)장" -ForegroundColor Cyan
    $noGpsAll = $noGps.Count + $noExif.Count
    if ($noGpsAll -gt 0) { Write-Host "  GPS 없음 $($noGpsAll)장 (건너뜀)" -ForegroundColor Yellow }
    if ($fail.Count -gt 0) { Write-Host "  읽기 실패 $($fail.Count)장 (건너뜀)" -ForegroundColor Red }
    if ($already.Count -gt 0) { Write-Host "  이름에 이미 주소가 붙은 사진 $($already.Count)장 (사진 위치와 다르면 고칩니다)" }

    if ($has.Count -eq 0 -and $already.Count -eq 0) {
        Write-Host ''
        Write-Host 'GPS가 있는 사진이 없습니다. 카톡/메신저로 옮기면 위치가 지워져요. USB로 폰의 DCIM\Camera 폴더를 복사해 다시 해 보세요.' -ForegroundColor Yellow
        return
    }

    # ---------- 2단계: 주소 조회 ----------
    $recs   = New-Object System.Collections.Generic.List[object]
    $noAddr = New-Object System.Collections.Generic.List[string]
    $noAddrShow = New-Object System.Collections.Generic.List[string]
    $skipGps = New-Object System.Collections.Generic.List[string]
    # 기준은 항상 사진 속 GPS입니다. 이름이나 로그에 적힌 주소는 믿지 않고, 캐시에 있는 좌표만 조회를 생략합니다. (캐시가 없어도 카카오에서 새로 조회)
    $need = @{}
    foreach ($f in $files) {
        $inf0 = $infos[$f.FullName]
        if ($inf0.Status -eq 'GPS있음') {
            $k0 = ('{0:F6},{1:F6}' -f $inf0.Lat, $inf0.Lon)
            if (-not $script:cache.ContainsKey($k0)) { $need[$k0] = 1 }
        }
    }
    $todo = $need.Count
    $fixAddr = New-Object System.Collections.Generic.List[string]
    $keptName = 0
    if ($todo -gt 0) {
        Write-Host ''
        Write-Host "[주소 조회] 캐시에 없는 좌표 $($todo)곳 (창을 닫지 마세요. 멈춰도 다시 실행하면 이어서 합니다)" -ForegroundColor Cyan
    }
    $i = 0
    foreach ($f in $files) {
        $info = $infos[$f.FullName]
        $nameAddr = $null
        if ($f.BaseName -match $namePattern) { $nameAddr = $matches['addr'] }
        $nameCoord = ''
        if ($f.BaseName -match '( -?\d+\.\d+, -?\d+\.\d+)$') { $nameCoord = $matches[1] }
        $addr = $null
        if ($info.Status -eq 'GPS있음') {
            $ck = ('{0:F6},{1:F6}' -f $info.Lat, $info.Lon)
            if (-not $script:cache.ContainsKey($ck)) {
                $i++
                if ($i % 10 -eq 0 -or $i -eq $todo) { Write-Progress -Activity '주소 조회 중' -Status "$i / $todo  $($f.Name)" -PercentComplete ([int](100 * $i / [math]::Max($todo, 1))) }
            }
            $addr = Get-Address $info.Lat $info.Lon
            if (-not $addr) {
                if ($nameAddr) { $addr = $nameAddr; $keptName++ }      # 조회 실패: 이름에 있는 주소를 그대로 씀
                else {
                    $la6 = ([double]$info.Lat).ToString('F6', $inv); $lo6 = ([double]$info.Lon).ToString('F6', $inv)
                    $noAddr.Add($f.FullName + "`r`n    좌표: $la6, $lo6`r`n    이유: $($script:lastFail)`r`n    구글맵: https://www.google.com/maps?q=$la6,$lo6`r`n    카카오맵: https://map.kakao.com/link/map/사진,$la6,$lo6")
                    $noAddrShow.Add("    $($f.Name)   $la6, $lo6")
                    continue
                }
            } elseif ($nameAddr -and ($nameAddr -ne $addr)) {
                $fixAddr.Add(("    {0}  ->  {1}" -f $nameAddr, $addr))
            }
        } elseif ($nameAddr) {
            $addr = $nameAddr                                          # GPS는 없지만 이름에 주소가 있음: 그대로 두고 번호만 정리
        } else {
            $skipGps.Add(("{0}`t{1}" -f $info.Status, $f.FullName)); continue
        }
        $recs.Add([pscustomobject]@{ File = $f; Address = $addr; Taken = $info.Taken; Name = $f.Name; Lat = $info.Lat; Lon = $info.Lon; NameCoord = $nameCoord })
    }
    Write-Progress -Activity '주소 조회 중' -Completed

    # ---------- 새 이름 계산 ----------
    $plan = New-Object System.Collections.Generic.List[object]
    $same = 0
    foreach ($g in ($recs | Group-Object -Property Address)) {
        $sorted = @($g.Group | Sort-Object -Property @{ Expression = 'Taken'; Descending = $NewestFirst }, @{ Expression = 'Name'; Descending = $NewestFirst })
        for ($k = 0; $k -lt $sorted.Count; $k++) {
            $r = $sorted[$k]
            $coord = ''
            if ($script:withCoord) {
                if ($null -ne $r.Lat) { $coord = ' ' + ([double]$r.Lat).ToString('F6', $inv) + ', ' + ([double]$r.Lon).ToString('F6', $inv) }
                elseif ($r.NameCoord) { $coord = $r.NameCoord }
            }
            $newName = '{0} ({1}){2}{3}' -f $r.Address, ($k + 1), $coord, $r.File.Extension
            $newPath = Join-Path $r.File.DirectoryName $newName
            if ($newPath -eq $r.File.FullName) { $same++ }
            else { $plan.Add([pscustomobject]@{ From = $r.File.FullName; To = $newPath }) }
        }
    }

    # ---------- 결과 요약 ----------
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    Write-Host ''
    $coordText = if ($script:withCoord) { '넣기' } else { '빼기' }
    Write-Host "[변경 계획] 이름이 바뀔 사진 $($plan.Count)장 (이름에 좌표 $coordText)" -ForegroundColor Green
    if ($same -gt 0) { Write-Host "  이미 올바른 이름 $($same)장" }
    if ($fixAddr.Count -gt 0) {
        Write-Host "  이름의 주소가 사진 위치와 달라 고쳐질 사진 $($fixAddr.Count)장 (현재 이름  ->  바뀔 주소)" -ForegroundColor Yellow
        $fixAddr | Select-Object -First 3 | ForEach-Object { Write-Host $_ }
    }
    if ($keptName -gt 0) { Write-Host "  주소를 못 찾아 현재 이름을 그대로 둔 사진 $($keptName)장" }
    if (($skipGps.Count + $noAddr.Count) -gt 0) { Write-Host "  건너뜀 $($skipGps.Count + $noAddr.Count)장 (GPS 없음 $($skipGps.Count), 주소 못 찾음 $($noAddr.Count))" }
    if ($noAddrShow.Count -gt 0) {
        Write-Host '  주소 못 찾은 사진 (파일명  좌표):' -ForegroundColor Yellow
        $noAddrShow | Select-Object -First 15 | ForEach-Object { Write-Host $_ }
    }
    if ($plan.Count -gt 0) {
        Write-Host '  예시:'
        $plan | Select-Object -First 3 | ForEach-Object {
            Write-Host ('    ' + (Split-Path -Leaf $_.From))
            Write-Host ('    -> ' + (Split-Path -Leaf $_.To)) -ForegroundColor Green
        }
    }
    if (($skipGps.Count + $noAddr.Count) -gt 0) {
        $skipPath = Join-Path $root "건너뜀목록_$stamp.txt"
        $lines = @('[GPS 없음/읽기 실패]') + $skipGps + @('', '[주소 못 찾음]') + $noAddr
        [IO.File]::WriteAllLines($skipPath, $lines, $utf8bom)
        Write-Host ''
        Write-Host "건너뛴 목록: $skipPath"
    }
    if ($plan.Count -eq 0) { Write-Host ''; Write-Host '바꿀 사진이 없습니다.'; return }

    Write-Host ''
    if ((Read-Host '이름을 바꿀까요? (Y=실행, 그 외=취소)') -notmatch '^[Yy]') {
        Write-Host '취소했습니다. (바뀐 파일 없음)'; return
    }

    # ---------- 실행 ----------
    $logPath = Join-Path $root "이름변경로그_$stamp.csv"
    $plan | ForEach-Object { [pscustomobject]@{ OldPath = $_.From; NewPath = $_.To } } | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding UTF8
    $ok = Invoke-Moves $plan
    Write-Host ''
    Write-Host "완료: $ok / $($plan.Count)장 (잘못됐으면 다시 실행해서 2번 되돌리기)" -ForegroundColor Green
}
catch {
    Write-Host ''
    Write-Host "오류: $($_.Exception.Message)" -ForegroundColor Red
    try { Write-Host "  (스크립트 $($_.InvocationInfo.ScriptLineNumber)번째 줄: $($_.InvocationInfo.Line.Trim()))" -ForegroundColor DarkGray } catch { }
}
