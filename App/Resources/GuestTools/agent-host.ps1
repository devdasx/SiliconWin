# SiliconWin host relay. Runs as SYSTEM at startup (scheduled task).
#
# The virtio-serial port "org.siliconwin.agent.0" (the line to SiliconWin on
# the Mac) can only be opened by SYSTEM and elevated administrators. This relay
# owns it and forwards everything to and from the named pipe
# \\.\pipe\SiliconWinAgent, which the per-user agent (agent.ps1) connects to.
$HostVersion = 2
$ErrorActionPreference = 'SilentlyContinue'

# Prefer a newer relay from the SILICONWIN disc (updated with the Mac app).
# This runs as SYSTEM, so only the disc SiliconWin attaches counts (an emulated
# QEMU CD drive labelled SILICONWIN). A disc image or drive that someone mounts
# inside Windows must never be able to run code as SYSTEM.
if (-not $env:SILICONWIN_HOST_CHILD) {
    $discs = Get-CimInstance Win32_CDROMDrive |
        Where-Object { $_.Drive -and $_.VolumeName -eq 'SILICONWIN' -and $_.PNPDeviceID -match 'QEMU' }
    foreach ($disc in $discs) {
        $candidate = Join-Path ($disc.Drive + '\') 'SiliconWin\agent-host.ps1'
        if ($candidate -ne $PSCommandPath -and (Test-Path $candidate)) {
            $line = Select-String -Path $candidate -Pattern '^\$HostVersion = (\d+)' | Select-Object -First 1
            if ($line -and [int]$line.Matches[0].Groups[1].Value -gt $HostVersion) {
                $env:SILICONWIN_HOST_CHILD = '1'
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $candidate
                exit
            }
        }
    }
}

$logFile = Join-Path $env:ProgramData 'SiliconWin\host.log'
New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null

Add-Type -ReferencedAssemblies System.Core -TypeDefinition @"
using System;
using System.IO;
using System.IO.Pipes;
using System.Threading;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

public static class SiliconWinRelay {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security,
                                            uint disposition, uint flags, IntPtr template);

    static volatile NamedPipeServerStream client;
    static string logPath;

    static void Log(string text) {
        try { File.AppendAllText(logPath, DateTime.Now.ToString("u") + " " + text + Environment.NewLine); } catch { }
    }

    static FileStream OpenPort(string path) {
        while (true) {
            // GENERIC_READ | GENERIC_WRITE, OPEN_EXISTING, FILE_FLAG_OVERLAPPED
            SafeFileHandle handle = CreateFile(path, 0xC0000000, 0, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
            if (!handle.IsInvalid) return new FileStream(handle, FileAccess.ReadWrite, 4096, true);
            Log("cannot open " + path + " (Win32 error " + Marshal.GetLastWin32Error() + "), retrying");
            Thread.Sleep(5000);
        }
    }

    public static void Run(string portPath, string pipeName, string log) {
        logPath = log;
        FileStream port = OpenPort(portPath);
        Log("serial port open");

        // Mac -> Windows: forward to the connected session agent (if any).
        Thread reader = new Thread(delegate () {
            byte[] buffer = new byte[65536];
            while (true) {
                int count;
                try { count = port.Read(buffer, 0, buffer.Length); }
                catch (Exception e) { Log("port read failed: " + e.Message); Thread.Sleep(1000); continue; }
                if (count <= 0) { Thread.Sleep(50); continue; }
                NamedPipeServerStream c = client;
                if (c != null) { try { c.Write(buffer, 0, count); c.Flush(); } catch { } }
            }
        });
        reader.IsBackground = true;
        reader.Start();

        PipeSecurity security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null),
                                                  PipeAccessRights.ReadWrite, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                                                  PipeAccessRights.FullControl, AccessControlType.Allow));

        // Windows -> Mac: one session agent at a time.
        byte[] upward = new byte[65536];
        while (true) {
            NamedPipeServerStream pipe = null;
            try {
                pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                                                 PipeOptions.Asynchronous, 65536, 65536, security);
                pipe.WaitForConnection();
                Log("session agent connected");
                client = pipe;
                int count;
                while ((count = pipe.Read(upward, 0, upward.Length)) > 0) {
                    port.Write(upward, 0, count);
                    port.Flush();
                }
            } catch (Exception e) {
                Log("pipe: " + e.Message);
                Thread.Sleep(1000);
            }
            client = null;
            if (pipe != null) { try { pipe.Dispose(); } catch { } }
            Log("session agent disconnected");
        }
    }
}
"@

[SiliconWinRelay]::Run('\\.\Global\org.siliconwin.agent.0', 'SiliconWinAgent', $logFile)
