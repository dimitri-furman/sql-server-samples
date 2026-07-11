#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Unit tests for ShrinkDriver.
  Run:  Invoke-Pester -Path .\tests\ShrinkDriver.Tests.ps1
#>

BeforeAll {
    # Dot-source the file to expose functions for testing.
    . (Join-Path $PSScriptRoot '..\src\ShrinkDriver.ps1')
}

Describe 'Test-ShrinkParameterSet' {
    It 'rejects TruncateOnly + NoTruncate together' {
        $e = Test-ShrinkParameterSet @{ AuthType='EntraID'; Sessions=5; AbortAfterWait='SELF'; TruncateOnly=$true; NoTruncate=$true }
        $e | Should -Not -BeNullOrEmpty
        ($e -join ';') | Should -Match 'mutually exclusive'
    }
    It 'rejects TruncateOnly + FileTargetSizeGB' {
        $e = Test-ShrinkParameterSet @{ AuthType='EntraID'; Sessions=5; AbortAfterWait='SELF'; TruncateOnly=$true; FileTargetSizeGB=100 }
        ($e -join ';') | Should -Match 'FileTargetSizeGB'
    }
    It 'rejects Sessions < 1' {
        $e = Test-ShrinkParameterSet @{ AuthType='EntraID'; Sessions=0; AbortAfterWait='SELF' }
        ($e -join ';') | Should -Match 'Sessions'
    }
    It 'requires login and password for SQL auth' {
        $e = Test-ShrinkParameterSet @{ AuthType='SQL'; Sessions=5; AbortAfterWait='SELF' }
        ($e -join ';') | Should -Match 'SqlLogin'
        ($e -join ';') | Should -Match 'SqlPassword'
    }
    It 'rejects an invalid AbortAfterWait' {
        $e = Test-ShrinkParameterSet @{ AuthType='EntraID'; Sessions=5; AbortAfterWait='NONE' }
        ($e -join ';') | Should -Match 'AbortAfterWait'
    }
    It 'accepts a valid EntraID parameter set' {
        $e = Test-ShrinkParameterSet @{ AuthType='EntraID'; Sessions=5; AbortAfterWait='SELF'; TruncateOnly=$false; NoTruncate=$false }
        $e | Should -BeNullOrEmpty
    }
}

Describe 'Get-ShrinkClampedRetryCount' {
    It 'clamps <in> to <out>' -TestCases @(
        @{ In = 0;  Out = 1 }
        @{ In = -1; Out = 1 }
        @{ In = 51; Out = 50 }
        @{ In = 50; Out = 50 }
        @{ In = 5;  Out = 5 }
    ) {
        Get-ShrinkClampedRetryCount -RetryCount $In | Should -Be $Out
    }
}

Describe 'Get-ShrinkBackoffSeconds' {
    It 'never exceeds min(cap, base*2^attempt) and is >= 0' {
        $rng = [System.Random]::new(42)
        foreach ($a in 0..10) {
            $cap = [Math]::Min(60, 5 * [Math]::Pow(2, $a))
            $v = Get-ShrinkBackoffSeconds -Attempt $a -BaseSec 5 -CapSec 60 -Random $rng
            $v | Should -BeGreaterOrEqual 0
            $v | Should -BeLessOrEqual $cap
        }
    }
    It 'is deterministic with a seeded RNG' {
        $a = Get-ShrinkBackoffSeconds -Attempt 3 -Random ([System.Random]::new(7))
        $b = Get-ShrinkBackoffSeconds -Attempt 3 -Random ([System.Random]::new(7))
        $a | Should -Be $b
    }
}

Describe 'Get-ShrinkNextTargetMB' {
    It 'steps down by 10 GB by default' {
        $r = Get-ShrinkNextTargetMB -AllocatedMB 100000
        $r.Done | Should -BeFalse
        $r.TargetMB | Should -Be (100000 - 10240)
    }
    It 'never goes below the floor' {
        $r = Get-ShrinkNextTargetMB -AllocatedMB 12000 -FloorMB 10000
        $r.TargetMB | Should -Be 10000
    }
    It 'reports Done when already at/below floor' {
        (Get-ShrinkNextTargetMB -AllocatedMB 10000 -FloorMB 10000).Done | Should -BeTrue
    }
}

Describe 'Select-ShrinkNextFile' {
    BeforeAll {
        $script:files = @(
            [pscustomobject]@{ FileId=1; AllocatedMB=1000; UsedMB=900; FloorMB=$null }  # reclaim 100
            [pscustomobject]@{ FileId=2; AllocatedMB=1000; UsedMB=200; FloorMB=$null }  # reclaim 800
            [pscustomobject]@{ FileId=3; AllocatedMB=1000; UsedMB=1000; FloorMB=$null } # reclaim 0
        )
    }
    It 'picks the most reclaimable file' {
        (Select-ShrinkNextFile -Files $script:files).FileId | Should -Be 2
    }
    It 'skips owned and given-up files' {
        (Select-ShrinkNextFile -Files $script:files -OwnedFileIds @(2) -GivenUpFileIds @()).FileId | Should -Be 1
    }
    It 'returns null when nothing is reclaimable' {
        Select-ShrinkNextFile -Files @($script:files[2]) | Should -BeNullOrEmpty
    }
}

