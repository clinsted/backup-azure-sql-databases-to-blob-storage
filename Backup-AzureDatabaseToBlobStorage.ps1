<#
.SYNOPSIS
	This Azure Automation runbook automates Azure SQL database backup to Blob storage and deletes old backups from blob storage. 

.DESCRIPTION
	You should use this Runbook if you want manage Azure SQL database backups in Blob storage. 
	This runbook can be used together with Azure SQL Point-In-Time-Restore.

	This is a PowerShell runbook, as opposed to a PowerShell Workflow runbook.

.PARAMETER ResourceGroupName
	Specifies the name of the resource group where the Azure SQL Database server is located
	
.PARAMETER DatabaseServerName
	Specifies the name of the Azure SQL Database Server which script will backup

.PARAMETER DatabaseName
	Specifies the name of the database which script will backup

.PARAMETER DatabaseAdminUsername
	Specifies the administrator username of the Azure SQL Database Server

.PARAMETER DatabaseAdminPassword
	Specifies the administrator password of the Azure SQL Database Server

.PARAMETER StorageKey
	Specifies the storage key of the storage account

.PARAMETER StorageAccountName
	Specifies the name of the storage account where backup file will be uploaded

.PARAMETER BlobContainerName
	Specifies the container name of the storage account where backup file will be uploaded. Container will be created if it does not exist.

.PARAMETER RetentionDays
	If provided it specifies the number of days how long backups are kept in blob storage. Script will remove all older backup files for each DatabaseName from the container. No other files that may exist in the folder will get deleted.
	If not provided or < 0 then no files are removed

.INPUTS
	None.

.OUTPUTS
	Human-readable informational and error messages produced during the job. Not intended to be consumed by another runbook.
#>

param(
    [parameter(Mandatory=$true)]
	[String] $ResourceGroupName,
    [parameter(Mandatory=$true)]
	[String] $DatabaseServerName,
	[parameter(Mandatory=$true)]
    [String]$DatabaseName,
    [parameter(Mandatory=$true)]
    [String]$DatabaseAdminUsername,
	[parameter(Mandatory=$true)]
    [String]$DatabaseAdminPassword,
    [parameter(Mandatory=$true)]
    [String]$StorageKey,
    [parameter(Mandatory=$true)]
    [String]$StorageAccountName,
	[parameter(Mandatory=$true)]
    [string]$BlobContainerName,
	[parameter(Mandatory=$false)]
    [Int32]$RetentionDays = 0
)

$ErrorActionPreference = 'stop'

function Login() {
	try
	{
		Write-Verbose "Logging in to Azure..." -Verbose

		Connect-AzAccount -Identity
	}
	catch {
		Write-Error -Message $_.Exception
		throw $_.Exception
	}
}

function Export-To-Blob-Storage([string]$resourceGroupName, [string]$databaseServerName, [string]$databaseName, [string]$databaseAdminUsername, [string]$databaseAdminPassword, [string]$storageKey, [string]$storageAccountName, [string]$blobContainerName) {
	Write-Verbose "Starting database export database '$databaseName'" -Verbose
	$securePassword = ConvertTo-SecureString -String $databaseAdminPassword -AsPlainText -Force 
	$creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $databaseAdminUsername, $securePassword
	$bacpacFilename = $databaseName + (Get-Date).ToString("yyyyMMddHHmm") + ".bacpac"
	$bacpacUri = "https://" + $storageAccountName + ".blob.core.windows.net/" + $blobContainerName + "/" + $databaseName + "/" + $bacpacFilename

	$exportRequest = New-AzSqlDatabaseExport -ResourceGroupName $resourceGroupName -ServerName $databaseServerName -DatabaseName $databaseName -StorageKeytype "StorageAccessKey" -StorageKey $storageKey -StorageUri $bacpacUri -AdministratorLogin $creds.UserName -AdministratorLoginPassword $creds.Password
	
	$exportStatus = Get-AzSqlDatabaseImportExportStatus -OperationStatusLink $exportRequest.OperationStatusLink
	[Console]::Write("Exporting")
	while ($exportStatus.Status -eq "InProgress")
	{
		Start-Sleep -s 15
		$exportStatus = Get-AzSqlDatabaseImportExportStatus -OperationStatusLink $exportRequest.OperationStatusLink
		[Console]::Write(".")
	}
	[Console]::WriteLine("")
	$exportStatus
}

function Delete-Old-Backups([string]$resourceGroupName, [string]$storageAccountName, [int]$retentionDays, [string]$databaseName, [string]$blobContainerName) {
	$context = (Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName).Context
	$isOldDate = [DateTime]::UtcNow.AddDays(-$retentionDays)
	$bacpacFilename = $databaseName + "/" + $databaseName

	$blobs = Get-AzStorageBlob -Container $blobContainerName -Prefix $bacpacFilename -Context $context | Where-Object { $_.Name -like "*.bacpac" }
	foreach ($blob in ($blobs | Where-Object { $_.LastModified.UtcDateTime -lt $isOldDate -and $_.BlobType -eq "BlockBlob" })) {
		Write-Verbose ("Removing blob: " + $blob.Name) -Verbose
		Remove-AzStorageBlob -Blob $blob.Name -Container $blobContainerName -Context $context
	}
}

Write-Verbose "Starting database backup" -Verbose

Login

Export-To-Blob-Storage `
	-resourceGroupName $ResourceGroupName `
	-databaseServerName $DatabaseServerName `
	-databaseName $DatabaseName `
	-databaseAdminUsername $DatabaseAdminUsername `
	-databaseAdminPassword $DatabaseAdminPassword `
	-storageKey $StorageKey `
	-storageAccountName $StorageAccountName `
	-blobContainerName $BlobContainerName

if ($RetentionDays -gt 0) {
	Delete-Old-Backups `
		-resourceGroupName $ResourceGroupName `
		-storageAccountName $StorageAccountName `
		-retentionDays $RetentionDays `
		-databaseName $DatabaseName `
		-blobContainerName $BlobContainerName
}

Write-Verbose "Database backup script finished" -Verbose
