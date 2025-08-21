$UnattendXml = @'
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
<!-- https://schneegans.de/windows/unattend-generator/?LanguageMode=Unattended&UILanguage=en-US&Locale=en-US&Keyboard=00000409&GeoLocation=244&ProcessorArchitecture=amd64&ComputerNameMode=Random&CompactOsMode=Default&TimeZoneMode=Explicit&TimeZone=Central+Standard+Time&PartitionMode=Interactive&DiskAssertionMode=Skip&WindowsEditionMode=Firmware&InstallFromMode=Automatic&PEMode=Default&UserAccountMode=Unattended&AutoLogonMode=Builtin&BuiltinAdministratorPassword=green%21clock%21purple%21rectangle2&PasswordExpirationMode=Unlimited&LockoutMode=Default&HideFiles=Hidden&TaskbarSearch=Box&TaskbarIconsMode=Default&StartTilesMode=Default&StartPinsMode=Default&EffectsMode=Default&DesktopIconsMode=Default&StartFoldersMode=Default&WifiMode=Interactive&ExpressSettings=DisableAll&LockKeysMode=Skip&StickyKeysMode=Default&ColorMode=Default&WallpaperMode=Default&LockScreenMode=Default&WdacMode=Skip -->
<settings pass="offlineServicing"/>
<settings pass="windowsPE">
<component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
<SetupUILanguage>
<UILanguage>en-US</UILanguage>
</SetupUILanguage>
<InputLocale>0409:00000409</InputLocale>
<SystemLocale>en-US</SystemLocale>
<UILanguage>en-US</UILanguage>
<UserLocale>en-US</UserLocale>
</component>
<component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
<UserData>
<ProductKey>
<Key>00000-00000-00000-00000-00000</Key>
<WillShowUI>OnError</WillShowUI>
</ProductKey>
<AcceptEula>true</AcceptEula>
</UserData>
<UseConfigurationSet>false</UseConfigurationSet>
</component>
</settings>
<settings pass="generalize"/>
<settings pass="specialize">
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
<TimeZone>Central Standard Time</TimeZone>
</component>
<component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
<RunSynchronous>
<RunSynchronousCommand wcm:action="add">
<Order>1</Order>
<Path>powershell.exe -WindowStyle Normal -NoProfile -Command "$xml = [xml]::new(); $xml.Load('C:\Windows\Panther\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;"</Path>
</RunSynchronousCommand>
<RunSynchronousCommand wcm:action="add">
<Order>2</Order>
<Path>powershell.exe -WindowStyle Normal -NoProfile -Command "Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\Specialize.ps1' -Raw | Invoke-Expression;"</Path>
</RunSynchronousCommand>
</RunSynchronous>
</component>
</settings>
<settings pass="auditSystem"/>
<settings pass="auditUser"/>
<settings pass="oobeSystem">
<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
<InputLocale>0409:00000409</InputLocale>
<SystemLocale>en-US</SystemLocale>
<UILanguage>en-US</UILanguage>
<UserLocale>en-US</UserLocale>
</component>
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
<UserAccounts>
<AdministratorPassword>
<Value>green!clock!purple!rectangle2</Value>
<PlainText>true</PlainText>
</AdministratorPassword>
</UserAccounts>
<AutoLogon>
<Username>Administrator</Username>
<Enabled>true</Enabled>
<LogonCount>1</LogonCount>
<Password>
<Value>green!clock!purple!rectangle2</Value>
<PlainText>true</PlainText>
</Password>
</AutoLogon>
<OOBE>
<ProtectYourPC>3</ProtectYourPC>
<HideEULAPage>true</HideEULAPage>
<HideWirelessSetupInOOBE>false</HideWirelessSetupInOOBE>
<HideOnlineAccountScreens>false</HideOnlineAccountScreens>
</OOBE>
<FirstLogonCommands>
<SynchronousCommand wcm:action="add">
<Order>1</Order>
<CommandLine>powershell.exe -WindowStyle Normal -NoProfile -Command "Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\FirstLogon.ps1' -Raw | Invoke-Expression;"</CommandLine>
</SynchronousCommand>
</FirstLogonCommands>
</component>
</settings>
<Extensions xmlns="https://schneegans.de/windows/unattend-generator/">
<ExtractScript> param( [xml] $Document ); foreach( $file in $Document.unattend.Extensions.File ) { $path = [System.Environment]::ExpandEnvironmentVariables( $file.GetAttribute( 'path' ) ); mkdir -Path( $path | Split-Path -Parent ) -ErrorAction 'SilentlyContinue'; $encoding = switch( [System.IO.Path]::GetExtension( $path ) ) { { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; } { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new( $false, $true ); } default { [System.Text.Encoding]::Default; } }; $bytes = $encoding.GetPreamble() + $encoding.GetBytes( $file.InnerText.Trim() ); [System.IO.File]::WriteAllBytes( $path, $bytes ); } </ExtractScript>
<File path="C:\Windows\Setup\Scripts\Specialize.ps1"> $scripts = @( { net.exe accounts /maxpwage:UNLIMITED; }; ); & { [float] $complete = 0; [float] $increment = 100 / $scripts.Count; foreach( $script in $scripts ) { Write-Progress -Activity 'Running scripts to customize your Windows installation. Do not close this window.' -PercentComplete $complete; '*** Will now execute command «{0}».' -f $( $str = $script.ToString().Trim() -replace '\s+', ' '; $max = 100; if( $str.Length -le $max ) { $str; } else { $str.Substring( 0, $max - 1 ) + '…'; } ); $start = [datetime]::Now; & $script; '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds; "`r`n" * 3; $complete += $increment; } } *>&1 >> "C:\Windows\Setup\Scripts\Specialize.log"; </File>
<File path="C:\Windows\Setup\Scripts\FirstLogon.ps1"> $scripts = @( { Set-ItemProperty -LiteralPath 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoLogonCount' -Type 'DWord' -Force -Value 0; }; ); & { [float] $complete = 0; [float] $increment = 100 / $scripts.Count; foreach( $script in $scripts ) { Write-Progress -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete; '*** Will now execute command «{0}».' -f $( $str = $script.ToString().Trim() -replace '\s+', ' '; $max = 100; if( $str.Length -le $max ) { $str; } else { $str.Substring( 0, $max - 1 ) + '…'; } ); $start = [datetime]::Now; & $script; '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds; "`r`n" * 3; $complete += $increment; } } *>&1 >> "C:\Windows\Setup\Scripts\FirstLogon.log"; </File>
</Extensions>
</unattend>
'@ 

if (-NOT (Test-Path 'C:\Windows\Panther')) {
    New-Item -Path 'C:\Windows\Panther'-ItemType Directory -Force -ErrorAction Stop | Out-Null
}

$Panther = 'C:\Windows\Panther'
$UnattendPath = "$Panther\Unattend.xml"
$UnattendXml | Out-File -FilePath $UnattendPath -Encoding utf8 -Width 2000 -Force