Describe 'Get-ShrinkDeltaWithReset' {
    It 'returns a positive delta when increasing' {
        $r = Get-ShrinkDeltaWithReset -Previous 100 -Current 150
        $r.IsReset | Should -BeFalse
        $r.Delta | Should -Be 50
    }
    It 'flags a reset when the counter decreases' {
        $r = Get-ShrinkDeltaWithReset -Previous 100 -Current 10
        $r.IsReset | Should -BeTrue
        $r.Delta | Should -BeNullOrEmpty
    }
}

Describe 'Update-ShrinkStuckState' {
    It 'fires only after the window with the same blocker and no progress' {
        $state = @{ Blocker=$null; Cpu=0; Reads=0; StuckSince=$null }
        $t0 = Get-Date
        (Update-ShrinkStuckState -State $state -Blocker 55 -Cpu 10 -Reads 10 -Now $t0 -WindowSec 300).IsStuck | Should -BeFalse
        (Update-ShrinkStuckState -State $state -Blocker 55 -Cpu 10 -Reads 10 -Now $t0.AddSeconds(310) -WindowSec 300).IsStuck | Should -BeTrue
    }
    It 'does not fire if CPU or reads increased' {
        $state = @{ Blocker=$null; Cpu=0; Reads=0; StuckSince=$null }
        $t0 = Get-Date
        Update-ShrinkStuckState -State $state -Blocker 55 -Cpu 10 -Reads 10 -Now $t0 | Out-Null
        (Update-ShrinkStuckState -State $state -Blocker 55 -Cpu 20 -Reads 10 -Now $t0.AddSeconds(400)).IsStuck | Should -BeFalse
    }
    It 'does not fire if the blocker changes' {
        $state = @{ Blocker=$null; Cpu=0; Reads=0; StuckSince=$null }
        $t0 = Get-Date
        Update-ShrinkStuckState -State $state -Blocker 55 -Cpu 10 -Reads 10 -Now $t0 | Out-Null
        (Update-ShrinkStuckState -State $state -Blocker 77 -Cpu 10 -Reads 10 -Now $t0.AddSeconds(400)).IsStuck | Should -BeFalse
    }
    It 'does not fire when not blocked' {
        $state = @{ Blocker=$null; Cpu=0; Reads=0; StuckSince=$null }
        (Update-ShrinkStuckState -State $state -Blocker 0 -Cpu 10 -Reads 10 -Now (Get-Date)).IsStuck | Should -BeFalse
    }
}

Describe 'New-ShrinkCommandText' {
    It 'builds a plain target shrink with NO_INFOMSGS and no WLP/USE' {
        $c = New-ShrinkCommandText -FileId 3 -TargetMB 52000
        $c | Should -Be 'DBCC SHRINKFILE (3, 52000) WITH NO_INFOMSGS'
        $c | Should -Not -Match 'USE'
        $c | Should -Not -Match 'WAIT_AT_LOW_PRIORITY'
    }
    It 'builds TRUNCATEONLY without a target' {
        New-ShrinkCommandText -FileId 1 -TruncateOnly | Should -Be 'DBCC SHRINKFILE (1, TRUNCATEONLY) WITH NO_INFOMSGS'
    }
    It 'appends NOTRUNCATE to a target shrink' {
        New-ShrinkCommandText -FileId 2 -TargetMB 1000 -NoTruncate |
            Should -Be 'DBCC SHRINKFILE (2, 1000, NOTRUNCATE) WITH NO_INFOMSGS'
    }
    It 'adds WLP with SELF and never emits MAX_DURATION' {
        $c = New-ShrinkCommandText -FileId 5 -TargetMB 1 -WaitAtLowPriority -AbortAfterWait SELF
        $c | Should -Match 'WAIT_AT_LOW_PRIORITY \(ABORT_AFTER_WAIT = SELF\)'
        $c | Should -Not -Match 'MAX_DURATION'
    }
    It 'adds WLP with BLOCKERS' {
        New-ShrinkCommandText -FileId 5 -TargetMB 1 -WaitAtLowPriority -AbortAfterWait BLOCKERS |
            Should -Match 'ABORT_AFTER_WAIT = BLOCKERS'
    }
    It 'throws on TruncateOnly + NoTruncate' {
        { New-ShrinkCommandText -FileId 1 -TruncateOnly -NoTruncate } | Should -Throw
    }
}
