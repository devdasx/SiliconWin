# SiliconWin guest agent (runs in the user's session, without elevation).
# Talks to SiliconWin on the Mac through the host relay (agent-host.ps1, which
# owns the virtio-serial port) over \\.\pipe\SiliconWinAgent: announces itself, keeps the clipboard (text) in
# sync in both directions and receives files dropped onto the Windows screen
# (saved to Desktop\From Mac). Messages are single lines: "<command> <base64>".

$AgentVersion = 5
$ErrorActionPreference = 'SilentlyContinue'

# Prefer a newer agent from the SILICONWIN disc (SiliconWin updates the disc
# whenever the Mac app is updated), so no admin rights are needed to update.
# Only the disc SiliconWin attaches counts (an emulated QEMU CD drive labelled
# SILICONWIN); drives and disc images mounted inside Windows are ignored.
if (-not $env:SILICONWIN_AGENT_CHILD) {
    $discs = Get-CimInstance Win32_CDROMDrive |
        Where-Object { $_.Drive -and $_.VolumeName -eq 'SILICONWIN' -and $_.PNPDeviceID -match 'QEMU' }
    foreach ($disc in $discs) {
        $candidate = Join-Path ($disc.Drive + '\') 'SiliconWin\agent.ps1'
        if ($candidate -ne $PSCommandPath -and (Test-Path $candidate)) {
            $line = Select-String -Path $candidate -Pattern '^\$AgentVersion = (\d+)' | Select-Object -First 1
            if ($line -and [int]$line.Matches[0].Groups[1].Value -gt $AgentVersion) {
                $env:SILICONWIN_AGENT_CHILD = '1'
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $candidate
                exit
            }
        }
    }
}

$logFile = Join-Path $env:LOCALAPPDATA 'SiliconWin\agent.log'
New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null
function Log([string] $text) { Add-Content -Path $logFile -Value ("{0:u} {1}" -f (Get-Date), $text) }
Log "agent $AgentVersion starting (elevated: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')))"

Add-Type -AssemblyName System.Windows.Forms

Add-Type -ReferencedAssemblies System.Core -TypeDefinition @"
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Collections.Concurrent;

public class SiliconWinPort {
    Stream stream;
    readonly object sendLock = new object();
    public readonly ConcurrentQueue<string> Incoming = new ConcurrentQueue<string>();
    public volatile bool Connected;
    public string LastError;

    // Files dropped onto the Windows screen on the Mac arrive here.
    public string DropFolder;
    FileStream incomingFile;
    string incomingPath;

    public bool Open(string pipeName) {
        try {
            NamedPipeClientStream pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            pipe.Connect(3000);
            stream = pipe;
        } catch (Exception e) {
            LastError = e.Message;
            return false;
        }
        Connected = true;
        Thread reader = new Thread(ReadLoop);
        reader.IsBackground = true;
        reader.Start();
        return true;
    }

    void ReadLoop() {
        byte[] buffer = new byte[65536];
        MemoryStream line = new MemoryStream();
        try {
            while (true) {
                int count = stream.Read(buffer, 0, buffer.Length);
                if (count <= 0) break;   // relay closed the pipe
                for (int i = 0; i < count; i++) {
                    if (buffer[i] == 10) {
                        Handle(Encoding.UTF8.GetString(line.ToArray()).Trim());
                        line.SetLength(0);
                    } else {
                        line.WriteByte(buffer[i]);
                    }
                }
            }
        } catch (Exception) { }
        Connected = false;
    }

    public bool Send(string text) {
        try {
            byte[] bytes = Encoding.UTF8.GetBytes(text + "\n");
            lock (sendLock) {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush();
            }
            return true;
        } catch (Exception) {
            return false;
        }
    }

    static string Encode(string text) { return Convert.ToBase64String(Encoding.UTF8.GetBytes(text)); }
    static string Decode(string data) { return Encoding.UTF8.GetString(Convert.FromBase64String(data)); }

    // File transfers are handled right here on the reader thread (fast);
    // everything else goes to the PowerShell loop.
    void Handle(string line) {
        try {
            if (line.StartsWith("file-begin ")) {
                string[] parts = line.Split(' ');
                string name = Path.GetFileName(Decode(parts[1]));
                Directory.CreateDirectory(DropFolder);
                string target = Path.Combine(DropFolder, name);
                string stem = Path.GetFileNameWithoutExtension(name), ext = Path.GetExtension(name);
                for (int n = 2; File.Exists(target); n++) target = Path.Combine(DropFolder, stem + " (" + n + ")" + ext);
                if (incomingFile != null) incomingFile.Close();
                incomingFile = new FileStream(target, FileMode.CreateNew, FileAccess.Write);
                incomingPath = target;
            } else if (line.StartsWith("file-data ")) {
                if (incomingFile != null) {
                    byte[] data = Convert.FromBase64String(line.Substring(10));
                    incomingFile.Write(data, 0, data.Length);
                }
            } else if (line == "file-end") {
                if (incomingFile != null) {
                    incomingFile.Close();
                    incomingFile = null;
                    Send("file-done " + Encode(Path.GetFileName(incomingPath)));
                }
            } else if (line == "file-cancel") {
                if (incomingFile != null) {
                    incomingFile.Close();
                    incomingFile = null;
                    File.Delete(incomingPath);
                }
            } else {
                Incoming.Enqueue(line);
            }
        } catch (Exception e) {
            if (incomingFile != null) { incomingFile.Close(); incomingFile = null; }
            Send("file-error " + Encode(e.Message));
        }
    }
}
"@

function Encode([string] $text) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) }
function Decode([string] $data) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data)) }

$path = 'SiliconWinAgent'   # named pipe served by agent-host.ps1
$dropFolder = Join-Path ([Environment]::GetFolderPath('Desktop')) 'From Mac'
$port = New-Object SiliconWinPort
if (-not $port) { Log "could not compile the serial port helper: $($Error[0])"; exit 1 }
$port.DropFolder = $dropFolder
while (-not $port.Open($path)) { Log "cannot reach the host relay: $($port.LastError)"; Start-Sleep -Seconds 5 }
Log "connected to the Mac"
$port.Send("hello $AgentVersion $env:COMPUTERNAME") | Out-Null

$lastClipboard = $null
try { $lastClipboard = [System.Windows.Forms.Clipboard]::GetText() } catch { }

while ($true) {
    $line = $null
    while ($port.Incoming.TryDequeue([ref] $line)) {
        $parts = $line.Split(' ', 2)
        switch ($parts[0]) {
            'clipboard' {
                $text = ''
                if ($parts.Count -gt 1) { $text = Decode $parts[1] }
                $lastClipboard = $text
                try {
                    if ($text.Length -gt 0) { [System.Windows.Forms.Clipboard]::SetText($text) }
                } catch { }
            }
            'ping' { $port.Send('pong') | Out-Null }
        }
    }

    try {
        $current = [System.Windows.Forms.Clipboard]::GetText()
        if ($current -ne $null -and $current -ne $lastClipboard -and $current.Length -le 4000000) {
            $lastClipboard = $current
            $port.Send('clipboard ' + (Encode $current)) | Out-Null
        }
    } catch { }

    if (-not $port.Connected) {
        Start-Sleep -Seconds 3
        $port = New-Object SiliconWinPort
        $port.DropFolder = $dropFolder
        while (-not $port.Open($path)) { Start-Sleep -Seconds 5 }
        $port.Send("hello $AgentVersion $env:COMPUTERNAME") | Out-Null
    }
    Start-Sleep -Milliseconds 400
}
