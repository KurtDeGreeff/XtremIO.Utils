<#	.Description
	Script to launch the XtremIO Java management console.  Assumes that *.jnlp files are associated w/ the proper Java WebStart app; Feb 2014
	.Example
	Open-XIOMgmtConsole -Computer somexmsappl01.dom.com
	Downloads the .jnlp file for launching the Java console for this XMS appliance, then tries to launch the console by calling the program associated with .jnlp files (should be Java WebStart or the likes)
	.Example
	Open-XIOMgmtConsole -TrustAllCert -Computer somenewerxmsappl10.dom.com
	Downloads the .jnlp file for launching the Java console for this XMS appliance, trusting the certificate for this interaction, then tries to launch the console by calling the program associated with .jnlp files (should be Java WebStart or the likes)
	.Example
	Open-XIOMgmtConsole -Computer somexmsappl02.dom.com -DownloadOnly
	Downloads the .jnlp file for launching the Java console for this XMS appliance
#>
function Open-XIOMgmtConsole {
	[CmdletBinding()]
	param(
		## Name(s) of XMS appliances for which to launch the Java management console
		[parameter(Mandatory=$true)][string[]]$ComputerName_arr,
		## switch: Trust all certs?  Not necessarily secure, but can be used if the XMS appliance is known/trusted, and has, say, a self-signed cert
		[switch]$TrustAllCert_sw,
		## switch:  Download the JNLP files only?  default is to open the files with the associate program
		[switch]$DownloadOnly_sw
	) ## end param

	Begin {
		## string to add to messages written by this function; function name in square brackets
		$strLogEntry_ToAdd = "[$($MyInvocation.MyCommand.Name)]"
	} ## end begin

	Process {
		$ComputerName_arr | %{
			$strThisXmsName = $_
			## make sure this name is legit (in DNS)
			Try {$oIpAddress = [System.Net.DNS]::GetHostAddresses($strThisXmsName)}
			Catch [System.Net.Sockets.SocketException] {Write-Warning "'$strThisXmsName' not found in DNS. Valid name?"; break;}

			## place to which to download this JNLP file
			$strDownloadFilespec = Join-Path ${env:\temp} "${strThisXmsName}.jnlp"
			$strJnlpFileUri = "http://$strThisXmsName/xtremapp/webstart.jnlp"
			$oWebClient = New-Object System.Net.WebClient
			## if specified to do so, set session's CertificatePolicy to trust all certs (for now; will revert to original CertificatePolicy)
			if ($true -eq $TrustAllCert_sw) {Write-Verbose "$strLogEntry_ToAdd setting ServerCertificateValidationCallback method temporarily so as to 'trust' certs (should only be used if certs are known-good / trustworthy)"; $oOrigServerCertValidationCallback = Disable-CertValidation}

			try {
				$oWebClient.DownloadFile($strJnlpFileUri, $strDownloadFilespec)
				## if not DownloadOnly switch, open the item
				if ($DownloadOnly_sw) {Write-Verbose -Verbose "downloaded to '$strDownloadFilespec'"} else {Invoke-Item $strDownloadFilespec}
			} catch {Write-Error $_}

			## if CertValidationCallback was altered, set back to original value
			if ($true -eq $TrustAllCert_sw) {
				[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $oOrigServerCertValidationCallback
				Write-Verbose "$strLogEntry_ToAdd set ServerCertificateValidationCallback back to original value of '$oOrigServerCertValidationCallback'"
			} ## end if
		} ## end foreach-object
	} ## end process
} ## end function

<#	.Description
	Function to get the stored, encrypted credentials from file (if one exists)
	.Example
	Get-XIOStoredCred
	.Outputs
	System.Management.Automation.PSCredential or none
#>
function Get-XIOStoredCred {
	[CmdletBinding()][OutputType([System.Management.Automation.PSCredential])]param()

	Process {
		if (Test-Path $hshCfg["EncrCredFilespec"]) {
			try {$credImportedXioCred = hImport-PSCredential $hshCfg["EncrCredFilespec"]} ## end try
			catch {
				#Write-Error -ErrorRecord $_
			} ## end catch
			if ($null -ne $credImportedXioCred) {return $credImportedXioCred} else {Write-Verbose "Could not import credential from file '$($hshCfg["EncrCredFilespec"])'. Valid credential file?"}
		} ## end if
		else {Write-Verbose "No stored XIO credential found at '$($hshCfg["EncrCredFilespec"])'"}
	} ## end process
} ## end function


<#	.Description
	Function to create a new stored, encrypted credentials file
	.Example
	New-XIOStoredCred -Credential $credMyStuff
	.Outputs
	None or System.Management.Automation.PSCredential
#>
function New-XIOStoredCred {
	[OutputType("null",[System.Management.Automation.PSCredential])]
	param(
		## The credential to encrypt; if none, will prompt
		[System.Management.Automation.PSCredential]$Credential = (Get-Credential -Message "Enter credentials to use for XtremIO access"),
		## switch: Pass the credentials through, returning back to caller?
		[switch]$PassThru_sw
	) ## end param
	hExport-PSCredential -Credential $Credential -Path $hshCfg["EncrCredFilespec"]
	if ($true -eq $PassThru_sw) {$Credential}
} ## end function


<#	.Description
	Function to remove the stored, encrypted credentials file (if one exists)
	.Example
	Remove-XIOStoredCred -WhatIf
	Perform WhatIf run of removing the credentials (without actually removing them)
	.Outputs
	None
#>
function Remove-XIOStoredCred {
	[CmdletBinding(SupportsShouldProcess=$true)]param()
	begin {$strStoredXioCredFilespec = $hshCfg["EncrCredFilespec"]}
	process {
		if (Test-Path $strStoredXioCredFilespec) {
			if ($PSCmdlet.ShouldProcess($strStoredXioCredFilespec, "Remove file")) {
				Remove-Item $strStoredXioCredFilespec -Force
			} ## end if
		} else {Write-Warning "Creds file '$strStoredXioCredFilespec' does not exist; no action to take"}
	} ## end process
} ## end function


<#	.Description
	Function to make a "connection" to an XtremIO XMS machine, such that subsequent interactions with that XMS machine will not require additional credentials be supplied.  Updates PowerShell title bar to show connection information
	.Example
	Connect-XIOServer somexms02.dom.com
	Connect to the given XMS server.  Will prompt for credential to use
	.Example
	Connect-XIOServer -Credential $credMe -ComputerName somexms01.dom.com -Port 443 -TrustAllCert
	Connect to the given XMS server using the given credential.  "TrustAllCert" parameter is useful when the XMS appliance has a self-signed cert that will not be found valid, but that is trusted to be legit
#>
function Connect-XIOServer {
	[CmdletBinding()]
	[OutputType([XioItemInfo.XioConnection])]
	param(
		## Credential for connecting to XMS appliance; if a credential has been encrypted and saved, this will automatically use that credential
		[System.Management.Automation.PSCredential]$Credential = $(_Find-CredentialToUse),
		## XMS appliance address to which to connect
		[parameter(Mandatory=$true,Position=0)][string[]]$ComputerName,
		## Port to use for API call (if none, will try to autodetect proper port; may be slightly slower due to port probe activity)
		[int]$Port,
		## switch: Trust all certs?  Not necessarily secure, but can be used if the XMS appliance is known/trusted, and has, say, a self-signed cert
		[switch]$TrustAllCert
	) ## end param
	begin {
		## if the global connection info variable does not yet exist, initialize it
		if ($null -eq $Global:DefaultXmsServers) {$Global:DefaultXmsServers = @()}
		## args for the Get-XIOInfo call, and for New-XioApiURI call
		$hshArgsForGetXIOInfo = @{Credential = $Credential}; $hshArgsForNewXioApiURI = @{RestCommand = "/types"; ReturnURIAndPortInfo = $true; TestPort = $true}
		if ($TrustAllCert) {$hshArgsForGetXIOInfo["TrustAllCert"] = $true}
		if ($PSBoundParameters.ContainsKey("Port")) {$hshArgsForGetXIOInfo["Port"] = $Port; $hshArgsForNewXioApiURI["Port"] = $Port}
	} ## end begin
	process {
		$ComputerName | Foreach-Object {
			$strThisXmsName = $_
			## if the global var already holds connection info for this XMS machine
			if ($Global:DefaultXmsServers | Where-Object {$_.ComputerName -eq $strThisXmsName}) {Write-Verbose "already connected to '$strThisXmsName'"}
			else {
				Try {
					## get the URI and Port that should be used for this connection
					$strTmpUriInfo, $intPortToUse = New-XioApiURI -ComputerName $strThisXmsName @hshArgsForNewXioApiURI
					## get the XIO info object for this XMS machine
					$oThisXioInfo = Get-XIOInfo -ComputerName $strThisXmsName @hshArgsForGetXIOInfo
					if ($null -ne $oThisXioInfo) {
						 $oTmpThisXmsConnection = New-Object -Type XioItemInfo.XioConnection -Property ([ordered]@{
							ComputerName = $strThisXmsName
							#XIOSSwVersion = $oThisXioInfo.SWVersion
							ConnectDatetime = (Get-Date)
							Port = $intPortToUse
							Credential = $Credential
							TrustAllCert = if ($TrustAllCert) {$true} else {$false}
						}) ## end New-Object
						## add connection object to global connection variable
						$Global:DefaultXmsServers += $oTmpThisXmsConnection
						## update PowerShell window titlebar
						Update-TitleBarForXioConnection
						## return the connection object
						$oTmpThisXmsConnection
					} ## end if
					else {"Unable to connect to XMS machine '$strThisXmsName'. What the"}
				} ## end try
				Catch {Write-Error "Failed to connect to XMS '$strThisXmsName'.  See error below for details"; Throw $_}
			} ## end else
		} ## end Foreach-Object
	} ## end process
} ## end function


<#	.Description
	Function to remove a "connection" that exists to an XtremIO XMS machine
	.Example
	Disconnect-XIOServer somexms02.*
	Disconnect from the given XMS server
	.Example
	Disconnect-XIOServer
	Disconnect from all connected XMS servers
#>
function Disconnect-XIOServer {
	[CmdletBinding()]
	param(
		## XMS appliance address from which to disconnect
		[parameter(Position=0)][string[]]$ComputerName = "*"
	)
	process {
		$ComputerName | Foreach-Object {
			$strThisXmsName = $_
			$arrXmsServerFromWhichToDisconnect = $Global:DefaultXmsServers | Where-Object {$_.ComputerName -like $strThisXmsName}
			## if connected to such an XMS machine, take said connection out of the global variable
			if ($arrXmsServerFromWhichToDisconnect) {
				$Global:DefaultXmsServers = @($Global:DefaultXmsServers | Where-Object {$_.ComputerName -notlike $strThisXmsName})
				## update PowerShell window titlebar
				Update-TitleBarForXioConnection
			} ## end if
			else {Write-Warning "Not connected to any XMS machine whose name is like '$strThisXmsName'. No action taken"}
		} ## end Foreach-Object
	} ## end process
} ## end function
