#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Integration tests for ShrinkDriver. These run real DBCC SHRINKFILE operations against a live SQL
  instance. By default they use SQL Server LocalDB (Windows auth); set $env:SHRINKDRIVER_TEST_SERVER
  (+ optionally _AUTH = EntraID|Windows|SQL, _LOGIN, _PASSWORD) to target another instance, e.g. an
  Azure SQL Database logical server. They are skipped automatically when no instance is reachable, so
  they never break the unit test gate.

  Run:  Invoke-Pester -Path .\tests\ShrinkDriver.Integration.Tests.ps1 -Tag Integration

  Notes:
  - Small files are used so the suite runs quickly; real page-movement shrink is seconds at best, not
    milliseconds, and DROP-created free space appears only after deferred deallocation settles (handled
    by Wait-ShrinkFreeSpaceSettled).
  - Shrinks assert on the returned result object, use -BackoffBaseSeconds/-BackoffCapSeconds 0 for
    instant retries, and -WaitAtLowPriority:$false (LocalDB Express has no WLP for shrink).
#>

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'fixtures\ShrinkTestDb.psm1') -Force
    $server = Get-ShrinkTestServer
    # Box SQL Server / LocalDB vs Azure SQL Database (EngineEdition 5, which provisions a single data
    # file). Some contexts apply only to the box engine and are skipped otherwise.
    $isBoxEngine = $false
    if ($server) {
        try { $isBoxEngine = (Get-ShrinkTestEngineEdition -Context $server) -ne 5 } catch { $isBoxEngine = $false }
    }
}

