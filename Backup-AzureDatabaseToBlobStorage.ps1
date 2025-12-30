<#
.SYNOPSIS
	This Azure Automation runbook automates Azure SQL database backup to Blob storage and deletes old backups from blob storage.

.DESCRIPTION
	You should use this Runbook if you want manage Azure SQL database backups in Blob storage.

.PARAMETER DatabaseResourceGroupName
	Specifies the name of the resource group where the Azure SQL Database server is located.

.PARAMETER DatabaseServerName
	Specifies the name of the Azure SQL Database Server which script will backup.

.PARAMETER DatabaseName
	Specifies the name of the Azure SQL Database which script will backup.

.PARAMETER DatabaseAdminUsername
	Specifies the administrator username of the Azure SQL Database Server.

.PARAMETER DatabaseAdminPassword
	Specifies the administrator password of the Azure SQL Database Server.

.PARAMETER StorageResourceGroupName
	Specifies the name of the resource group where the Azure Storage Account is located.

.PARAMETER StorageKey
	Specifies the storage key of the storage account.

.PARAMETER StorageAccountName
	Specifies the name of the storage account where backup file will be uploaded.

.PARAMETER BlobContainerName
	Specifies the container name of the storage account where backup file will be uploaded. Container will be created if it does not exist.

.PARAMETER RetentionDays
	Specifies the number of days backups are kept in blob storage. All older backup files for the Azure SQL Database DatabaseName are deleted from the container.
	If not provided or < 0 then no deletes are performed.

.INPUTS
	None.

.OUTPUTS
	Human-readable informational and error messages produced during the job. Not intended to be consumed by another runbook.
#>

param(
 	[parameter(Mandatory=$true)]
	[String] $DatabaseResourceGroupName,
 	[parameter(Mandatory=$true)]
	[String] $DatabaseServerName,
	[parameter(Mandatory=$true)]
	[String]$DatabaseName,
	[parameter(Mandatory=$true)]
	[String]$DatabaseAdminUsername,
	[parameter(Mandatory=$true)]
	[String]$DatabaseAdminPassword,
	[parameter(Mandatory=$true)]
	[String] $StorageResourceGroupName,
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

function Create-Blob-Container-If-Not-Exists([string]$blobContainerName, $context) {
	Write-Verbose "Checking if blob container '$blobContainerName' already exists" -Verbose

	# Attempt to get the container and capture any error silently
	$container = Get-AzStorageContainer -Name $blobContainerName -Context $context -ErrorAction SilentlyContinue

	# Check if the $container variable is null
	if ($null -eq $container) {
		New-AzStorageContainer -Name $blobContainerName -Context $context
		Write-Verbose "Container '$blobContainerName' created" -Verbose
	} else {
		Write-Verbose "Container '$blobContainerName' already exists" -Verbose
	}
}

function Export-To-Blob-Storage([string]$resourceGroupName, [string]$databaseServerName, [string]$databaseName, [string]$databaseAdminUsername, [string]$databaseAdminPassword, [string]$storageKey, [string]$storageUri) {
	Write-Verbose "Starting database export database '$databaseName'" -Verbose

	$securePassword = ConvertTo-SecureString -String $databaseAdminPassword -AsPlainText -Force 
	$creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $databaseAdminUsername, $securePassword

	$exportRequest = New-AzSqlDatabaseExport -ResourceGroupName $resourceGroupName -ServerName $databaseServerName -DatabaseName $databaseName -StorageKeytype "StorageAccessKey" -StorageKey $storageKey -StorageUri $storageUri -AdministratorLogin $creds.UserName -AdministratorLoginPassword $creds.Password	
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

function Delete-Old-Backups([int]$retentionDays, [string]$databaseName, [string]$blobContainerName, $context) {
	$isOldDate = [DateTime]::UtcNow.AddDays(-$retentionDays)
	$prefix = $databaseName + "/" + $databaseName

	$blobs = Get-AzStorageBlob -Container $blobContainerName -Prefix $prefix -Context $context | Where-Object { $_.Name -like "*.bacpac" }
	foreach ($blob in ($blobs | Where-Object { $_.LastModified.UtcDateTime -lt $isOldDate -and $_.BlobType -eq "BlockBlob" })) {
		Write-Verbose ("Removing blob: " + $blob.Name) -Verbose
		Remove-AzStorageBlob -Blob $blob.Name -Container $blobContainerName -Context $context
	}
}

Write-Verbose "Starting database backup" -Verbose

Login

$context = (Get-AzStorageAccount -ResourceGroupName $StorageResourceGroupName -Name $StorageAccountName).Context

Create-Blob-Container-If-Not-Exists `
	-blobContainerName $BlobContainerName `
	-context $context

$storageUri = "https://" + $StorageAccountName + ".blob.core.windows.net/" + $BlobContainerName + "/" + $DatabaseName + "/" + $DatabaseName + (Get-Date).ToString("yyyyMMddHHmm") + ".bacpac"

Export-To-Blob-Storage `
	-resourceGroupName $DatabaseResourceGroupName `
	-databaseServerName $DatabaseServerName `
	-databaseName $DatabaseName `
	-databaseAdminUsername $DatabaseAdminUsername `
	-databaseAdminPassword $DatabaseAdminPassword `
	-storageKey $StorageKey `
	-storageUri $storageUri

if ($RetentionDays -gt 0) {
	Delete-Old-Backups `
		-retentionDays $RetentionDays `
		-databaseName $DatabaseName `
		-blobContainerName $BlobContainerName `
		-context $context
}

Write-Verbose "Database backup script finished" -Verbose
