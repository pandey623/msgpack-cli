param([Switch]$Rebuild)

if ( $env:APPVEYOR -eq "True" )
{
	[string]$builder = "MSBuild.exe"
	[string]$winBuilder = "MSBuild.exe"
	[string]$nuget = "nuget"
	
	# AppVeyor should have right MSBuild and dotnet-cli...
}
else
{
	./SetBuildEnv.ps1
	[string]$builder = "$env:windir\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe"
	[string]$winBuilder = "${env:ProgramFiles(x86)}\MSBuild\14.0\Bin\MSBuild.exe"
	[string]$nuget = "../.nuget/nuget.exe"

	if ( !( Test-Path( "$winBuilder" ) ) )
	{
		$winBuilder = "${env:ProgramFiles}\MSBuild\14.0\Bin\MSBuild.exe"
	}
	if ( !( Test-Path( "$winBuilder" ) ) )
	{
		Write-Error "MSBuild v14 is required."
		exit 1
	}

	if ( !( Test-Path( "${env:ProgramFiles}\dotnet\dotnet.exe" ) ) )
	{
		Write-Error "DotNet CLI is required."
		exit 1
	}
}

[string]$androidTool = "$env:localappdata\Android\android-sdk\tools\android.bat"

if ( !( Test-Path $androidTool ) )
{
	Write-Error "ADK is required."
	exit 1
}

# Ensure Android SDK for API level 10 is installed.
# Thanks to http://help.appveyor.com/discussions/problems/3177-how-to-add-more-android-sdks-to-build-agents
$adkIndexes = 
	& $androidTool list sdk --all |% { 
		if ( $_ -match '(?<index>\d+)- (?<sdk>.+), revision (?<revision>[\d\.]+)' ) { 
			$sdk = New-Object PSObject 
			Add-Member -InputObject $sdk -MemberType NoteProperty -Name Index -Value $Matches.index 
			Add-Member -InputObject $sdk -MemberType NoteProperty -Name Name -Value $Matches.sdk 
			Add-Member -InputObject $sdk -MemberType NoteProperty -Name Revision -Value $Matches.revision 
			$sdk
		}
	} |? { $_.name -like 'sdk platform*API 10*' -or $_.name -like 'google apis*api 10' } |% { $_.Index }

Echo 'y' | & $androidTool update sdk -u -a -t ( [String]::Join( ',', $adkIndexes ) )

[string]$buildConfig = 'Release'
if ( ![String]::IsNullOrWhitespace( $env:CONFIGURATION ) )
{
	$buildConfig = $env:CONFIGURATION
}

[string]$sln = '../MsgPack.sln'
[string]$slnCompat = '../MsgPack.compats.sln'
[string]$slnWindows = '../MsgPack.Windows.sln'
[string]$slnXamarin = '../MsgPack.Xamarin.sln'
[string]$projNetStandard11 = "../src/netstandard/1.1/MsgPack"
[string]$projNetStandard13 = "../src/netstandard/1.3/MsgPack"

$buildOptions = @( '/v:minimal' )
if( $Rebuild )
{
    $buildOptions += '/t:Rebuild'
}

$buildOptions += "/p:Configuration=${buildConfig}"

# Unity
if ( !( Test-Path "./MsgPack-CLI" ) )
{
	New-Item ./MsgPack-CLI -Type Directory | Out-Null
}
else
{
	Remove-Item ./MsgPack-CLI/* -Recurse -Force
}

if ( !( Test-Path "../dist" ) )
{
	New-Item ../dist -Type Directory | Out-Null
}
else
{
	Remove-Item ../dist/* -Recurse -Force
}

if ( ( Test-Path "../bin/Xamarin.iOS10" ) )
{
	Remove-Item ../bin/Xamarin.iOS10 -Recurse
}

if ( !( Test-Path "./MsgPack-CLI/mpu" ) )
{
	New-Item ./MsgPack-CLI/mpu -Type Directory | Out-Null
}

# build
& $nuget restore $sln
if ( $LastExitCode -ne 0 )
{
	Write-Error "Failed to restore $sln"
	exit $LastExitCode
}

& $builder $sln $buildOptions
if ( $LastExitCode -ne 0 )
{
	Write-Error "Failed to build $sln"
	exit $LastExitCode
}

& $nuget restore $slnCompat
if ( $LastExitCode -ne 0 )
{
	Write-Error "Failed to restore $slnCompat"
	exit $LastExitCode
}

& $builder $slnCompat $buildOptions
if ( $LastExitCode -ne 0 )
{
	Write-Error "Failed to build $slnCompat"
	exit $LastExitCode
}

& $nuget restore $slnWindows
if ( $LastExitCode -ne 0 )
{
	Write-Error "Failed to restore $slnWindows"
	exit $LastExitCode
}

& $winBuilder $slnWindows $buildOptions
if ( $LastExitCode -ne 0 )
{
	Write-Error "Failed to build $slnWindows"
	exit $LastExitCode
}

& $nuget restore $slnXamarin
if ( $LastExitCode -ne 0 )
{
	Write-Error "Failed to restore $slnXamarin"
	exit $LastExitCode
}

& $builder $slnXamarin $buildOptions
if ( $LastExitCode -ne 0 )
{
	Write-Error "Failed to build $slnXamarin"
	exit $LastExitCode
}
Copy-Item ../bin/MonoTouch10 ../bin/Xamarin.iOS10 -Recurse

dotnet restore $projNetStandard11
if ( $LastExitCode -ne 0 )
{
	Write-Error "Failed to restore $projNetStandard11"
	exit $LastExitCode
}

dotnet build $projNetStandard11 -o ../bin/netstandard1.1 -f netstandard11 -c $buildConfig
if ( $LastExitCode -ne 0 )
{
	Write-Error "Failed to build $projNetStandard11"
	exit $LastExitCode
}

dotnet restore $projNetStandard13
if ( $LastExitCode -ne 0 )
{
	Write-Error "Failed to restore $projNetStandard13"
	exit $LastExitCode
}

dotnet build $projNetStandard13 -o ../bin/netstandard1.3 -f netstandard13 -c $buildConfig
if ( $LastExitCode -ne 0 )
{
	Write-Error "Failed to build $projNetStandard13"
	exit $LastExitCode
}

if ( $buildConfig -eq 'Release' )
{
	[string]$zipVersion = $env:PackageVersion
	& $nuget pack ../MsgPack.nuspec -Symbols -Version $env:PackageVersion -OutputDirectory ../dist

	Copy-Item ../bin/ ./MsgPack-CLI/ -Recurse -Exclude @("*.vshost.*")
	Copy-Item ../tools/mpu/bin/ ./MsgPack-CLI/mpu/ -Recurse -Exclude @("*.vshost.*")
	[Reflection.Assembly]::LoadWithPartialName( "System.IO.Compression.FileSystem" ) | Out-Null
	# 'latest' should be rewritten with semver manually.
	if ( ( Test-Path "../dist/MsgPack.Cli.${zipVersion}.zip" ) )
	{
		Remove-Item ../dist/MsgPack.Cli.${zipVersion}.zip
	}
	[IO.Compression.ZipFile]::CreateFromDirectory( ( Convert-Path './MsgPack-CLI' ), ( Convert-Path '../dist/' ) + "MsgPack.Cli.${zipVersion}.zip" )
	Remove-Item ./MsgPack-CLI -Recurse -Force

	if ( $env:APPVEYOR -ne "True" )
	{
		Write-Host "Package creation finished. Ensure AssemblyInfo.cs is updated and ./SetFileVersions.ps1 was executed."
	}
}