Describe 'ShrinkDriver integration' -Tag 'Integration' -Skip:(-not $server) {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'fixtures\ShrinkTestDb.psm1') -Force
        . (Join-Path $PSScriptRoot '..\src\ShrinkDriver.ps1')
        $server = Get-ShrinkTestServer
        $log = Join-Path ([System.IO.Path]::GetTempPath()) 'shrinkdriver-integration.log'
    }

    Context 'Report mode' {
        BeforeAll { $db = New-ShrinkTestDatabase -Context $server }
        AfterAll { Remove-ShrinkTestDatabase -TestDb $db }

        It 'returns a Report result listing eligible files' {
            $r = Invoke-ShrinkDriver -ServerName $server.ServerInstance -DatabaseName $db.Database -Mode Report `
                -AuthType $server.Auth -MinReclaimMBOverride 1 -PassThru -LogPath $log 6>$null
            $r.Mode | Should -Be 'Report'
            $r.Files.Count | Should -BeGreaterThan 0
            $r.Eligible | Should -BeGreaterThan 0
            @($r.Files | Where-Object IsEligible).Count | Should -Be $r.Eligible
        }

        It 'reports zero eligible when the threshold is huge (no crash)' {
            $r = Invoke-ShrinkDriver -ServerName $server.ServerInstance -DatabaseName $db.Database -Mode Report `
                -AuthType $server.Auth -MinReclaimMBOverride 1000000000 -PassThru -LogPath $log 6>$null
            $r.Mode | Should -Be 'Report'
            $r.Eligible | Should -Be 0
        }
    }

    Context 'Shrink happy path' {
        BeforeAll {
            $db = New-ShrinkTestDatabase -Context $server
            Wait-ShrinkFreeSpaceSettled -TestDb $db -MinFreeMB 8 | Out-Null
            $allocBefore = (Get-ShrinkTestFileSizes -TestDb $db | Measure-Object -Property alloc_mb -Sum).Sum
            $res = Invoke-ShrinkDriver -ServerName $server.ServerInstance -DatabaseName $db.Database -Mode Shrink `
                -AuthType $server.Auth -WaitAtLowPriority:$false -BackoffBaseSeconds 0 -BackoffCapSeconds 0 `
                -MinReclaimMBOverride 1 -StepMBOverride 20 -Sessions 4 -StatusIntervalSeconds 5 -PassThru -LogPath $log 6>$null
        }
        AfterAll { Remove-ShrinkTestDatabase -TestDb $db }

        It 'returns a Shrink result object' {
            $res.Mode | Should -Be 'Shrink'
            $res.Files.Count | Should -BeGreaterThan 0
        }

        It 'classifies every file into a known bucket' {
            $known = @('Shrunk', 'PartlyShrunk', 'AlreadyMinimal', 'AlreadyAtTarget', 'Repacked', 'Grew', 'GaveUp', 'Interrupted', 'NotProcessed')
            foreach ($f in $res.Files) { $f.Bucket | Should -BeIn $known }
        }

        It 'reclaims space from at least one file' {
            ($res.Counts.Shrunk + $res.Counts.PartlyShrunk) | Should -BeGreaterThan 0
        }

        It 'reduces the total allocated size' {
            $allocAfter = (Get-ShrinkTestFileSizes -TestDb $db | Measure-Object -Property alloc_mb -Sum).Sum
            $allocAfter | Should -BeLessThan $allocBefore
        }
    }

    Context 'Per-file floor (FileTargetMBOverride)' {
        BeforeAll {
            $db = New-ShrinkTestDatabase -Context $server
            Wait-ShrinkFreeSpaceSettled -TestDb $db -MinFreeMB 8 | Out-Null
            $before = Get-ShrinkTestFileSizes -TestDb $db
            $allocBefore = ($before | Measure-Object -Property alloc_mb -Sum).Sum
            $beforeAllocById = @{}
            $before | ForEach-Object { $beforeAllocById[[int]$_.file_id] = [int]$_.alloc_mb }
            $maxUsed = ($before | Measure-Object -Property used_mb -Maximum).Maximum
            $floor = [int]$maxUsed + 5   # above every file's used
            $res = Invoke-ShrinkDriver -ServerName $server.ServerInstance -DatabaseName $db.Database -Mode Shrink `
                -AuthType $server.Auth -WaitAtLowPriority:$false -BackoffBaseSeconds 0 -BackoffCapSeconds 0 `
                -MinReclaimMBOverride 1 -FileTargetMBOverride $floor -StepMBOverride 10 -Sessions 4 `
                -StatusIntervalSeconds 5 -PassThru -LogPath $log 6>$null
        }
        AfterAll { Remove-ShrinkTestDatabase -TestDb $db }

        It 'never shrinks a file below the floor' {
            # A file that started above the floor must be held at or above it. Files already smaller than
            # the floor are left untouched (and may legitimately sit below it), so they are excluded.
            foreach ($f in (Get-ShrinkTestFileSizes -TestDb $db)) {
                if ($beforeAllocById[[int]$f.file_id] -gt $floor) { $f.alloc_mb | Should -BeGreaterOrEqual $floor }
            }
        }

        It 'reduces total allocated size toward the floor' {
            $allocAfter = (Get-ShrinkTestFileSizes -TestDb $db | Measure-Object -Property alloc_mb -Sum).Sum
            $allocAfter | Should -BeLessThan $allocBefore
        }
    }

    Context 'NoTruncate (repack only)' {
        BeforeAll {
            $db = New-ShrinkTestDatabase -Context $server
            Wait-ShrinkFreeSpaceSettled -TestDb $db -MinFreeMB 8 | Out-Null
            $allocBefore = (Get-ShrinkTestFileSizes -TestDb $db | Measure-Object -Property alloc_mb -Sum).Sum
            $res = Invoke-ShrinkDriver -ServerName $server.ServerInstance -DatabaseName $db.Database -Mode Shrink `
                -AuthType $server.Auth -NoTruncate -WaitAtLowPriority:$false -BackoffBaseSeconds 0 -BackoffCapSeconds 0 `
                -MinReclaimMBOverride 1 -Sessions 4 -StatusIntervalSeconds 5 -PassThru -LogPath $log 6>$null
        }
        AfterAll { Remove-ShrinkTestDatabase -TestDb $db }

        It 'reports every processed file as Repacked' {
            $res.Files.Count | Should -BeGreaterThan 0
            $res.Counts.Repacked | Should -Be $res.Files.Count
        }

        It 'never releases space (nothing shrunk)' {
            ($res.Counts.Shrunk + $res.Counts.PartlyShrunk) | Should -Be 0
        }

        It 'leaves the total allocated size unchanged' {
            $allocAfter = (Get-ShrinkTestFileSizes -TestDb $db | Measure-Object -Property alloc_mb -Sum).Sum
            $allocAfter | Should -Be $allocBefore
        }
    }

    Context 'TruncateOnly (release tail free space)' -Skip:(-not $isBoxEngine) {
        BeforeAll {
            $db = New-ShrinkTestDatabase -Context $server
            Wait-ShrinkFreeSpaceSettled -TestDb $db -MinFreeMB 8 | Out-Null
            # Grow every data file so there is guaranteed unused space at the tail for TRUNCATEONLY to
            # reclaim (the drop-created free space is interspersed and may not sit at the file end).
            Add-ShrinkTestTailSpace -TestDb $db -AddMB 48
            $allocBefore = (Get-ShrinkTestFileSizes -TestDb $db | Measure-Object -Property alloc_mb -Sum).Sum
            $res = Invoke-ShrinkDriver -ServerName $server.ServerInstance -DatabaseName $db.Database -Mode Shrink `
                -AuthType $server.Auth -TruncateOnly -WaitAtLowPriority:$false -BackoffBaseSeconds 0 -BackoffCapSeconds 0 `
                -MinReclaimMBOverride 1 -Sessions 4 -StatusIntervalSeconds 5 -PassThru -LogPath $log 6>$null
        }
        AfterAll { Remove-ShrinkTestDatabase -TestDb $db }

        It 'classifies every file into a known bucket' {
            $known = @('Shrunk', 'PartlyShrunk', 'AlreadyMinimal', 'AlreadyAtTarget', 'Repacked', 'Grew', 'GaveUp', 'Interrupted', 'NotProcessed')
            $res.Files.Count | Should -BeGreaterThan 0
            foreach ($f in $res.Files) { $f.Bucket | Should -BeIn $known }
        }

        It 'reclaims the trailing free space' {
            $res.Counts.Shrunk | Should -BeGreaterThan 0
            $allocAfter = (Get-ShrinkTestFileSizes -TestDb $db | Measure-Object -Property alloc_mb -Sum).Sum
            $allocAfter | Should -BeLessThan $allocBefore
        }
    }

    Context 'Concurrency (files > sessions)' -Skip:(-not $isBoxEngine) {
        BeforeAll {
            $db = New-ShrinkTestDatabase -Context $server -FileCount 6
            Wait-ShrinkFreeSpaceSettled -TestDb $db -MinFreeMB 8 | Out-Null
            $res = Invoke-ShrinkDriver -ServerName $server.ServerInstance -DatabaseName $db.Database -Mode Shrink `
                -AuthType $server.Auth -WaitAtLowPriority:$false -BackoffBaseSeconds 0 -BackoffCapSeconds 0 `
                -MinReclaimMBOverride 1 -StepMBOverride 20 -Sessions 2 -StatusIntervalSeconds 5 -PassThru -LogPath $log 6>$null
        }
        AfterAll { Remove-ShrinkTestDatabase -TestDb $db }

        It 'exercises more files than sessions' {
            # Sessions was capped at 2 while more eligible files exist, so a freed worker must pick up the rest.
            $res.Files.Count | Should -BeGreaterThan 2
        }

        It 'accounts for every eligible file exactly once (counts tally to files; none dropped)' {
            $sum = ($res.Counts.PSObject.Properties | Measure-Object -Property Value -Sum).Sum
            $sum | Should -Be $res.Files.Count
        }

        It 'shrinks at least one file under limited concurrency' {
            ($res.Counts.Shrunk + $res.Counts.PartlyShrunk) | Should -BeGreaterThan 0
        }
    }
}
