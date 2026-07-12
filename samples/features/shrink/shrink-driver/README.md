# ShrinkDriver

Reclaim allocated but unused space from the data files of a MSSQL database
by running parallel `DBCC SHRINKFILE` operations, with progress monitoring,
incremental shrinking, and automatic retries.

## What it does

- Shrinks multiple data files at once (one session per file) to reduce total run time.
- Shrinks each file gradually in steps toward an optional target size, instead of in one large operation.
- Skips files with little unused space to reclaim.
- Optionally runs shrink at low lock priority to reduce blocking of other queries.
- Retries transient failures with backoff, and moves on from files that cannot shrink further.
- Runs in two modes: `Report` (default) shows each file's used, allocated, and reclaimable space without changing anything; `Shrink` performs the shrink.
- Writes a status report to the console and a log file at a regular interval, and stops on Ctrl+C or an optional time limit.
- Supports Entra ID, Windows, and SQL authentication when connecting to the database.

## Requirements

- SQL Server 2022 or later, Azure SQL Managed Instance, or Azure SQL Database.
- To shrink (`-Mode Shrink`): membership in the `db_owner` database role, or the `sysadmin` server role.
- To report (`-Mode Report`, the default): connection to the database.
- PowerShell 7 or later.
- The `SqlServer` module:
  `Install-Module SqlServer -Scope CurrentUser`.

## Usage

Load the script, then call `Invoke-ShrinkDriver`:

```powershell
. .\src\ShrinkDriver.ps1

# Report (default): show each file's used, allocated, and reclaimable space, without changing anything
Invoke-ShrinkDriver -ServerName myserver.database.windows.net -DatabaseName MyDb

# Shrink with Entra ID auth (default) to the smallest possible size, working on up to 5 files concurrently
Invoke-ShrinkDriver -ServerName myserver.database.windows.net -DatabaseName MyDb -Mode Shrink -Sessions 5

# Shrink with Windows auth: don't shrink below 500 GiB, working on up to 8 files concurrently
Invoke-ShrinkDriver -ServerName sql01 -DatabaseName MyDb -Mode Shrink -AuthType Windows -FileTargetSizeGiB 500 -Sessions 8

# Shrink with SQL auth
$pw = Read-Host -AsSecureString 'SQL password'
Invoke-ShrinkDriver -ServerName sql01 -DatabaseName MyDb -Mode Shrink -AuthType SQL -SqlLogin appuser -SqlPassword $pw
```

For the full list of parameters and what they do:

```powershell
Get-Help Invoke-ShrinkDriver -Full
```

## Output

Progress is written to the console and mirrored to a log file — by default a
timestamped `shrink-<time>.log` next to the script, or the
path given with `-LogPath`. The log records specified parameter values and a 
periodic per-file status report plus notable events (retries and cancellations).
A summary at the end reports how each file ended up:

- **Shrunk** — the file was reduced in size.
- **Repacked** — with `-NoTruncate`, data pages were moved toward the front of the file; the allocated size is unchanged by design (space is not released).
- **Partly shrunk** — reduced, but gave up before reaching the target or minimum size.
- **Already at minimum** — already at its smallest possible size; nothing to reclaim.
- **Already at target** — already at or below the requested target size.
- **Grew** — ended larger than it started because other sessions added data during the shrink.
- **Gave up** — abandoned after retries with no change in size.

## Tests

Unit tests for the pure helper functions (no database required) use
[Pester](https://pester.dev) 5 or later:

```powershell
Invoke-Pester -Path .\tests\ShrinkDriver.Tests.ps1
```

## Shrink documentation

- [DBCC SHRINKFILE](https://learn.microsoft.com/sql/t-sql/database-console-commands/dbcc-shrinkfile-transact-sql).
- [Manage file space for databases in Azure SQL Database](https://learn.microsoft.com/azure/azure-sql/database/file-space-manage).
