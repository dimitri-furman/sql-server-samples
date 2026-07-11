# ShrinkDriver

Reclaim allocated but unused space from the data files of a MSSQL database
by running several `DBCC SHRINKFILE` operations in parallel, with progress
monitoring, incremental shrinking, and automatic retries.

## What it does

- Shrinks multiple data files at once (one session per file) to reduce total run time.
- Shrinks each file gradually in steps toward an optional target size, instead of in one large operation.
- Optionally runs shrink at low lock priority to reduce blocking of other queries.
- Retries transient failures with backoff, and moves on from files that cannot shrink further.
- Writes a status report to the console and a log file at a regular interval, and stops cleanly on Ctrl+C or an optional time limit.
- Supports Entra ID, Windows, and SQL authentication when connecting to the database.

## Requirements

- SQL Server 2022 or later, Azure SQL Managed Instance, or Azure SQL Database.
- Membership in the `db_owner` role in the target database, or membership in the `sysadmin` server role.
- PowerShell 7 or later.
- The `SqlServer` module:
  `Install-Module SqlServer -Scope CurrentUser`.

## Usage

Load the script, then call `Invoke-ShrinkDriver`:

```powershell
. .\src\ShrinkDriver.ps1

# Entra ID auth (default): shrink 5 files at a time to the smallest possible size
Invoke-ShrinkDriver -ServerName myserver.database.windows.net -DatabaseName MyDb -Sessions 5

# Windows auth: stop each file at 500 GB, 8 files at a time
Invoke-ShrinkDriver -ServerName sql01 -DatabaseName Sales -AuthType Windows -FileTargetSizeGB 500 -Sessions 8

# SQL auth
$pw = Read-Host -AsSecureString 'SQL password'
Invoke-ShrinkDriver -ServerName sql01 -DatabaseName Sales -AuthType SQL -SqlLogin appuser -SqlPassword $pw
```

For the full list of parameters and what they do:

```powershell
Get-Help Invoke-ShrinkDriver -Full
```

## Output

Progress is written to the console and mirrored to a log file — by default a
timestamped `shrink-<server>-<database>-<time>.log` next to the script, or the
path given with `-LogPath`. The log records specified parameter values and a 
periodic per-file status report plus notable events (retries, files given up on, 
and cancellations).

## Tests

Unit tests for the pure helper functions (no database required) use
[Pester](https://pester.dev) 5 or later:

```powershell
Invoke-Pester -Path .\tests\ShrinkDriver.Tests.ps1
```

## Shrink documentation

- [DBCC SHRINKFILE](https://learn.microsoft.com/sql/t-sql/database-console-commands/dbcc-shrinkfile-transact-sql).
- [Manage file space for databases in Azure SQL Database](https://learn.microsoft.com/azure/azure-sql/database/file-space-manage).
