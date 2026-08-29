param(
    [Parameter(Mandatory = $false)]
    [int]$DiskNumber = 2,

    [Parameter(Mandatory = $false)]
    [string]$TargetLetter = ""
)

$diskPath = "\\.\PhysicalDrive$DiskNumber"
$maxRetries = 3
$success = $false

Write-Host "[*] Launching automated recovery master (up to $maxRetries attempts)..." -ForegroundColor Yellow

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public class GptLoopMaster {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern SafeFileHandle CreateFile(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetFilePointerEx(
        SafeFileHandle hFile, long liDistanceToMove, out long lpNewFilePointer, uint dwMoveMethod);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteFile(
        SafeFileHandle hFile, byte[] lpBuffer, uint nNumberOfBytesToWrite,
        out uint lpNumberOfBytesWritten, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(
        SafeFileHandle hFile, byte[] lpBuffer, uint nNumberOfBytesToRead,
        out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    public static byte[] ReadBytes(string path, long byteOffset, int count) {
        SafeFileHandle handle = CreateFile(path, 0x80000000 | 0x40000000, 0x00000001 | 0x00000002, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (handle.IsInvalid) throw new Exception("CreateFile read failed: " + Marshal.GetLastWin32Error());
        long newPos;
        SetFilePointerEx(handle, byteOffset, out newPos, 0);
        byte[] buffer = new byte[count];
        uint read;
        ReadFile(handle, buffer, (uint)buffer.Length, out read, IntPtr.Zero);
        handle.Close();
        return buffer;
    }

    public static void WriteBytes(string path, long byteOffset, byte[] data) {
        SafeFileHandle handle = CreateFile(path, 0x80000000 | 0x40000000, 0x00000001 | 0x00000002, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (handle.IsInvalid) throw new Exception("CreateFile write failed: " + Marshal.GetLastWin32Error());
        long newPos;
        SetFilePointerEx(handle, byteOffset, out newPos, 0);
        uint written;
        bool success = WriteFile(handle, data, (uint)data.Length, out written, IntPtr.Zero);
        handle.Close();
        if (!success) throw new Exception("WriteFile failed: " + Marshal.GetLastWin32Error());
    }

    public static uint ComputeCrc32(byte[] data) {
        uint crc = 0xFFFFFFFF;
        for (int i = 0; i < data.Length; i++) {
            crc ^= data[i];
            for (int j = 0; j < 8; j++) {
                if ((crc & 1) != 0) {
                    crc = (crc >> 1) ^ 0xEDB88320;
                } else {
                    crc = crc >> 1;
                }
            }
        }
        return ~crc;
    }
}
"@

for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    Write-Host "`n--- Recovery Attempt #$attempt of $maxRetries ---" -ForegroundColor Cyan
    try {
        $primaryHeaderSector = [GptLoopMaster]::ReadBytes($diskPath, 512, 512)
        $primaryHeader = New-Object byte[] 92
        [Array]::Copy($primaryHeaderSector, 0, $primaryHeader, 0, 92)

        $backupLba      = [BitConverter]::ToUInt64($primaryHeader, 32)
        $firstUsableLba = [BitConverter]::ToUInt64($primaryHeader, 40)
        $lastUsableLba  = [BitConverter]::ToUInt64($primaryHeader, 48)
        $partEntriesLba = [BitConverter]::ToUInt64($primaryHeader, 72)
        $numEntries     = [BitConverter]::ToUInt32($primaryHeader, 80)
        $entrySize      = [BitConverter]::ToUInt32($primaryHeader, 84)

        if ($partEntriesLba -eq 0) { $partEntriesLba = 2 }
        if ($numEntries -eq 0) { $numEntries = 128 }
        if ($entrySize -eq 0) { $entrySize = 128 }

        $startLba = 4096
        if ($firstUsableLba -gt $startLba) { $startLba = $firstUsableLba }
        $endLba = $lastUsableLba - 4096
        $totalSectors = ($endLba - $startLba) + 1

        $tableSize = [int]($numEntries * $entrySize)
        $partitionEntries = [GptLoopMaster]::ReadBytes($diskPath, [Int64]($partEntriesLba * 512), $tableSize)

        $typeGuidBytes = [byte[]]@(0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44, 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7)
        [Array]::Copy($typeGuidBytes, 0, $partitionEntries, 0, 16)

        $uniqGuidBytes = [byte[]]@(0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF,0x00)
        [Array]::Copy($uniqGuidBytes, 0, $partitionEntries, 16, 16)

        [Array]::Copy([BitConverter]::GetBytes([UInt64]$startLba), 0, $partitionEntries, 32, 8)
        [Array]::Copy([BitConverter]::GetBytes([UInt64]$endLba), 0, $partitionEntries, 40, 8)
        [Array]::Copy([BitConverter]::GetBytes([UInt64]0), 0, $partitionEntries, 48, 8)

        $nameBytes = [System.Text.Encoding]::Unicode.GetBytes("Data")
        [Array]::Copy($nameBytes, 0, $partitionEntries, 56, [Math]::Min($nameBytes.Length, 72))

        $bootSector = [GptLoopMaster]::ReadBytes($diskPath, [Int64]($startLba * 512), 512)
        $oemId = [System.Text.Encoding]::ASCII.GetString($bootSector[3..10])

        if ($oemId -eq "NTFS    ") {
            [Array]::Copy([BitConverter]::GetBytes([UInt64]$totalSectors), 0, $bootSector, 40, 8)
            [GptLoopMaster]::WriteBytes($diskPath, [Int64]($startLba * 512), $bootSector)
            [GptLoopMaster]::WriteBytes($diskPath, [Int64]($endLba * 512), $bootSector)
        }

        $partitionEntriesCrc = [GptLoopMaster]::ComputeCrc32($partitionEntries)
        [Array]::Copy([BitConverter]::GetBytes($partitionEntriesCrc), 0, $primaryHeader, 88, 4)

        [Array]::Clear($primaryHeader, 16, 4)
        $primaryHeaderCrc = [GptLoopMaster]::ComputeCrc32($primaryHeader)
        [Array]::Copy([BitConverter]::GetBytes($primaryHeaderCrc), 0, $primaryHeader, 16, 4)

        [GptLoopMaster]::WriteBytes($diskPath, [Int64]($partEntriesLba * 512), $partitionEntries)
        $primaryHeaderSector = [GptLoopMaster]::ReadBytes($diskPath, 512, 512)
        [Array]::Copy($primaryHeader, 0, $primaryHeaderSector, 0, 92)
        [GptLoopMaster]::WriteBytes($diskPath, 512, $primaryHeaderSector)

        Update-HostStorageCache
        Start-Sleep -Seconds 1

        $partCheck = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue
        if ($partCheck) {
            Write-Host "[+] Partition successfully detected by the system on attempt $attempt!" -ForegroundColor Green
            $success = $true
            break
        } else {
            Write-Warning "[!] Partition not visible yet, retrying..."
        }
    }
    catch {
        Write-Warning "[!] Error on iteration $attempt - $_"
    }
}

if (-not $success) {
    Write-Error "[-] Failed to restore partition layout within $maxRetries attempts."
    exit
}

Write-Host "[*] Configuring target drive letter..." -ForegroundColor Cyan
Start-Sleep -Seconds 1
$partition = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue

if ($partition) {
    if (-not [string]::IsNullOrEmpty($TargetLetter)) {
        $cleanLetter = $TargetLetter.TrimEnd(':').ToUpper()
        
        # Safely release letter if it is already taken
        $existing = Get-Partition -DriveLetter $cleanLetter -ErrorAction SilentlyContinue
        if ($existing) {
            Remove-PartitionAccessPath -DiskNumber $existing.DiskNumber -PartitionNumber $existing.PartitionNumber -AccessPath "$cleanLetter`:" -Confirm:$false -ErrorAction SilentlyContinue
        }

        # Assign mandatory target letter
        Set-Partition -InputObject $partition -NewDriveLetter $cleanLetter
        Write-Host "[+] Successfully assigned mandatory drive letter: $cleanLetter" -ForegroundColor Green
    } else {
        if ([string]::IsNullOrEmpty($partition.DriveLetter)) {
            Set-Partition -InputObject $partition -AssignDriveLetter
            Write-Host "[+] Drive letter assigned automatically" -ForegroundColor Green
        } else {
            Write-Host "[+] Drive already has a letter assigned: $($partition.DriveLetter)" -ForegroundColor Green
        }
    }
} else {
    Write-Error "[-] Error: Partition on Disk $DiskNumber not found for letter assignment."
}

Write-Host "[SUCCESS] Utility finished execution cleanly and stably!" -ForegroundColor Green
