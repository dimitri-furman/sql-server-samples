#Requires -Version 7.0
<#
.SYNOPSIS
  Loads Invoke-ShrinkDriver, a command that reclaims allocated but unused space from
  a MSSQL database's data files by running DBCC SHRINKFILE commands in parallel on
  multiple sessions.

.DESCRIPTION
  Dot-source this file to define the command, then call it:

    . .\ShrinkDriver.ps1
    Invoke-ShrinkDriver -ServerName <server> -DatabaseName <database>

  Requires PowerShell 7 or later. Depends on the SqlServer module
  (Install-Module SqlServer -Scope CurrentUser). See the README for the full list.

  Run 'Get-Help Invoke-ShrinkDriver -Full' for the description, parameters, and examples.
#>

Set-StrictMode -Version Latest

function Invoke-ShrinkDriver {
    <#
    .SYNOPSIS
      Reclaims unused space from a database's data files by running several
      DBCC SHRINKFILE operations in parallel, with progress monitoring and retries.
    .DESCRIPTION
      Connects to the target database, shrinks each eligible data file toward the
      requested size in steps using multiple concurrent sessions, and writes a status
      report to the console and a log file at a regular interval.

      Requires PowerShell 7 or later and membership in the
      db_owner database role. Supported platforms: SQL Server 2022 or later, Azure SQL
      Managed Instance, and Azure SQL Database.

      Entra ID authentication uses the ambient Azure credential (managed identity,
      Azure CLI, Azure PowerShell, Visual Studio, or an interactive browser prompt);
      for an interactive sign-in, run Connect-AzAccount first.

      Dependencies: the SqlServer module.
    .PARAMETER ServerName
      Target SQL Server / Azure SQL logical server name.
    .PARAMETER DatabaseName
      Target database name.
    .PARAMETER AuthType
      Authentication method: EntraID (default), Windows, or SQL.
    .PARAMETER SqlLogin
      Login name; required when AuthType is SQL.
    .PARAMETER SqlPassword
      Password as a SecureString; required when AuthType is SQL.
    .PARAMETER Sessions
      Number of files to shrink concurrently (default 5). Capped at the eligible file count.
    .PARAMETER TruncateOnly
      Release free space at the end of each file only, without moving data.
    .PARAMETER NoTruncate
      Compact each file without releasing the freed space.
    .PARAMETER WaitAtLowPriority
      Run shrink at low lock priority to reduce blocking of other queries (default true).
    .PARAMETER AbortAfterWait
      On a low-priority wait timeout, abort this shrink (SELF, default) or kill the
      blocking sessions (BLOCKERS). BLOCKERS terminates other transactions, use with caution.
    .PARAMETER FileTargetSizeGB
      Optional per-file floor in GB; no file is shrunk below this size.
    .PARAMETER RetryCount
      Retry attempts per file for transient failures (default 5, maximum 50).
    .PARAMETER MaxRuntimeMinutes
      Optional overall time budget; the run stops when it is reached.
    .PARAMETER StepGB
      Increment size used for gradual shrinking (default 10 GB).
    .PARAMETER StatusIntervalSeconds
      How often the status report is written, in seconds (default 180).
    .PARAMETER StuckWindowSeconds
      A shrink blocked with no progress for this long is cancelled and retried (default 300).
    .PARAMETER LogPath
      Log file path. Defaults to a timestamped file next to this script.
    .EXAMPLE
      Invoke-ShrinkDriver -ServerName myserver.database.windows.net -DatabaseName MyDb -Sessions 5
    .EXAMPLE
      Invoke-ShrinkDriver -ServerName sql01 -DatabaseName Sales -AuthType Windows -FileTargetSizeGB 500 -Sessions 8
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$DatabaseName,

        [ValidateSet('EntraID', 'Windows', 'SQL')][string]$AuthType = 'EntraID',
        [string]$SqlLogin,
        [securestring]$SqlPassword,

        [int]$Sessions = 5,
        [switch]$TruncateOnly,
        [switch]$NoTruncate,
        [bool]$WaitAtLowPriority = $true,
        [ValidateSet('SELF', 'BLOCKERS')][string]$AbortAfterWait = 'SELF',

        [Nullable[int]]$FileTargetSizeGB = $null,
        [int]$RetryCount = 5,
        [Nullable[int]]$MaxRuntimeMinutes = $null,

        [int]$StepGB = 10,
        [int]$StatusIntervalSeconds = 180,
        [int]$StuckWindowSeconds = 300,
        [string]$LogPath
    )

    $ErrorActionPreference = 'Stop'
    $selfPath = $PSCommandPath
    $hasTarget = $null -ne $FileTargetSizeGB

    # ----- validate parameters -----
    $paramSet = @{
        AuthType = $AuthType; SqlLogin = $SqlLogin; SqlPassword = $SqlPassword
        Sessions = $Sessions; TruncateOnly = [bool]$TruncateOnly; NoTruncate = [bool]$NoTruncate
        WaitAtLowPriority = $WaitAtLowPriority; AbortAfterWait = $AbortAfterWait
        FileTargetSizeGB = $(if ($hasTarget) { [int]$FileTargetSizeGB } else { $null })
    }
    $validationErrors = Test-ShrinkParameterSet -Params $paramSet
    if ($validationErrors.Count -gt 0) {
        $validationErrors | ForEach-Object { Write-Error $_ }
        throw "Parameter validation failed with $($validationErrors.Count) error(s)."
    }
    $RetryCount = Get-ShrinkClampedRetryCount -RetryCount $RetryCount
    $stepMB = [long]$StepGB * 1024
    $floorMB = if ($hasTarget) { [long]$FileTargetSizeGB * 1024 } else { $null }

    # ----- logging (console + mirrored file) -----
    if (-not $LogPath) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $safeServer = ($ServerName -replace '[^\w.-]', '_')
        $LogPath = Join-Path $PSScriptRoot ("shrink-{0}-{1}-{2}.log" -f $safeServer, $DatabaseName, $stamp)
    }
    $logLock = [object]::new()
    function Write-ShrinkLog {
        param([string]$Message, [string]$Level = 'INFO')
        $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
        [System.Threading.Monitor]::Enter($logLock)
        try { Write-Host $line; Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8 }
        finally { [System.Threading.Monitor]::Exit($logLock) }
    }

    @(
        '==================== ShrinkDriver run ===================='
        "Server           : $ServerName"
        "Database         : $DatabaseName"
        "AuthType         : $AuthType" + $(if ($AuthType -eq 'SQL') { " (login $SqlLogin)" } else { '' })
        "Sessions         : $Sessions"
        "TruncateOnly     : $([bool]$TruncateOnly)"
        "NoTruncate       : $([bool]$NoTruncate)"
        "WaitAtLowPriority: $WaitAtLowPriority"
        "AbortAfterWait   : $AbortAfterWait"
        "FileTargetSizeGB : $(if ($hasTarget) { [int]$FileTargetSizeGB } else { '(min possible)' })"
        "StepGB           : $StepGB"
        "RetryCount       : $RetryCount"
        "MaxRuntimeMinutes: $(if ($null -ne $MaxRuntimeMinutes) { [int]$MaxRuntimeMinutes } else { '(none)' })"
        "StatusInterval   : $StatusIntervalSeconds s"
        "LogFile          : $LogPath"
        '=========================================================='
    ) | ForEach-Object { Write-ShrinkLog $_ }
    if ($WaitAtLowPriority -and $AbortAfterWait -eq 'BLOCKERS') {
        Write-ShrinkLog 'AbortAfterWait=BLOCKERS will roll back transactions that block shrink. Use with caution.' 'WARN'
    }

    # ----- connection helpers -----
    # The Microsoft.Data.SqlClient types come from the SqlServer module. Import it on
    # demand; if it is not installed, stop with instructions to install it.
    if (-not ('Microsoft.Data.SqlClient.SqlConnection' -as [type])) {
        if (-not (Get-Module -ListAvailable -Name SqlServer)) {
            throw "The 'SqlServer' module is required but not installed. Install it with " +
                  "'Install-Module SqlServer -Scope CurrentUser' (needs PowerShell 7 or later), then retry."
        }
        Import-Module SqlServer -ErrorAction Stop
    }
    function New-ShrinkConnection {
        $csb = [Microsoft.Data.SqlClient.SqlConnectionStringBuilder]::new()
        $csb['Data Source'] = $ServerName; $csb['Initial Catalog'] = $DatabaseName
        $csb['Encrypt'] = $true; $csb['Connect Timeout'] = 30; $csb['Application Name'] = 'ShrinkDriver'
        $conn = [Microsoft.Data.SqlClient.SqlConnection]::new()
        switch ($AuthType) {
            'Windows' { $csb['Integrated Security'] = $true; $conn.ConnectionString = $csb.ConnectionString }
            'SQL' {
                $conn.ConnectionString = $csb.ConnectionString
                $pw = $SqlPassword.Copy(); $pw.MakeReadOnly()
                $conn.Credential = [Microsoft.Data.SqlClient.SqlCredential]::new($SqlLogin, $pw)
            }
            # EntraID: Microsoft.Data.SqlClient acquires the token from the ambient Azure
            # credential and negotiates the correct authority for the target Azure cloud.
            default { $csb['Authentication'] = 'Active Directory Default'; $conn.ConnectionString = $csb.ConnectionString }
        }
        $conn.Open(); $conn
    }
    function Invoke-ShrinkScalar {
        param([Microsoft.Data.SqlClient.SqlConnection]$Conn, [string]$Sql, [int]$TimeoutSec = 30)
        $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = $TimeoutSec
        try { $cmd.ExecuteScalar() } finally { $cmd.Dispose() }
    }

    # ----- pre-flight -----
    $control = New-ShrinkConnection
    Write-ShrinkLog "Connected to [$DatabaseName] on [$ServerName]."

    # Supported platforms only: SQL Server 2022 or later, Azure SQL Database, and
    # Azure SQL Managed Instance.
    $engineEdition = [int](Invoke-ShrinkScalar $control "SELECT CAST(SERVERPROPERTY('EngineEdition') AS int);")
    $majorVersion = [int](Invoke-ShrinkScalar $control "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int);")
    $isAzureDbOrMi = $engineEdition -in @(5, 8)
    if (-not $isAzureDbOrMi -and $majorVersion -lt 16) {
        throw "ShrinkDriver supports only SQL Server 2022 or later, Azure SQL Database, and Azure SQL Managed Instance. Detected major version $majorVersion (EngineEdition $engineEdition), which is not supported."
    }
    $hasPerm = [int](Invoke-ShrinkScalar $control "SELECT CASE WHEN IS_ROLEMEMBER('db_owner') = 1 OR IS_SRVROLEMEMBER('sysadmin') = 1 THEN 1 ELSE 0 END;")
    if ($hasPerm -ne 1) { throw "The login must be a member of db_owner on [$DatabaseName] or sysadmin." }
    $autoShrink = [int](Invoke-ShrinkScalar $control "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(), 'IsAutoShrink') AS int);")
    if ($autoShrink -eq 1) {
        throw "AUTO_SHRINK is ON for [$DatabaseName]. Disable it (ALTER DATABASE ... SET AUTO_SHRINK OFF) before running ShrinkDriver."
    }

    function Get-EligibleFiles {
        param([Microsoft.Data.SqlClient.SqlConnection]$Conn)
        $sql = @'
SELECT df.file_id, df.name,
       CAST(df.size / 128.0 AS bigint)                            AS alloc_mb,
       CAST(FILEPROPERTY(df.name, 'SpaceUsed') / 128.0 AS bigint) AS used_mb
FROM sys.database_files df
JOIN sys.filegroups fg ON df.data_space_id = fg.data_space_id
WHERE df.type_desc = 'ROWS' AND df.state_desc = 'ONLINE' AND fg.is_read_only = 0
ORDER BY (df.size - CAST(FILEPROPERTY(df.name, 'SpaceUsed') AS bigint)) DESC;
'@
        $cmd = $Conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 120
        $rd = $cmd.ExecuteReader()
        $files = [System.Collections.Generic.List[object]]::new()
        try {
            while ($rd.Read()) {
                $files.Add([pscustomobject]@{
                        FileId = [int]$rd['file_id']; Name = [string]$rd['name']
                        AllocatedMB = [long]$rd['alloc_mb']; UsedMB = [long]$rd['used_mb']; FloorMB = $floorMB
                    })
            }
        } finally { $rd.Dispose(); $cmd.Dispose() }
        $files
    }

    $allFiles = Get-EligibleFiles -Conn $control
    $eligible = $allFiles | Where-Object { ($_.AllocatedMB - $_.UsedMB) -gt 0 -and ($null -eq $floorMB -or $_.AllocatedMB -gt $floorMB) }
    Write-ShrinkLog ("Eligible data files: {0} of {1}. Total allocated {2} GB, used {3} GB." -f `
            $eligible.Count, $allFiles.Count,
        [math]::Round((($allFiles | Measure-Object AllocatedMB -Sum).Sum) / 1024, 1),
        [math]::Round((($allFiles | Measure-Object UsedMB -Sum).Sum) / 1024, 1))
    if ($eligible.Count -eq 0) { Write-ShrinkLog 'No files have reclaimable space above the target. Nothing to do.'; $control.Close(); return }
    $effectiveSessions = [Math]::Min($Sessions, $eligible.Count)
    if ($effectiveSessions -lt $Sessions) {
        Write-ShrinkLog ("Capping concurrency to {0} (eligible file count) from requested {1}." -f $effectiveSessions, $Sessions) 'WARN'
    }

    # ----- shared state -----
    $shared = [hashtable]::Synchronized(@{})
    $shared.Files = [System.Collections.Generic.List[object]]::new(); $eligible | ForEach-Object { $shared.Files.Add($_) }
    # GivenUp: files not attempted again this run (cannot shrink further, retries
    # exhausted, or no size reduction).
    $shared.Owned = @{}; $shared.GivenUp = @{}; $shared.Done = @{}; $shared.Sessions = @{}
    $shared.Events = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $shared.Stop = $false; $shared.Lock = [object]::new()

    $connParams = @{
        Server = $ServerName; Database = $DatabaseName; AuthType = $AuthType
        SqlLogin = $SqlLogin; SqlPassword = $SqlPassword
        TruncateOnly = [bool]$TruncateOnly; NoTruncate = [bool]$NoTruncate
        Wlp = [bool]$WaitAtLowPriority; AbortAfterWait = $AbortAfterWait
        FloorMB = $floorMB; StepMB = $stepMB; RetryCount = $RetryCount
    }

    $workerScript = {
        param($workerId, $shared, $selfPath, $connParams)
        . $selfPath
        Set-StrictMode -Version Latest

        function New-WConn {
            $csb = [Microsoft.Data.SqlClient.SqlConnectionStringBuilder]::new()
            $csb['Data Source'] = $connParams.Server; $csb['Initial Catalog'] = $connParams.Database
            $csb['Encrypt'] = $true; $csb['Connect Timeout'] = 30; $csb['Application Name'] = "ShrinkDriver-w$workerId"
            $c = [Microsoft.Data.SqlClient.SqlConnection]::new()
            switch ($connParams.AuthType) {
                'Windows' { $csb['Integrated Security'] = $true; $c.ConnectionString = $csb.ConnectionString }
                'SQL' {
                    $c.ConnectionString = $csb.ConnectionString
                    $pw = $connParams.SqlPassword.Copy(); $pw.MakeReadOnly()
                    $c.Credential = [Microsoft.Data.SqlClient.SqlCredential]::new($connParams.SqlLogin, $pw)
                }
                default { $csb['Authentication'] = 'Active Directory Default'; $c.ConnectionString = $csb.ConnectionString }
            }
            $c.Open(); $c
        }
        function Emit($msg) { $shared.Events.Enqueue(('w{0}: {1}' -f $workerId, $msg)) }
        function Get-Size($conn, $fileId) {
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT CAST(size/128.0 AS bigint) AS a, CAST(FILEPROPERTY(name,'SpaceUsed')/128.0 AS bigint) AS u FROM sys.database_files WHERE file_id = $fileId;"
            $rd = $cmd.ExecuteReader()
            try { if ($rd.Read()) { @{ Alloc = [long]$rd['a']; Used = [long]$rd['u'] } } else { $null } }
            finally { $rd.Dispose(); $cmd.Dispose() }
        }

        $conn = New-WConn
        $spidCmd = $conn.CreateCommand(); $spidCmd.CommandText = 'SELECT @@SPID'
        $spid = [int]$spidCmd.ExecuteScalar(); $spidCmd.Dispose()
        $shared.Sessions[$workerId] = @{ Spid = $spid; Command = $null; FileId = $null; State = 'Idle' }
        Emit "Connected (session ID $spid)"

        try {
            while (-not $shared.Stop) {
                $file = $null
                [System.Threading.Monitor]::Enter($shared.Lock)
                try {
                    $file = Select-ShrinkNextFile -Files $shared.Files.ToArray() `
                        -OwnedFileIds ([int[]]$shared.Owned.Keys) -GivenUpFileIds ([int[]]$shared.GivenUp.Keys)
                    if ($file) { $shared.Owned[$file.FileId] = $workerId }
                } finally { [System.Threading.Monitor]::Exit($shared.Lock) }
                if (-not $file) { break }

                $shared.Sessions[$workerId].FileId = $file.FileId
                $shared.Sessions[$workerId].State = 'Shrinking'
                Emit "Start file $($file.FileId) [$($file.Name)]"

                $attempt = 0; $givenUp = $false
                while (-not $shared.Stop) {
                    $sz = Get-Size $conn $file.FileId
                    if (-not $sz) { break }

                    if ($connParams.TruncateOnly) {
                        $sql = New-ShrinkCommandText -FileId $file.FileId -TruncateOnly `
                            -WaitAtLowPriority:$connParams.Wlp -AbortAfterWait $connParams.AbortAfterWait
                    } else {
                        $next = Get-ShrinkNextTargetMB -AllocatedMB $sz.Alloc -UsedMB $sz.Used -FloorMB $connParams.FloorMB -StepMB $connParams.StepMB
                        if ($next.Done) {
                            $why = if ($next.Reason -eq 'AtOrBelowFloor') { 'reached target size' } else { 'no further reduction possible' }
                            Emit "File $($file.FileId) done ($why) at $([math]::Round($sz.Alloc/1024,1)) GB"; break
                        }
                        $sql = New-ShrinkCommandText -FileId $file.FileId -TargetMB $next.TargetMB `
                            -NoTruncate:$connParams.NoTruncate -WaitAtLowPriority:$connParams.Wlp -AbortAfterWait $connParams.AbortAfterWait
                    }

                    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 0
                    $shared.Sessions[$workerId].Command = $cmd
                    $before = $sz.Alloc
                    try {
                        [void]$cmd.ExecuteNonQuery()
                        $after = (Get-Size $conn $file.FileId).Alloc
                        if ($connParams.TruncateOnly) { Emit "File $($file.FileId) truncated to $([math]::Round($after/1024,1)) GB"; break }
                        if ($after -ge $before) {
                            $attempt++
                            if ($attempt -gt $connParams.RetryCount) {
                                $shared.GivenUp[$file.FileId] = "plateau (no size reduction after $($connParams.RetryCount) retries) at $([math]::Round($after/1024,1)) GB"
                                Emit "Gave up on file $($file.FileId): $($shared.GivenUp[$file.FileId])"; $givenUp = $true; break
                            }
                            $wait = Get-ShrinkBackoffSeconds -Attempt $attempt
                            Emit "File $($file.FileId) no size reduction; retry $attempt in $([int]$wait)s"
                            Start-Sleep -Seconds $wait
                        } else { $attempt = 0 }
                    } catch [Microsoft.Data.SqlClient.SqlException] {
                        $num = $_.Exception.Number
                        if ($num -eq 5201) {
                            $shared.GivenUp[$file.FileId] = 'MSSQL error 5201: file cannot be shrunk further'
                            Emit "Gave up on file $($file.FileId): MSSQL error 5201 (no reclaimable space)"; $givenUp = $true; break
                        }
                        $attempt++
                        if ($attempt -gt $connParams.RetryCount) {
                            $shared.GivenUp[$file.FileId] = "MSSQL error $num after $($connParams.RetryCount) retries: $($_.Exception.Message.Split([Environment]::NewLine)[0])"
                            Emit "Gave up on file $($file.FileId): $($shared.GivenUp[$file.FileId])"; $givenUp = $true; break
                        }
                        $wait = Get-ShrinkBackoffSeconds -Attempt $attempt
                        Emit "File $($file.FileId) MSSQL error $num (retry $attempt in $([int]$wait)s): $($_.Exception.Message.Split([Environment]::NewLine)[0])"
                        if ($conn.State -ne 'Open') { try { $conn.Dispose() } catch {}; Start-Sleep -Seconds $wait; $conn = New-WConn }
                        else { Start-Sleep -Seconds $wait }
                    } finally {
                        $shared.Sessions[$workerId].Command = $null
                        try { $cmd.Dispose() } catch {}
                    }
                }

                if (-not $givenUp) { $final = Get-Size $conn $file.FileId; if ($final) { $shared.Done[$file.FileId] = $final.Alloc } }
                [System.Threading.Monitor]::Enter($shared.Lock)
                try { $shared.Owned.Remove($file.FileId) } finally { [System.Threading.Monitor]::Exit($shared.Lock) }
                $shared.Sessions[$workerId].FileId = $null; $shared.Sessions[$workerId].State = 'Idle'
            }
        } finally {
            $shared.Sessions[$workerId].State = 'Stopped'
            try { $conn.Dispose() } catch {}
            Emit 'Worker stopped'
        }
    }

    # ----- launch workers -----
    $iss = [initialsessionstate]::CreateDefault()
    $pool = [runspacefactory]::CreateRunspacePool(1, $effectiveSessions, $iss, $Host)
    $pool.Open()
    $workers = for ($workerId = 0; $workerId -lt $effectiveSessions; $workerId++) {
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($workerScript).AddArgument($workerId).AddArgument($shared).AddArgument($selfPath).AddArgument($connParams)
        [pscustomobject]@{ WorkerId = $workerId; PS = $ps; Handle = $ps.BeginInvoke() }
    }
    Write-ShrinkLog "Launched $effectiveSessions worker session(s)."

    # graceful Ctrl+C: request stop and cancel any in-flight shrink operations
    $cancelHandler = {
        param($s, $e)
        $e.Cancel = $true
        $shared.Stop = $true
        $shared.Events.Enqueue('Ctrl+C received: stopping (in-flight shrinks will be cancelled).')
        foreach ($sess in $shared.Sessions.Values) { if ($sess.Command) { try { $sess.Command.Cancel() } catch {} } }
    }.GetNewClosure()
    [Console]::CancelKeyPress.Add($cancelHandler)

    # ----- monitor loop -----
    $startTime = Get-Date
    $deadline = if ($null -ne $MaxRuntimeMinutes) { $startTime.AddMinutes([int]$MaxRuntimeMinutes) } else { $null }
    $prev = @{}; $stuckState = @{}

    function Write-StatusReport {
        $evt = ''
        while ($shared.Events.TryDequeue([ref]$evt)) { Write-ShrinkLog $evt 'EVENT' }
        $spids = @($shared.Sessions.Values | Where-Object { $_.Spid } | ForEach-Object { [int]$_.Spid })
        if ($spids.Count -eq 0) { return }
        $inList = ($spids -join ',')
        $sql = @"
SELECT r.session_id, r.status, r.command, ISNULL(r.wait_type,'') AS wait_type, r.wait_time,
       ISNULL(r.wait_resource,'') AS wait_resource, r.percent_complete, r.total_elapsed_time,
       r.cpu_time, r.reads, ISNULL(r.blocking_session_id,0) AS blocker,
       ISNULL((SELECT TOP 1 b.command FROM sys.dm_exec_requests b WHERE b.session_id = r.blocking_session_id),'') AS blocker_cmd
FROM sys.dm_exec_requests r WHERE r.session_id IN ($inList);
"@
        $cmd = $control.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 60
        $rd = $cmd.ExecuteReader(); $rows = [System.Collections.Generic.List[object]]::new()
        try { while ($rd.Read()) { $rows.Add([pscustomobject]@{
                        Spid = [int]$rd['session_id']; Status = [string]$rd['status']; Command = [string]$rd['command']
                        Wait = [string]$rd['wait_type']; WaitTime = [long]$rd['wait_time']; WaitRes = [string]$rd['wait_resource']
                        Pct = [double]$rd['percent_complete']; Elapsed = [long]$rd['total_elapsed_time']
                        Cpu = [long]$rd['cpu_time']; Reads = [long]$rd['reads']; Blocker = [int]$rd['blocker']; BlockerCmd = [string]$rd['blocker_cmd']
                    }) } } finally { $rd.Dispose(); $cmd.Dispose() }

        Write-ShrinkLog '---- status ----'
        foreach ($sess in $shared.Sessions.GetEnumerator() | Sort-Object { $_.Key }) {
            $workerId = $sess.Key; $s = $sess.Value
            $row = $rows | Where-Object Spid -eq $s.Spid | Select-Object -First 1
            if (-not $row) { Write-ShrinkLog ("worker {0} session ID {1} file {2} : {3}" -f $workerId, $s.Spid, $s.FileId, $s.State); continue }
            $dCpu = '-'; $dReads = '-'
            if ($prev.ContainsKey($s.Spid)) {
                $c = Get-ShrinkDeltaWithReset -Previous $prev[$s.Spid].Cpu -Current $row.Cpu
                $rr = Get-ShrinkDeltaWithReset -Previous $prev[$s.Spid].Reads -Current $row.Reads
                $dCpu = if ($c.IsReset) { 'reset' } else { $c.Delta }
                $dReads = if ($rr.IsReset) { 'reset' } else { $rr.Delta }
            }
            $prev[$s.Spid] = @{ Cpu = $row.Cpu; Reads = $row.Reads }
            $fileSz = if ($s.FileId) {
                [string](Invoke-ShrinkScalar $control "SELECT CONCAT(CAST(CAST(FILEPROPERTY(name,'SpaceUsed')/128.0 AS decimal(19,1)) AS varchar(20)),'/',CAST(CAST(size/128.0 AS decimal(19,1)) AS varchar(20)),' MB used/alloc') FROM sys.database_files WHERE file_id = $($s.FileId);")
            } else { '' }
            Write-ShrinkLog ("worker {0} session ID {1} file {2} cmd={3} status={4} wait={5}({6}ms) res='{7}' pct={8}% elapsed={9}s dCPU={10} dReads={11} blocker={12}{13} {14}" -f `
                    $workerId, $s.Spid, $s.FileId, $row.Command, $row.Status, $row.Wait, $row.WaitTime, $row.WaitRes,
                [math]::Round($row.Pct, 1), [int]($row.Elapsed / 1000), $dCpu, $dReads, $row.Blocker,
                $(if ($row.Blocker) { "($($row.BlockerCmd))" } else { '' }), $fileSz)

            if (-not $stuckState.ContainsKey($s.Spid)) { $stuckState[$s.Spid] = @{ Blocker = 0; Cpu = 0; Reads = 0; StuckSince = $null } }
            $st = Update-ShrinkStuckState -State $stuckState[$s.Spid] -Blocker $row.Blocker -Cpu $row.Cpu -Reads $row.Reads -Now (Get-Date) -WindowSec $StuckWindowSeconds
            if ($st.IsStuck -and $s.Command) {
                Write-ShrinkLog ("worker {0} session ID {1} stuck on blocker {2} >= {3}s with no progress: cancelling command." -f $workerId, $s.Spid, $row.Blocker, $StuckWindowSeconds) 'WARN'
                try { $s.Command.Cancel() } catch {}
                $stuckState[$s.Spid].StuckSince = $null
            }
        }
        $db = Invoke-ShrinkScalar $control "SELECT CONCAT(CAST(CAST(SUM(CAST(FILEPROPERTY(name,'SpaceUsed') AS bigint))/128.0/1024 AS decimal(19,1)) AS varchar(20)),' / ',CAST(CAST(SUM(size)/128.0/1024 AS decimal(19,1)) AS varchar(20)),' GB (used/alloc)') FROM sys.database_files WHERE type_desc='ROWS';"
        Write-ShrinkLog ("Database total: {0}   files given up: {1}   files done: {2}" -f $db, $shared.GivenUp.Count, $shared.Done.Count)
    }

    try {
        while ($true) {
            Write-StatusReport
            if (-not ($workers | Where-Object { -not $_.Handle.IsCompleted })) { Write-ShrinkLog 'All workers finished.'; break }
            if ($deadline -and (Get-Date) -ge $deadline -and -not $shared.Stop) {
                Write-ShrinkLog 'MaxRuntime reached: stopping.' 'WARN'
                $shared.Stop = $true
                foreach ($sess in $shared.Sessions.Values) { if ($sess.Command) { try { $sess.Command.Cancel() } catch {} } }
            }
            Start-Sleep -Seconds $StatusIntervalSeconds
        }
    } finally {
        [Console]::CancelKeyPress.Remove($cancelHandler)
        foreach ($w in $workers) {
            try { $w.PS.EndInvoke($w.Handle) | Out-Null } catch { Write-ShrinkLog "Worker $($w.WorkerId) error: $($_.Exception.Message)" 'WARN' }
            $w.PS.Dispose()
        }
        $pool.Close(); $pool.Dispose()
        Write-StatusReport
        $elapsedMin = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        Write-ShrinkLog '==================== summary ===================='
        Write-ShrinkLog ("Elapsed {0} min. Files done: {1}. Given up: {2}." -f $elapsedMin, $shared.Done.Count, $shared.GivenUp.Count)
        foreach ($r in $shared.GivenUp.GetEnumerator()) { Write-ShrinkLog ("  Gave up on file {0}: {1}" -f $r.Key, $r.Value) }
        Write-ShrinkLog '================================================='
        $control.Close(); $control.Dispose()
    }
}

# ----- internal helper functions (used by Invoke-ShrinkDriver and the worker runspaces) -----

function Test-ShrinkParameterSet {
    <# .SYNOPSIS Validate a parameter set; returns an array of error strings (empty = valid). #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Params)

    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Params['TruncateOnly'] -and $Params['NoTruncate']) {
        $errors.Add('TruncateOnly and NoTruncate cannot both be set (mutually exclusive).')
    }
    if ($Params['TruncateOnly'] -and $null -ne $Params['FileTargetSizeGB']) {
        $errors.Add('FileTargetSizeGB is not compatible with TruncateOnly (truncate-only does no data movement).')
    }
    if ([int]($Params['Sessions'] ?? 0) -lt 1) {
        $errors.Add('Sessions must be >= 1.')
    }
    if ($Params['AuthType'] -eq 'SQL') {
        if ([string]::IsNullOrWhiteSpace([string]$Params['SqlLogin'])) {
            $errors.Add('SqlLogin is required for SQL authentication.')
        }
        if (-not $Params['SqlPassword']) {
            $errors.Add('SqlPassword is required for SQL authentication.')
        }
    }
    if ($Params['AuthType'] -notin @('EntraID', 'Windows', 'SQL')) {
        $errors.Add("Invalid AuthType '$($Params['AuthType'])' (expected EntraID, Windows, or SQL).")
    }
    if ($Params['AbortAfterWait'] -notin @('SELF', 'BLOCKERS')) {
        $errors.Add("Invalid AbortAfterWait '$($Params['AbortAfterWait'])' (expected SELF or BLOCKERS).")
    }
    , $errors.ToArray()
}

function Get-ShrinkClampedRetryCount {
    <# .SYNOPSIS Clamp a retry count to the allowed range 1..50. #>
    [CmdletBinding()][OutputType([int])]
    param([Parameter(Mandatory)][int]$RetryCount)
    [Math]::Min(50, [Math]::Max(1, $RetryCount))
}

function Get-ShrinkBackoffSeconds {
    <# .SYNOPSIS Exponential backoff with full jitter: uniform(0 .. min(Cap, Base*2^Attempt)). #>
    [CmdletBinding()][OutputType([double])]
    param(
        [Parameter(Mandatory)][int]$Attempt,
        [int]$BaseSec = 5,
        [int]$CapSec = 60,
        [System.Random]$Random
    )
    if (-not $Random) { $Random = [System.Random]::new() }
    $exp = [double]$BaseSec * [Math]::Pow(2, [Math]::Max(0, $Attempt))
    $cap = [Math]::Min([double]$CapSec, $exp)
    [Math]::Round($Random.NextDouble() * $cap, 2)
}

function Get-ShrinkNextTargetMB {
    <# .SYNOPSIS Compute the next SHRINKFILE target (MB), or signal completion. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$AllocatedMB,
        [long]$UsedMB = 0,
        [Nullable[long]]$FloorMB = $null,
        [long]$StepMB = 10240
    )
    $floor = if ($null -ne $FloorMB) { [long]$FloorMB } else { [long]0 }
    if ($AllocatedMB -le $floor) {
        return [pscustomobject]@{ Done = $true; TargetMB = $null; Reason = 'AtOrBelowFloor' }
    }
    $next = $AllocatedMB - $StepMB
    if ($next -lt $floor) { $next = $floor }
    if ($next -ge $AllocatedMB) {
        return [pscustomobject]@{ Done = $true; TargetMB = $null; Reason = 'NoReduction' }
    }
    [pscustomobject]@{ Done = $false; TargetMB = [long]$next; Reason = 'Step' }
}

function Select-ShrinkNextFile {
    <#
    .SYNOPSIS
      Pick the next file to shrink: the one with the most reclaimable space above its
      floor, skipping files already being shrunk by another session and files the
      driver has given up on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [int[]]$OwnedFileIds = @(),
        [int[]]$GivenUpFileIds = @()
    )
    $cand = foreach ($f in $Files) {
        if ($f.FileId -in $OwnedFileIds) { continue }
        if ($f.FileId -in $GivenUpFileIds) { continue }
        if (([long]$f.AllocatedMB - [long]$f.UsedMB) -le 0) { continue }
        $floor = if ($null -ne $f.FloorMB) { [long]$f.FloorMB } else { [long]0 }
        if ([long]$f.AllocatedMB -le $floor) { continue }
        $f
    }
    if (-not $cand) { return $null }
    $cand |
        Sort-Object `
            @{ Expression = { [long]$_.AllocatedMB - [long]$_.UsedMB }; Descending = $true }, `
            @{ Expression = { [int]$_.FileId }; Descending = $false } |
        Select-Object -First 1
}

function Get-ShrinkDeltaWithReset {
    <# .SYNOPSIS Non-negative delta, detecting a counter reset (Current < Previous => skip). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$Previous, [Parameter(Mandatory)][long]$Current)
    if ($Current -lt $Previous) {
        [pscustomobject]@{ IsReset = $true; Delta = $null }
    } else {
        [pscustomobject]@{ IsReset = $false; Delta = [long]($Current - $Previous) }
    }
}

function Update-ShrinkStuckState {
    <# .SYNOPSIS Update per-session stuck state; stuck = same non-zero blocker >= WindowSec with no CPU/reads progress. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [int]$Blocker = 0,
        [long]$Cpu = 0,
        [long]$Reads = 0,
        [datetime]$Now = (Get-Date),
        [int]$WindowSec = 300
    )
    $isStuck = $false
    if (-not $Blocker) {
        $State.StuckSince = $null
    }
    elseif ($State.Blocker -eq $Blocker -and $State.Cpu -eq $Cpu -and $State.Reads -eq $Reads) {
        if ($null -eq $State.StuckSince) { $State.StuckSince = $Now }
        elseif (($Now - [datetime]$State.StuckSince).TotalSeconds -ge $WindowSec) { $isStuck = $true }
    }
    else {
        $State.StuckSince = $Now
    }
    $State.Blocker = $Blocker
    $State.Cpu = $Cpu
    $State.Reads = $Reads
    [pscustomobject]@{ IsStuck = $isStuck; StuckSince = $State.StuckSince }
}

function New-ShrinkCommandText {
    <# .SYNOPSIS Build the DBCC SHRINKFILE T-SQL for one file. #>
    [CmdletBinding()][OutputType([string])]
    param(
        [Parameter(Mandatory)][int]$FileId,
        [Nullable[long]]$TargetMB = $null,
        [switch]$TruncateOnly,
        [switch]$NoTruncate,
        [switch]$WaitAtLowPriority,
        [ValidateSet('SELF', 'BLOCKERS')][string]$AbortAfterWait = 'SELF'
    )
    if ($TruncateOnly -and $NoTruncate) { throw 'TruncateOnly and NoTruncate are mutually exclusive.' }
    $inner =
        if ($TruncateOnly) { "$FileId, TRUNCATEONLY" }
        elseif ($null -ne $TargetMB) {
            if ($NoTruncate) { "$FileId, $TargetMB, NOTRUNCATE" } else { "$FileId, $TargetMB" }
        }
        else { "$FileId" }
    $withParts = [System.Collections.Generic.List[string]]::new()
    if ($WaitAtLowPriority) { $withParts.Add("WAIT_AT_LOW_PRIORITY (ABORT_AFTER_WAIT = $AbortAfterWait)") }
    $withParts.Add('NO_INFOMSGS')
    "DBCC SHRINKFILE ($inner) WITH $($withParts -join ', ')"
}
