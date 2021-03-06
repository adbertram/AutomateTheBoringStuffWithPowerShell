#Requires -RunAsAdministrator

#region Configuration
Set-StrictMode -Version Latest

$modulePath = $PSScriptRoot
$configFilePath = "$modulePath\PowerLabConfiguration.psd1"
$script:LabConfiguration = Import-PowerShellDataFile -Path $configFilePath

#endregion
function New-PowerLab {
	[CmdletBinding()]
	param (		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[switch]$WinRmCopy
	)
	$ErrorActionPreference = 'Stop'

	try {
		## Create the switch
		NewLabSwitch

		## Create the domain controller
		New-ActiveDirectoryForest
		
		# region Create the member servers
		foreach ($type in $($script:LabConfiguration.VirtualMachines).where({$_.Type -ne 'Domain Controller'}).Type) {
			& ("New-{0}Server" -f $type) -AddToDomain
		}
		#endregion
	} catch {
		Write-Error  "$($_.Exception.Message) - Line Number: $($_.InvocationInfo.ScriptLineNumber)"
	}
}
function Remove-PowerLab {
	[OutputType('void')]
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param
	()

	$ErrorActionPreference = 'Stop'

	## Remove all VMs
	$icmParams = @{
		ComputerName = $script:LabConfiguration.HostServer.Name
	}
	$nameMatch = $script:LabConfiguration.VirtualMachines.BaseName -join '|'
	if ($vms = Invoke-Command @icmParams -ScriptBlock { Get-Vm | where { $_.Name -match $using:nameMatch }}) {
	
		Invoke-Command @icmParams -ScriptBlock { Stop-Vm -Name $using:vms.Name -Force; Remove-Vm -Name $using:vms.Name }
	}

	## Remove all VHDs
	$vhdPath = ConvertToUncPath -LocalFilePath $script:LabConfiguration.DefaultVirtualMachineConfiguration.VHDConfig.Path -ComputerName $script:LabConfiguration.HostServer.Name
	if ($vhds = Get-ChildItem -Path $vhdPath) {
		if ($PSCmdlet.ShouldProcess("VHDs: [$($vhds.Name -join ',')]", 'Remove')) {
			$vhds | Remove-Item
		}
	}

	## Remove all trusted hosts
	$trustedHostString = (Get-ChildItem -Path WSMan:\localhost\Client\TrustedHosts).Value
	$trustedHosts = $trustedHostString -split ','
	$nonLabTrustedHosts = $trustedHosts | where { $_ -notmatch $nameMatch }
	if ($labTrustedHosts = $trustedHosts | where { $_ -match $nameMatch }) {
		$nonLabString = $nonLabTrustedHosts -join ','
		if ($PSCmdlet.ShouldProcess('Lab trusted hosts', 'Remove')) {
			Set-Item -Path WSMan:\localhost\Client\TrustedHosts $nonLabString -Force
		}
	}

	## Remove all cached credentials
	GetCachedCredential | where {$_.Name -match $nameMatch} | foreach {
		if ($PSCmdlet.ShouldProcess("Lab cached credential: $($_.Name)", 'Remove')) {
			RemoveCachedCredential -TargetName $_.Name
		}
	}
}
function New-ActiveDirectoryForest {
	[OutputType([void])]
	[CmdletBinding(SupportsShouldProcess)]
	param
	()

	$ErrorActionPreference = 'Stop'

	## Build the VM
	$vm = New-PowerLabVm -Type 'Domain Controller' -PassThru

	## Grab config values from file
	$forestConfiguration = $script:LabConfiguration.ActiveDirectoryConfiguration
	$forestParams = @{
		DomainName                    = $forestConfiguration.DomainName
		DomainMode                    = $forestConfiguration.DomainMode
		ForestMode                    = $forestConfiguration.ForestMode
		Confirm                       = $false
		SafeModeAdministratorPassword = (ConvertTo-SecureString -AsPlainText $forestConfiguration.SafeModeAdministratorPassword -Force)
		WarningAction                 = 'Ignore'
	}
	
	## Build the forest
	InvokeVmCommand -ArgumentList $forestParams -ComputerName $vm.Name -ScriptBlock { 
		param($forestParams)
		$null = Install-windowsfeature -Name AD-Domain-Services -IncludeManagementTools
		$null = Install-ADDSForest @forestParams
	}

	## Replace the workgroup cred with the new domain cred
	RemoveCachedCredential -TargetName $vm.Name
	$credConfig = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Users.where({ $_.Name -ne 'Administrator' })
	$cred = New-PSCredential -UserName "$($forestConfiguration.DomainName)\$($credConfig.name)" -Password $credConfig.Password
	AddCachedCredential -ComputerName $vm.Name -Credential $cred
}
function New-PowerLabSqlServer {
	[OutputType([void])]
	[CmdletBinding(SupportsShouldProcess)]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[switch]$AddToDomain
	)

	$ErrorActionPreference = 'Stop'

	## Build the VM
	$vmparams = @{ 
		Type     = 'SQL' 
		PassThru = $true
	}
	$vm = New-PowerLabVm @vmParams
	Install-PowerLabSqlServer -ComputerName $vm.Name

	if ($AddToDomain.IsPresent) {
		$credConfig = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Users.where({ $_.Name -ne 'Administrator' })
		$domainUserName = '{0}\{1}' -f $script:LabConfiguration.ActiveDirectoryConfiguration.DomainName, $credConfig.name
		$domainCred = New-PSCredential -UserName $domainUserName -Password $credConfig.Password
		$addParams = @{
			ComputerName = $vm.Name
			DomainName   = $script:LabConfiguration.ActiveDirectoryConfiguration.DomainName
			Credential   = $domainCred
			Restart      = $true
			Force        = $true
		}
		Add-Computer @addParams
	}
}
function New-WebServer {
	[OutputType([void])]
	[CmdletBinding(SupportsShouldProcess)]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[switch]$AddToDomain
	)

	$ErrorActionPreference = 'Stop'

	## Build the VM
	$vmparams = @{ 
		Type     = 'Web' 
		PassThru = $true
	}
	$vm = New-PowerLabVm @vmParams
	Install-IIS -ComputerName $vm.Name

	if ($AddToDomain.IsPresent) {
		$credConfig = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Users.where({ $_.Name -ne 'Administrator' })
		$domainUserName = '{0}\{1}' -f $script:LabConfiguration.ActiveDirectoryConfiguration.DomainName, $credConfig.name
		$domainCred = New-PSCredential -UserName $domainUserName -Password $credConfig.Password
		$addParams = @{
			ComputerName = $vm.Name
			DomainName   = $script:LabConfiguration.ActiveDirectoryConfiguration.DomainName
			Credential   = $domainCred
			Restart      = $true
			Force        = $true
		}
		Add-Computer @addParams
	}
	
}
function Install-IIS {
	[OutputType([void])]
	[CmdletBinding(SupportsShouldProcess)]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$ComputerName
	)

	$ErrorActionPreference = 'Stop'

	$null = InvokeVmCommand -ComputerName $ComputerName -ScriptBlock { Install-WindowsFeature -Name Web-Server }

	$webConfig = $script:LabConfiguration.DefaultServerConfiguration.Web
	NewIISAppPool -ComputerName $ComputerName -Name $webConfig.ApplicationPoolName
	NewIISWebsite -ComputerName $ComputerName -Name $webConfig.WebsiteName -ApplicationPool $webConfig.ApplicationPoolName
	
}
function NewIISAppPool {
	[OutputType('void')]
	[CmdletBinding(SupportsShouldProcess)]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$ComputerName,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Name
	)

	$ErrorActionPreference = 'Stop'

	$scriptBlock = {
		$null = Import-Module -Name 'WebAdministration'
		$appPoolPath = 'IIS:\AppPools\{0}' -f $Using:Name;
		if (-not (Test-Path -Path $appPoolPath)) {
			$null = New-Item -Path $appPoolPath -Force
		}
	}

	InvokeVmCommand -ComputerName $ComputerName -ScriptBlock $scriptBlock
}
function NewIISWebsite {
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$ComputerName,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Name,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$ApplicationPool
	)

	$ErrorActionPreference = 'Stop'

	$scriptBlock = {

		$null = Import-Module -Name 'WebAdministration'

		# Check if a physical path was specified or if one should be generated from the website name.
		# Build the full website physical path if not specified.
		$websitePhysicalPath = "C:\inetpub\sites\{0}" -f $Using:Name

		# Build the PSProvider path for the website.
		$websitePath = "IIS:\Sites\{0}" -f $Using:Name
		if (-not (Test-Path -Path $webSitePath)) {
			$appPoolPath = "IIS:\AppPools\{0}" -f $Using:ApplicationPool
			if (-not (Test-Path -Path $appPoolPath)) {
				throw "IIS application pool '{0}' does not exist." -f $Using:ApplicationPool
			}

			# Check if there are any existing websites. If not, we need to specify the ID, otherwise the action
			# will fail.
			if ((Get-ChildItem -Path IIS:\Sites).Count -eq 0) {
				$websiteParams = @{
					id = 1
				}
			}

			# Create the website with the specified parameters.
			$websiteParams += @{
				Path     = $websitePath
				bindings = @{
					protocol           = 'http'
					physicalPath       = $websitePhysicalPath
					bindingInformation = "*:80:$using:Name"
				}
			}

			$null = New-Item @websiteParams
		}

	}

	InvokeVmCommand -ComputerName $ComputerName -ScriptBlock $scriptBlock

}
function Install-PowerLabSqlServer {
	[OutputType([void])]
	[CmdletBinding(SupportsShouldProcess)]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$ComputerName
	)
	$ErrorActionPreference = 'Stop'

	try {
		$credConfig = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Users.where({ $_.Name -ne 'Administrator' })
		$cred = New-PSCredential -UserName $credConfig.name -Password $credConfig.Password
	
		## Copy the SQL server config ini to the VM
		$copiedConfigFile = Copy-Item -Path "$modulePath\SqlServer.ini" -Destination "\\$ComputerName\c$" -PassThru
		PrepareSqlServerInstallConfigFile -Path $copiedConfigFile

		$sqlConfigFilePath = $copiedConfigFile.FullName.Replace("\\$ComputerName\c$\", 'C:\')
		
		$isoConfig = $script:LabConfiguration.ISOs.where({$_.Name -eq 'SQL Server 2016'})
	
		$isoPath = Join-Path -Path $script:LabConfiguration.IsoFolderPath -ChildPath $isoConfig.FileName
		$uncIsoPath = ConvertToUncPath -LocalFilePath $isoPath -ComputerName $script:LabConfiguration.HostServer.Name
	
		## Copy the ISO to the VM
		$localDestIsoPath = 'C:\{0}' -f $isoConfig.FileName
		$destIsoPath = ConvertToUncPath -ComputerName $ComputerName -LocalFilePath $localDestIsoPath
		if (-not (Test-Path -Path $destIsoPath -PathType Leaf)) {
			Write-Verbose -Message "Copying SQL Server ISO to [$($destisoPath)]..."
			Copy-Item -Path $uncIsoPath -Destination $destIsoPath -Force
		}
	
		## Execute the installer
		Write-Verbose -Message 'Running SQL Server installer...'
		$icmParams = @{
			ComputerName = $ComputerName
			ArgumentList = $sqlConfigFilePath, $localDestIsoPath
			ScriptBlock  = {
				$image = Mount-DiskImage -ImagePath $args[1] -PassThru
				$installerPath = "$(($image | Get-Volume).DriveLetter):"
				$null = & "$installerPath\setup.exe" "/CONFIGURATIONFILE=$($args[0])"
				$image | Dismount-DiskImage
			}
		}
		InvokeVmCommand @icmParams
	} catch {
		$PSCmdlet.ThrowTerminatingError($_)
	} finally {
		Write-Verbose -Message 'Cleaning up installer remnants...'
		Remove-Item -Path $destIsoPath, $copiedConfigFile.FullName -Recurse -ErrorAction Ignore
	}
}
function WaitWinRM {
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$ComputerName,

		[Parameter()]
		[pscredential]$Credential,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[ValidateRange(1, [Int64]::MaxValue)]
		[int]$Timeout = 1500
	)
	
	try {
		$icmParams = @{
			ComputerName  = $ComputerName
			ScriptBlock   = { $true }
			SessionOption = (New-PSSessionOption -NoMachineProfile -OpenTimeout 20000 -SkipCACheck -SkipRevocationCheck) 
			ErrorAction   = 'SilentlyContinue'
			ErrorVariable = 'err'
		}

		if ($PSBoundParameters.ContainsKey('Credential')) {
			$icmParams.Credential = $Credential
		}

		$timer = [Diagnostics.Stopwatch]::StartNew()

		Wait-Ping -ComputerName $ComputerName -Timeout $Timeout

		while (-not (Invoke-Command @icmParams)) {
			Write-Verbose -Message "Waiting for [$($ComputerName)] to become available to WinRM..."
			if ($timer.Elapsed.TotalSeconds -ge $Timeout) {
				throw "Timeout exceeded. Giving up on WinRM availability to [$ComputerName]"
			}
			Start-Sleep -Seconds 10
		}
	} catch {
		$PSCmdlet.ThrowTerminatingError($_)
		$false
	} finally {
		if (Test-Path -Path Variable:\Timer) {
			$timer.Stop()
		}
	}
}
function PrepareSqlServerInstallConfigFile {
	[OutputType('void')]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Path
	)

	$ErrorActionPreference = 'Stop'

	$sqlConfig = $script:LabConfiguration.DefaultServerConfiguration.SQL

	$configContents = Get-Content -Path $Path -Raw
	$configContents = $configContents.Replace('SQLSVCACCOUNT=""', ('SQLSVCACCOUNT="{0}"' -f $sqlConfig.ServiceAccount.Name))
	$configContents = $configContents.Replace('SQLSVCPASSWORD=""', ('SQLSVCPASSWORD="{0}"' -f $sqlConfig.ServiceAccount.Password))
	$configContents = $configContents.Replace('SQLSYSADMINACCOUNTS=""', ('SQLSYSADMINACCOUNTS="{0}"' -f $sqlConfig.SystemAdministratorAccount.Name))
	Set-Content -Path $Path -Value $configContents
	
}
function New-PowerLabVm {
	[OutputType([void])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[ValidateSet('SQL', 'Web', 'Domain Controller')]
		[string]$Type,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[switch]$PassThru
	)

	$ErrorActionPreference = 'Stop'

	$name = GetNextLabVmName -Type $Type

	## Create the VM
	$scriptBlock = {
		$vmParams = @{
			Name               = $args[0]
			Path               = $args[1]
			MemoryStartupBytes = $args[2]
			Switch             = $args[3]
			Generation         = $args[4]
		}
		New-VM @vmParams
	}
	$argList = @(
		$name
		$script:LabConfiguration.DefaultVirtualMachineConfiguration.VMConfig.Path
		(Invoke-Expression -Command $script:LabConfiguration.DefaultVirtualMachineConfiguration.VMConfig.StartupMemory)
		(GetLabSwitch).Name
		$script:LabConfiguration.DefaultVirtualMachineConfiguration.VmConfig.Generation
	)
	$vm = InvokeHyperVCommand -Scriptblock $scriptBlock -ArgumentList $argList

	## Create the VHD and install Windows on the VM
	$os = @($script:LabConfiguration.VirtualMachines).where({$_.Type -eq $Type}).OS
	$addparams = @{
		Vm              = $vm
		OperatingSystem = $os
		VmType          = $Type
	}
	AddOperatingSystem @addparams

	InvokeHyperVCommand -Scriptblock { Start-Vm -Name $args[0] } -ArgumentList $name

	Add-TrustedHostComputer -ComputerName $name

	WaitWinRM -ComputerName $vm.Name

	## Enabling CredSSP support
	## Not using InvokeVMCommand here because we have to enable CredSSP first before it'll work
	$credConfig = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Users.where({ $_.Name -ne 'Administrator' })
	$localCred = New-PSCredential -UserName $credConfig.name -Password $credConfig.Password
	Invoke-Command -ComputerName $name -ScriptBlock { $null = Enable-WSManCredSSP -Role Server -Force } -Credential $localCred
	
	if ($PassThru.IsPresent) {
		$vm
	}
	
}
function New-PSCredential {
	[CmdletBinding()]
	[OutputType([System.Management.Automation.PSCredential])]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$UserName,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Password
	)

	$ErrorActionPreference = 'Stop'

	#region Build arguments
	$arguments = @($UserName)
	$arguments += ConvertTo-SecureString -String $Password -AsPlainText -Force
	#endregion Build arguments

	# Create a new credential object with the specified parameters.
	New-Object System.Management.Automation.PSCredential -ArgumentList $arguments
}
function AddCachedCredential {
	[OutputType('void')]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$ComputerName,
		
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[pscredential]$Credential
	)

	$ErrorActionPreference = 'Stop'

	if ((cmdkey /list:$ComputerName) -match '\* NONE \*') {
		$null = cmdkey /add:$ComputerName /user:($Credential.UserName) /pass:($Credential.GetNetworkCredential().Password)
	}
}
function RemoveCachedCredential {
	[OutputType([void])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$TargetName,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string[]]$ComputerName
	)

	if (-not $PSBoundParameters.ContainsKey('ComputerName')) {
		$null = cmdkey /delete:$TargetName
	} else {
		foreach ($c in $ComputerName) {
			$invParams = @{
				ComputerName = $c
				Command      = "cmdkey /delete:$TargetName"
			}
			$null = Invoke-PsExec @invParams
		}
	}
	
}
function ConvertToMatchValue {
	[OutputType('string')]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$String,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$RegularExpression
	)

	([regex]::Match($String, $RegularExpression)).Groups[1].Value
	
}
function ConvertToCachedCredential {
	[OutputType('pscustomobject')]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		$CmdKeyOutput
	)

	if (-not ($CmdKeyOutput.where({ $_ -match '\* NONE \*' }))) {
		if (@($CmdKeyOutput).Count -eq 1) {
			$CmdKeyOutput = $CmdKeyOutput -split "`n"
		}
		$nullsRemoved = $CmdKeyOutput.where({ $_ })
		$i = 0
		foreach ($j in $nullsRemoved) {
			if ($j -match '^\s+Target:') {
				[pscustomobject]@{
					Name        = (ConvertToMatchValue -String $j -RegularExpression 'Target: .+:target=(.*)$').Trim()
					Category    = (ConvertToMatchValue -String $j -RegularExpression 'Target: (.+):').Trim()
					Type        = (ConvertToMatchValue -String $nullsRemoved[$i + 1] -RegularExpression 'Type: (.+)$').Trim()
					User        = (ConvertToMatchValue -String $nullsRemoved[$i + 2] -RegularExpression 'User: (.+)$').Trim()
					Persistence = ($nullsRemoved[$i + 3]).Trim()
				}
			}
			$i++
		}
	}
}
function GetCachedCredential {
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string[]]$ComputerName,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$TargetName
	)

	if (-not $PSBoundParameters.ContainsKey('ComputerName') -and -not ($PSBoundParameters.ContainsKey('Name'))) {
		ConvertToCachedCredential -CmdKeyOutput (cmdkey /list)
	} elseif (-not $PSBoundParameters.ContainsKey('ComputerName') -and $PSBoundParameters.ContainsKey('Name')) {
		ConvertToCachedCredential -CmdKeyOutput (cmdkey /list:$TargetName)
	} else {
		foreach ($c in $ComputerName) {
			$cmdkeyOutput = Invoke-PsExec -ComputerName $c -Command 'cmdkey /list'
			if ($cred = ConvertToCachedCredential -CmdKeyOutput $cmdkeyOutput) {
				[pscustomobject]@{
					ComputerName = $c
					Credentials  = $cred
				}
			}
		}
	}
}
function TestIsIsoNameValid {
	[OutputType([bool])]
	[CmdletBinding(SupportsShouldProcess)]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Name
	)

	if ($Name -notin $script:LabConfiguration.ISOs.Name) {
		throw "The ISO with label '$Name' could not be found."
	} else {
		$true
	}
	
}
function TestIsOsNameValid {
	[OutputType([bool])]
	[CmdletBinding(SupportsShouldProcess)]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Name
	)

	if (($Name -notin ($script:LabConfiguration.ISOs | Where-Object { $_.Type -eq 'OS' }).Name)) {
		throw "The operating system name '$Name' is not valid."
	} else {
		$true
	}
	
}
function AddOperatingSystem {
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object]$Vm,
	
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[ValidateScript({ TestIsOsNameValid $_ })]
		[string]$OperatingSystem,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$VmType,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[switch]$DomainJoined
	)

	$ErrorActionPreference = 'Stop'

	try {
		$templateAnswerFilePath = (GetUnattendXmlFile -OperatingSystem $OperatingSystem).FullName
		$isoConfig = $script:LabConfiguration.ISOs.where({$_.Name -eq $OperatingSystem})
		
		$ipAddress = NewVmIpAddress
		$prepParams = @{
			Path         = $templateAnswerFilePath
			VMName       = $vm.Name
			IpAddress    = $ipAddress
			DnsServer    = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Network.DnsServer
			ProductKey   = $isoConfig.ProductKey
			UserName     = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Users.where({ $_.Name -ne 'Administrator' }).Name
			UserPassword = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Users.where({ $_.Name -ne 'Administrator' }).Password
			DomainName   = $script:LabConfiguration.ActiveDirectoryConfiguration.DomainName
		}
		if ($PSBoundParameters.ContainsKey('VmType')) {
			$prepParams.VmType = $VmType
		}
		$answerFile = PrepareUnattendXmlFile @prepParams

		if (-not ($vhd = NewLabVhd -OperatingSystem $OperatingSystem -AnswerFilePath $answerFile.FullName -Name $vm.Name -PassThru)) {
			throw 'VHD creation failed'
		}

		$invParams = @{
			Scriptblock  = {
				$vm = Get-Vm -Name $args[0]
				$vm | Add-VMHardDiskDrive -Path $args[1]
				$bootOrder = ($vm | Get-VMFirmware).Bootorder
				if ($bootOrder[0].BootType -ne 'Drive') {
					$vm | Set-VMFirmware -FirstBootDevice $vm.HardDrives[0]
				}
			}
			ArgumentList = $Vm.Name, $vhd.Path
		}
		InvokeHyperVCommand @invParams

		## Add the VM to the local hosts file
		if (-not (Get-HostsFileEntry | where {$_.HostName -eq $vm.Name})) {
			Add-HostsFileEntry -HostName $vm.Name -IpAddress $ipAddress -ErrorAction Ignore
		}

		## Add the cached credential the local computer
		$credConfig = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Users.where({ $_.Name -ne 'Administrator' })
		if ($DomainJoined.IsPresent) {
			$userName = '{0}\{1}' -f $script:LabConfiguration.ActiveDirectoryConfiguration.DomainName, $credConfig.name
		} else {
			$userName = $credConfig.name
			
			$cred = New-PSCredential -UserName $userName -Password $credConfig.Password
			AddCachedCredential -ComputerName $vm.Name -Credential $cred
		}
	} catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}
}
function ConvertToVirtualDisk {
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[ValidatePattern('\.vhdx?$')]
		[string]$VhdPath,
		
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$IsoFilePath,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$AnswerFilePath,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[ValidateSet('Dynamic', 'Fixed')]
		[string]$Sizing = $script:LabConfiguration.DefaultVirtualMachineConfiguration.VHDConfig.Sizing,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$Edition = $script:LabConfiguration.DefaultVirtualMachineConfiguration.VHDConfig.OSEdition,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[ValidateRange(512MB, 64TB)]
		[Uint64]$SizeBytes = (Invoke-Expression $script:LabConfiguration.DefaultVirtualMachineConfiguration.VHDConfig.Size),
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[ValidateSet('VHD', 'VHDX')]
		[string]$VhdFormat = $script:LabConfiguration.DefaultVirtualMachineConfiguration.VHDConfig.Type,
	
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$VHDPartitionStyle = $script:LabConfiguration.DefaultVirtualMachineConfiguration.VHDConfig.PartitionStyle
		
	)

	$ErrorActionPreference = 'Stop'

	$projectRootUnc = ConvertToUncPath -LocalFilePath $script:LabConfiguration.ProjectRootFolder -ComputerName $script:LabConfiguration.HostServer.Name
	Copy-Item -Path "$PSScriptRoot\Convert-WindowsImage.ps1" -Destination $projectRootUnc -Force
		
	## Copy the answer file to the Hyper-V host
	$answerFileName = $AnswerFilePath | Split-Path -Leaf
	Copy-Item -Path $AnswerFilePath -Destination $projectRootUnc -Force
	$localTempAnswerFilePath = Join-Path -Path ($projectrootunc -replace '.*(\w)\$', '$1:') -ChildPath $answerFileName
		
	$sb = {
		. $args[0]
		$convertParams = @{
			SourcePath        = $args[1]
			SizeBytes         = $args[2]
			Edition           = $args[3]
			VHDFormat         = $args[4]
			VHDPath           = $args[5]
			VHDType           = $args[6]
			VHDPartitionStyle = $args[7]
		}
		if ($args[8]) {
			$convertParams.UnattendPath = $args[8]
		}
		Convert-WindowsImage @convertParams
		Get-Vhd -Path $args[5]
	}

	$icmParams = @{
		ScriptBlock  = $sb
		ArgumentList = (Join-Path -Path $script:LabConfiguration.ProjectRootFolder -ChildPath 'Convert-WindowsImage.ps1'), $IsoFilePath, $SizeBytes, $Edition, $VhdFormat, $VhdPath, $Sizing, $VHDPartitionStyle, $localTempAnswerFilePath
	}
	InvokeHyperVCommand @icmParams
}
function NewLabVhd {
	[CmdletBinding(DefaultParameterSetName = 'None')]
	param
	(
		
		[Parameter(Mandatory, ParameterSetName = 'OSInstall')]
		[ValidateNotNullOrEmpty()]
		[string]$Name,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[ValidateRange(512MB, 1TB)]
		[int64]$Size = (Invoke-Expression $script:LabConfiguration.DefaultVirtualMachineConfiguration.VHDConfig.Size),
	
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[ValidateSet('Dynamic', 'Fixed')]
		[string]$Sizing = $script:LabConfiguration.DefaultVirtualMachineConfiguration.VHDConfig.Sizing,
	
		[Parameter(Mandatory, ParameterSetName = 'OSInstall')]
		[ValidateNotNullOrEmpty()]
		[ValidateScript({ TestIsOsNameValid $_ })]
		[string]$OperatingSystem,

		[Parameter(Mandatory, ParameterSetName = 'OSInstall')]
		[ValidateNotNullOrEmpty()]
		[string]$AnswerFilePath,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[switch]$PassThru
	)
	begin {
		$ErrorActionPreference = 'Stop'
	}
	process {
		try {	
			$params = @{
				'SizeBytes' = $Size
			}
			$vhdPath = $script:LabConfiguration.DefaultVirtualMachineConfiguration.VHDConfig.Path
			if ($PSBoundParameters.ContainsKey('OperatingSystem')) {
				$isoFileName = $script:LabConfiguration.ISOs.where({ $_.Name -eq $OperatingSystem }).FileName

				$cvtParams = $params + @{
					IsoFilePath    = Join-Path -Path $script:LabConfiguration.IsoFolderPath -ChildPath $isoFileName
					VhdPath        = '{0}.vhdx' -f (Join-Path -Path $vhdPath -ChildPath $Name)
					VhdFormat      = 'VHDX'
					Sizing         = $Sizing
					AnswerFilePath = $AnswerFilePath
				}
				
				$vhd = ConvertToVirtualDisk @cvtParams
			} else {
				$params.ComputerName = $script:LabConfiguration.HostServer.Name
				$params.Path = "$vhdPath\$Name.vhdx"
				if ($Sizing -eq 'Dynamic') {
					$params.Dynamic = $true
				} elseif ($Sizing -eq 'Fixed') {
					$params.Fixed = $true
				}

				$invParams = @{
					ScriptBlock  = { $params = $args[0]; New-VHD @params }
					ArgumentList = $params
				}
				$vhd = InvokeHyperVCommand @invParams
			}
			if ($PassThru.IsPresent) {
				$vhd
			}
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}
function NewVmIpAddress {
	[OutputType('string')]
	[CmdletBinding()]
	param
	()

	$ipNet = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Network.IpNetwork
	$ipBase = $ipNet -replace ".$($ipNet.Split('.')[-1])$"
	$randomLastOctet = Get-Random -Minimum 10 -Maximum 254
	$ipBase, $randomLastOctet -join '.'
	
}
function Get-PowerLabVhd {
	[CmdletBinding()]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$Name
	
	)
	try {
		$defaultVhdPath = $script:LabConfiguration.DefaultVirtualMachineConfiguration.VHDConfig.Path

		$icmParams = @{
			ScriptBlock  = { Get-ChildItem -Path $args[0] -File | foreach { Get-VHD -Path $_.FullName } }
			ArgumentList = $defaultVhdPath
		}
		InvokeHyperVCommand @icmParams
	} catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}
}
function Get-PowerLabVm {
	[CmdletBinding(DefaultParameterSetName = 'Name')]
	param
	(
		[Parameter(ParameterSetName = 'Name')]
		[ValidateNotNullOrEmpty()]
		[string]$Name,

		[Parameter(ParameterSetName = 'Type')]
		[ValidateNotNullOrEmpty()]
		[string]$Type
	
	)
	$ErrorActionPreference = 'Stop'

	$nameMatch = $script:LabConfiguration.VirtualMachines.BaseName -join '|'
	if ($PSBoundParameters.ContainsKey('Name')) {
		$nameMatch = $Name
	} elseif ($PSBoundParameters.ContainsKey('Type')) {
		$nameMatch = $Type
	}

	try {
		$icmParams = @{
			ScriptBlock  = { $name = $args[0]; @(Get-VM).where({ $_.Name -match $name }) }
			ArgumentList = $nameMatch
		}
		InvokeHyperVCommand @icmParams
	} catch {
		if ($_.Exception.Message -notmatch 'Hyper-V was unable to find a virtual machine with name') {
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
}
function InvokeVmCommand {
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$ComputerName,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[scriptblock]$ScriptBlock,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[object[]]$ArgumentList
	)

	$ErrorActionPreference = 'Stop'

	$credConfig = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Users.where({ $_.Name -ne 'Administrator' })
	$cred = New-PSCredential -UserName $credConfig.name -Password $credConfig.Password
	$icmParams = @{
		ComputerName   = $ComputerName 
		ScriptBlock    = $ScriptBlock
		Credential     = $cred
		Authentication = 'CredSSP'
	}
	if ($PSBoundParameters.ContainsKey('ArgumentList')) {
		$icmParams.ArgumentList = $ArgumentList
	}
	Invoke-Command @icmParams

	
}
function InvokeHyperVCommand {
	[CmdletBinding(SupportsShouldProcess)]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[scriptblock]$Scriptblock,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[object[]]$ArgumentList
	)

	$ErrorActionPreference = 'Stop'

	$icmParams = @{
		ScriptBlock  = $Scriptblock
		ArgumentList = $ArgumentList
	}
	
	if (-not (Get-Variable 'hypervSession' -Scope Script -ErrorAction Ignore)) {
		$script:hypervSession = New-PSSession -ComputerName $script:LabConfiguration.HostServer.Name
	}
	$icmParams.Session = $script:hypervSession
	
	Invoke-Command @icmParams

}
function GetLabSwitch {
	[OutputType('Microsoft.HyperV.PowerShell.VMSwitch')]
	[CmdletBinding()]
	param
	()

	$ErrorActionPreference = 'Stop'

	$switchConfig = $script:LabConfiguration.DefaultVirtualMachineConfiguration.VirtualSwitch

	$scriptBlock = {
		if ($args[1] -eq 'External') {
			Get-VmSwitch -SwitchType 'External'
		} else {
			Get-VmSwitch -Name $args[0] -SwitchType $args[1]
		}
	}
	InvokeHyperVCommand -Scriptblock $scriptBlock -ArgumentList $switchConfig.Name, $switchConfig.Type
}
function NewLabSwitch {
	[CmdletBinding()]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$Name = $script:LabConfiguration.DefaultVirtualMachineConfiguration.VirtualSwitch.Name,
	
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[ValidateSet('Internal', 'External')]
		[string]$Type = $script:LabConfiguration.DefaultVirtualMachineConfiguration.VirtualSwitch.Type
		
	)
	begin {
		$ErrorActionPreference = 'Stop'
	}
	process {
		try {
			$scriptBlock = {
				if ($args[1] -eq 'External') {
					if ($externalSwitch = Get-VmSwitch -SwitchType 'External') {
						$switchName = $externalSwitch.Name
					} else {
						$switchName = $args[0]
						$netAdapterName = (Get-NetAdapter -Physical| where { $_.Status -eq 'Up' }).Name
						$null = New-VMSwitch -Name $args[0] -NetAdapterName $netAdapterName
					}
				} else {
					$switchName = $args[0]
					if (-not (Get-VmSwitch -Name $args[0] -ErrorAction Ignore)) {
						$null = New-VMSwitch -Name $args[0] -SwitchType $args[1]
					}
				}
			}
			InvokeHyperVCommand -Scriptblock $scriptBlock -ArgumentList $Name, $Type
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}
function ConvertToUncPath {
	<#
		.SYNOPSIS
			A simple function to convert a local file path and a computer name to a network UNC path.

		.PARAMETER LocalFilePath
			A file path ie. C:\Windows\somefile.txt

		.PARAMETER Computername
			One or more computers in which the file path exists on
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]$LocalFilePath,
		
		[Parameter(Mandatory)]
		[string[]]$ComputerName
	)
	process {
		try {
			foreach ($Computer in $ComputerName) {
				$RemoteFilePathDrive = ($LocalFilePath | Split-Path -Qualifier).TrimEnd(':')
				"\\$Computer\$RemoteFilePathDrive`$$($LocalFilePath | Split-Path -NoQualifier)"
			}
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}
function GetNextLabVmName {
	[OutputType('string')]
	[CmdletBinding(SupportsShouldProcess)]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Type
	)

	if (-not ($types = @($script:LabConfiguration.VirtualMachines).where({$_.Type -eq $Type}))) {
		throw "Unrecognize VM type: [$($Type)]"
	}

	if (-not ($highNumberVm = Get-PowerLabVm -Type $Type | Select -ExpandProperty Name | Sort-Object -Descending | Select-Object -First 1)) {
		$nextNum = 1
	} else {
		[int]$highNum = [regex]::matches($highNumberVm, '(\d+)$').Groups[1].Value
		$nextNum = $highNum + 1
	}

	$baseName = $types.BaseName
	
	'{0}{1}' -f $baseName, $nextNum
}
function Add-TrustedHostComputer {
	[CmdletBinding()]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string[]]$ComputerName
			
	)
	try {
		foreach ($c in $ComputerName) {
			Write-Verbose -Message "Adding [$($c)] to client WSMAN trusted hosts"
			$TrustedHosts = (Get-Item -Path WSMan:\localhost\Client\TrustedHosts).Value
			if (-not $TrustedHosts) {
				Set-Item -Path wsman:\localhost\Client\TrustedHosts -Value $c -Force
			} elseif (($TrustedHosts -split ',') -notcontains $c) {
				$TrustedHosts = ($TrustedHosts -split ',') + $c
				Set-Item -Path wsman:\localhost\Client\TrustedHosts -Value ($TrustedHosts -join ',') -Force
			}
		}
	} catch {
		Write-Error $_.Exception.Message
	}
}
function GetUnattendXmlFile {
	[OutputType('System.IO.FileInfo')]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[ValidateScript({ TestIsOsNameValid $_ })]
		[string]$OperatingSystem
	)

	$ErrorActionPreference = 'Stop'

	Get-ChildItem -Path "$PSScriptRoot\AutoUnattend" -Filter "$OperatingSystem.xml"

}		
function PrepareUnattendXmlFile {
	[OutputType('System.IO.FileInfo')]
	[CmdletBinding(SupportsShouldProcess)]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$Path,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$VMName,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$IpAddress,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$DnsServer,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$DomainName,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$ProductKey,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$UserName,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$UserPassword,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$VmType
	)

	$ErrorActionPreference = 'Stop'

	## Make a copy of the unattend XML
	$tempUnattend = Copy-Item -Path $Path -Destination $env:TEMP -PassThru -Force

	## Prep the XML object
	$unattendText = Get-Content -Path $tempUnattend.FullName -Raw
	$xUnattend = ([xml]$unattendText)
	$ns = New-Object System.Xml.XmlNamespaceManager($xunattend.NameTable)
	$ns.AddNamespace('ns', $xUnattend.DocumentElement.NamespaceURI)

	if ($VmType -eq 'Domain Controller') {
		$dnsIp = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Network.DnsServer
		$xUnattend.SelectSingleNode('//ns:Interface/ns:UnicastIpAddresses/ns:IpAddress', $ns).InnerText = "$dnsIp/24"
		$xUnattend.SelectSingleNode('//ns:DNSServerSearchOrder/ns:IpAddress', $ns).InnerText = $dnsIp
	} else {
		# Insert the NIC configuration
		$xUnattend.SelectSingleNode('//ns:Interface/ns:UnicastIpAddresses/ns:IpAddress', $ns).InnerText = "$IpAddress/24"
		$xUnattend.SelectSingleNode('//ns:DNSServerSearchOrder/ns:IpAddress', $ns).InnerText = $DnsServer
	}

	## Insert the correct product key
	$xUnattend.SelectSingleNode('//ns:ProductKey', $ns).InnerText = $ProductKey
	
	# ## Insert the user names and password
	$localuser = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Users.where({ $_.Name -ne 'Administrator' })
	$xUnattend.SelectSingleNode('//ns:LocalAccounts/ns:LocalAccount/ns:Password/ns:Value[text()="XXXX"]', $ns).InnerXml  = $localuser.Password
	$xUnattend.SelectSingleNode('//ns:LocalAccounts/ns:LocalAccount/ns:Name[text()="XXXX"]', $ns).InnerXml  = $localuser.Name

	$userxPaths = '//ns:FullName', '//ns:Username'
	$userxPaths | foreach {
		$xUnattend.SelectSingleNode($_, $ns).InnerXml = $UserName
	}

	## Change the local admin password
	$localadmin = $script:LabConfiguration.DefaultOperatingSystemConfiguration.Users.where({ $_.Name -eq 'Administrator' })
	$xUnattend.SelectSingleNode('//ns:LocalAccounts/ns:LocalAccount/ns:Name[text()="Administrator"]', $ns).InnerText = $localadmin.Password
	
	$netUserCmd = $xUnattend.SelectSingleNode('//ns:FirstLogonCommands/ns:SynchronousCommand/ns:CommandLine[text()="net user administrator XXXX"]', $ns)
	$netUserCmd.InnerText = $netUserCmd.InnerText.Replace('XXXX', $localadmin.Password)

	## Set the lab user autologon
	$xUnattend.SelectSingleNode('//ns:AutoLogon/ns:Password/ns:Value', $ns).InnerText = $UserPassword

	## Insert the host name
	$xUnattend.SelectSingleNode('//ns:ComputerName', $ns).InnerText = $VMName

	## Set the domain names
	$xUnattend.SelectSingleNode('//ns:DNSDomain', $ns) | foreach { $_.InnerText = $DomainName }

	## Save the config back to the XML file
	$xUnattend.Save($tempUnattend.FullName)

	$tempUnattend
}
function Add-HostsFileEntry {
	[CmdletBinding()]
	param
	(
		
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[ValidatePattern('^[^\.]+$')]
		[string]$HostName,
		
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[ipaddress]$IpAddress,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$Comment,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$ComputerName = $env:COMPUTERNAME,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[pscredential]$Credential,
	
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$HostFilePath = "$env:SystemRoot\System32\drivers\etc\hosts"
		
				
	)
	begin {
		$ErrorActionPreference = 'Stop'
	}
	process {
		try {
			$IpAddress = $IpAddress.IPAddressToString
			
			$getParams = @{ }
			if ($ComputerName -ne $env:COMPUTERNAME) {
				$getParams.ComputerName = $ComputerName
				$getParams.Credential = $Credential
			}
			
			$existingHostEntries = Get-HostsFileEntry @getParams
			
			if ($result = $existingHostEntries | where HostName -EQ $HostName) {
				throw "The hostname [$($HostName)] already exists in the host file with IP [$($result.IpAddress)]"
			} elseif ($result = $existingHostEntries | where IPAddress -EQ $IpAddress) {
				Write-Warning "The IP address [$($result.IPAddress)] already exists in the host file for the hostname [$($HostName)]. You should probabloy remove the old one hostname reference."
			}
			$vals = @(
				$IpAddress
				$HostName
			)
			if ($PSBoundParameters.ContainsKey('Comment')) {
				$vals += "# $Comment"
			}
			
			$sb = {
				param($HostFilePath, $vals)
				
				## If the hosts file doesn't end with a blank line, make it so
				if ((Get-Content -Path $HostFilePath -Raw) -notmatch '\n$') {
					Add-Content -Path $HostFilePath -Value ''
				}
				Add-Content -Path $HostFilePath -Value ($vals -join "`t")
			}
			
			if ($ComputerName -eq (hostname)) {
				& $sb $HostFilePath $vals
			} else {
				$icmParams = @{
					'ComputerName' = $ComputerName
					'ScriptBlock'  = $sb
					'ArgumentList' = $HostFilePath, $vals
				}
				if ($PSBoundParameters.ContainsKey('Credential')) {
					$icmParams.Credential = $Credential
				}
				[pscustomobject](Invoke-Command @icmParams)
			}
			
			
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}
function Get-HostsFileEntry {
	[CmdletBinding()]
	[OutputType([System.Management.Automation.PSCustomObject])]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$ComputerName = $env:COMPUTERNAME,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[pscredential]$Credential,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$HostFilePath = "$env:SystemRoot\System32\drivers\etc\hosts"
		
	)
	begin {
		$ErrorActionPreference = 'Stop'
	}
	process {
		try {
			$sb = {
				param($HostFilePath)
				$regex = '^(?<ipAddress>[0-9.]+)[^\w]*(?<hostname>[^#\W]*)($|[\W]{0,}#\s+(?<comment>.*))'
				$matches = $null
				Get-Content -Path $HostFilePath | foreach {
					$null = $_ -match $regex
					if ($matches) {
						$output = @{
							'IPAddress' = $matches.ipAddress
							'HostName'  = $matches.hostname
						}
						if ('comment' -in $matches.PSObject.Properties.Name) {
							$output.Comment = $matches.comment
						}
						$output
					}
					$matches = $null
				}
			}
			
			if ($ComputerName -eq (hostname)) {
				& $sb $HostFilePath
			} else {
				$icmParams = @{
					'ComputerName' = $ComputerName
					'ScriptBlock'  = $sb
					'ArgumentList' = $HostFilePath
				}
				if ($PSBoundParameters.ContainsKey('Credential')) {
					$icmParams.Credential = $Credential
				}
				[pscustomobject](Invoke-Command @icmParams)
			}
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}
function Remove-HostsFileEntry {
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[ValidatePattern('^[^\.]+$')]
		[string]$HostName,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$HostFilePath = "$env:SystemRoot\System32\drivers\etc\hosts"
	)
	begin {
		$ErrorActionPreference = 'Stop'
	}
	process {
		try {
			if (Get-HostsFileEntry | where HostName -EQ $HostName) {
				$regex = "^(?<ipAddress>[0-9.]+)[^\w]*($HostName)(`$|[\W]{0,}#\s+(?<comment>.*))"
				$toremove = (Get-Content -Path $HostFilePath | select-string -Pattern $regex).Line
				## Safer to create a temp file
				$tempFile = [System.IO.Path]::GetTempFileName()
				(Get-Content -Path $HostFilePath | where { $_ -ne $toremove }) | Add-Content -Path $tempFile
				if (Test-Path -Path $tempFile -PathType Leaf) {
					Remove-Item -Path $HostFilePath
					Move-Item -Path $tempFile -Destination $HostFilePath
				}
			} else {
				Write-Warning -Message "No hostname found for [$($HostName)]"
			}
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}
function Set-HostsFileEntry {
	[CmdletBinding()]
	param
	(
		
	)
	begin {
		$ErrorActionPreference = 'Stop'
	}
	process {
		try {
				
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}
function Wait-Ping {
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$ComputerName,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[switch]$Offline,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[ValidateRange(1, [Int64]::MaxValue)]
		[int]$Timeout = 1500
	)

	$ErrorActionPreference = 'Stop'
	try {
		$timer = [Diagnostics.Stopwatch]::StartNew()
		if ($Offline.IsPresent) {
			while ((ping $ComputerName -n 2) -match 'Lost = 0') {
				Write-Verbose -Message "Waiting for [$($ComputerName)] to go offline..."
				if ($timer.Elapsed.TotalSeconds -ge $Timeout) {
					throw "Timeout exceeded. Giving up on [$ComputerName] going offline";
				}
				Start-Sleep -Seconds 10;
			}
		} else {
			## Using good ol' fashioned ping.exe because it just uses ICMP. Test-Connection uses CIM and NetworkInformation.Ping sometimes hangs
			while (-not ((ping $ComputerName -n 2) -match 'Lost = 0')) {
				Write-Verbose -Message "Waiting for [$($ComputerName)] to become pingable..."
				if ($timer.Elapsed.TotalSeconds -ge $Timeout) {
					throw "Timeout exceeded. Giving up on ping availability to [$ComputerName]";
				}
				Start-Sleep -Seconds 10;
			}
		}
	} catch {
		$PSCmdlet.ThrowTerminatingError($_)
	} finally {
		if (Test-Path -Path Variable:\Timer) {
			$timer.Stop();
		}
	}
}