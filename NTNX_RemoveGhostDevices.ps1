<#
.notes
#Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
##############################################################################
#	 	 Remove Ghost Device Script
#	 	 Filename			:	  NTNX_RemoveGhostDevices.ps1
#	 	 Script Version		:	  1.2.14
##############################################################################
.prerequisites
	1. Powershell 5 or above ($psversiontable.psversion.major)
.synopsis
    Find ghost devices and uninstall them.
.usage
	PS C:\> NTNX_RemoveGhostDevices.ps1 -runaction List [ Dry Run: Get list, but do not remove anything ]
	PS C:\> NTNX_RemoveGhostDevices.ps1 -runaction Commit -confirm $true [ Commit to removing devices ]
.disclaimer
	This code is intended as a standalone example. Subject to licensing restrictions defined on nutanix.dev, this can be downloaded, copied and/or modified in any way you see fit.
	Please be aware that all public code samples provided by Nutanix are unofficial in nature, are provided as examples only, are unsupported and will need to be heavily scrutinized and potentially modified before they can be used in a production environment. All such code samples are provided on an as-is basis, and Nutanix expressly disclaims all warranties, express or implied.
	All code samples are © Nutanix, Inc., and are provided as-is under the MIT license. (https://opensource.org/licenses/MIT)
#>
##############################################################################
#////////////////////////////////////////////////////////////////////////////////////////////////
# DO NOT CHANGE THIS!
#////////////////////////////////////////////////////////////////////////////////////////////////
##############################################################################
[CmdletBinding()]
Param (
	[Parameter(Mandatory=$true,HelpMessage="Enter desired script action [Commit/List]")]
	[ValidateSet('Commit','List')]
	[string]$RunAction = 'List',
	[bool]$Confirm = $false
)
##############################################################################
# Set Variables Below
##############################################################################
[string]$my_log_dir = 'c:\temp'
##############################################################################
#////////////////////////////////////////////////////////////////////////////////////////////////
# CHANGE NOTHING BELOW HERE!
#////////////////////////////////////////////////////////////////////////////////////////////////
##############################################################################
$my_list_ghost_devices_only = $false
$my_remove_ghost_devices = $false
switch ($RunAction) {
	"List" { $my_list_ghost_devices_only = $true }
	"Commit"  { $my_remove_ghost_devices = $true }
}
if ($confirm) { $my_confirmed = $true }
$my_scriptpath = $myinvocation.mycommand.path # grab the full path to the scripts execution directory/location.
[string]$my_rundate = (get-date -format "%M-%d-yyyy")
[string]$my_workingdir = split-path $my_scriptpath # split the execution full path from the filename to create a working directory variable.
[string]$my_scriptname = split-path $my_scriptpath -leaf -resolve # grab the script name.
$my_logfile = "$($my_log_dir)\$($my_scriptname.replace('.ps1',''))_$($my_rundate).log"
new-item -itemtype directory -force -path $my_log_dir | out-null
if (test-path $my_logfile) { remove-item $my_logfile -ea silentlycontinue }
try { stop-transcript | out-null } catch [system.invalidoperationexception] {}
start-transcript -path $my_logfile | out-null

function filter-device {
    param ( [system.object]$my_dev )
    $my_class = $my_dev.class
    $my_friendlyname = $my_dev.friendlyname
    $my_matchfilter = $false

    if (($my_matchfilter -eq $false) -and ($my_narrowbyfriendlyname -ne $null)) {
        $my_shouldinclude = $false
        foreach ($my_friendlynamefilter in $my_narrowbyfriendlyname) {
            if ($my_friendlyname -like "*$($my_friendlynamefilter)*") {
                $my_shouldinclude = $true
                break
            }
        }
        $my_matchfilter = !$my_shouldinclude
    }
    return $my_matchfilter
}

function write-coloroutput($foregroundcolor) {
    $my_fc = $host.ui.rawui.foregroundcolor
    $host.ui.rawui.foregroundcolor = $foregroundcolor
    if ($args) { write-output $($args) }
    else { $input | write-output }
    $host.ui.rawui.foregroundcolor = $my_fc
}

function filter-devices {
    param ( [array]$my_devices )
    $my_filtereddevices = @()
    foreach ($my_dev in $my_devices) {
        $my_matchfilter = filter-device -my_dev $my_dev
        if ($my_matchfilter -eq $false) {
            $my_filtereddevices += @($my_dev)
        }
    }
    return $my_filtereddevices
}

function get-ghost-devices {
    param ( [array]$my_devices )
    return ($my_devices | where { $_.installstate -eq $false } | sort -property friendlyname)
}

$my_setup_api = @"
using System;
using System.Diagnostics;
using System.Text;
using System.Runtime.InteropServices;
namespace Win32
{
    public static class SetupApi
    {
         // 1st form using a ClassGUID only, with Enumerator = IntPtr.Zero
        [DllImport("setupapi.dll", CharSet = CharSet.Auto)]
        public static extern IntPtr SetupDiGetClassDevs(
           ref Guid ClassGuid,
           IntPtr Enumerator,
           IntPtr hwndParent,
           int Flags
        );

        // 2nd form uses an Enumerator only, with ClassGUID = IntPtr.Zero
        [DllImport("setupapi.dll", CharSet = CharSet.Auto)]
        public static extern IntPtr SetupDiGetClassDevs(
           IntPtr ClassGuid,
           string Enumerator,
           IntPtr hwndParent,
           int Flags
        );

        [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern bool SetupDiEnumDeviceInfo(
            IntPtr DeviceInfoSet,
            uint MemberIndex,
            ref SP_DEVINFO_DATA DeviceInfoData
        );

        [DllImport("setupapi.dll", SetLastError = true)]
        public static extern bool SetupDiDestroyDeviceInfoList(
            IntPtr DeviceInfoSet
        );
        [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern bool SetupDiGetDeviceRegistryProperty(
            IntPtr deviceInfoSet,
            ref SP_DEVINFO_DATA deviceInfoData,
            uint property,
            out UInt32 propertyRegDataType,
            byte[] propertyBuffer,
            uint propertyBufferSize,
            out UInt32 requiredSize
        );
        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern bool SetupDiGetDeviceInstanceId(
            IntPtr DeviceInfoSet,
            ref SP_DEVINFO_DATA DeviceInfoData,
            StringBuilder DeviceInstanceId,
            int DeviceInstanceIdSize,
            out int RequiredSize
        );


        [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern bool SetupDiRemoveDevice(IntPtr DeviceInfoSet,ref SP_DEVINFO_DATA DeviceInfoData);
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVINFO_DATA
    {
       public uint cbSize;
       public Guid classGuid;
       public uint devInst;
       public IntPtr reserved;
    }
    [Flags]
    public enum DiGetClassFlags : uint
    {
        DIGCF_DEFAULT       = 0x00000001,  // only valid with DIGCF_DEVICEINTERFACE
        DIGCF_PRESENT       = 0x00000002,
        DIGCF_ALLCLASSES    = 0x00000004,
        DIGCF_PROFILE       = 0x00000008,
        DIGCF_DEVICEINTERFACE   = 0x00000010,
    }
    public enum SetupDiGetDeviceRegistryPropertyEnum : uint
    {
         SPDRP_DEVICEDESC          = 0x00000000, // DeviceDesc (R/W)
         SPDRP_HARDWAREID          = 0x00000001, // HardwareID (R/W)
         SPDRP_COMPATIBLEIDS           = 0x00000002, // CompatibleIDs (R/W)
         SPDRP_UNUSED0             = 0x00000003, // unused
         SPDRP_SERVICE             = 0x00000004, // Service (R/W)
         SPDRP_UNUSED1             = 0x00000005, // unused
         SPDRP_UNUSED2             = 0x00000006, // unused
         SPDRP_CLASS               = 0x00000007, // Class (R--tied to ClassGUID)
         SPDRP_CLASSGUID           = 0x00000008, // ClassGUID (R/W)
         SPDRP_DRIVER              = 0x00000009, // Driver (R/W)
         SPDRP_CONFIGFLAGS         = 0x0000000A, // ConfigFlags (R/W)
         SPDRP_MFG             = 0x0000000B, // Mfg (R/W)
         SPDRP_FRIENDLYNAME        = 0x0000000C, // FriendlyName (R/W)
         SPDRP_LOCATION_INFORMATION    = 0x0000000D, // LocationInformation (R/W)
         SPDRP_PHYSICAL_DEVICE_OBJECT_NAME = 0x0000000E, // PhysicalDeviceObjectName (R)
         SPDRP_CAPABILITIES        = 0x0000000F, // Capabilities (R)
         SPDRP_UI_NUMBER           = 0x00000010, // UiNumber (R)
         SPDRP_UPPERFILTERS        = 0x00000011, // UpperFilters (R/W)
         SPDRP_LOWERFILTERS        = 0x00000012, // LowerFilters (R/W)
         SPDRP_BUSTYPEGUID         = 0x00000013, // BusTypeGUID (R)
         SPDRP_LEGACYBUSTYPE           = 0x00000014, // LegacyBusType (R)
         SPDRP_BUSNUMBER           = 0x00000015, // BusNumber (R)
         SPDRP_ENUMERATOR_NAME         = 0x00000016, // Enumerator Name (R)
         SPDRP_SECURITY            = 0x00000017, // Security (R/W, binary form)
         SPDRP_SECURITY_SDS        = 0x00000018, // Security (W, SDS form)
         SPDRP_DEVTYPE             = 0x00000019, // Device Type (R/W)
         SPDRP_EXCLUSIVE           = 0x0000001A, // Device is exclusive-access (R/W)
         SPDRP_CHARACTERISTICS         = 0x0000001B, // Device Characteristics (R/W)
         SPDRP_ADDRESS             = 0x0000001C, // Device Address (R)
         SPDRP_UI_NUMBER_DESC_FORMAT       = 0X0000001D, // UiNumberDescFormat (R/W)
         SPDRP_DEVICE_POWER_DATA       = 0x0000001E, // Device Power Data (R)
         SPDRP_REMOVAL_POLICY          = 0x0000001F, // Removal Policy (R)
         SPDRP_REMOVAL_POLICY_HW_DEFAULT   = 0x00000020, // Hardware Removal Policy (R)
         SPDRP_REMOVAL_POLICY_OVERRIDE     = 0x00000021, // Removal Policy Override (RW)
         SPDRP_INSTALL_STATE           = 0x00000022, // Device Install State (R)
         SPDRP_LOCATION_PATHS          = 0x00000023, // Device Location Paths (R)
         SPDRP_BASE_CONTAINERID        = 0x00000024  // Base ContainerID (R)
    }
}
"@
Add-Type -TypeDefinition $my_setup_api

#Array for all removed devices report
$my_removeArray = @()
#Array for all devices report
$my_devicearray = @()

$setupClass = [Guid]::Empty
$my_devs = [Win32.SetupApi]::SetupDiGetClassDevs([ref]$setupClass, [IntPtr]::Zero, [IntPtr]::Zero, [Win32.DiGetClassFlags]::DIGCF_ALLCLASSES)

$my_dev_info = new-object Win32.SP_DEVINFO_DATA
$my_dev_info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($my_dev_info)

$my_devCount = 0
if ($my_remove_ghost_devices -eq $true) {
	write-coloroutput white "Removing Ghosted Devices"
	write-coloroutput white "**********************"
}

while ([Win32.SetupApi]::SetupDiEnumDeviceInfo($my_devs, $my_devCount, [ref]$my_dev_info)) {
	$propType = 0
	[byte[]]$propBuffer = $null
	$propBufferSize = 0
	[Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($my_devs, [ref]$my_dev_info, [Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_FRIENDLYNAME, [ref]$propType, $propBuffer, 0, [ref]$propBufferSize) | Out-null
	[byte[]]$propBuffer = new-object byte[] $propBufferSize

	#Get HardwareID
	$propTypeHWID = 0
	[byte[]]$propBufferHWID = $null
	$propBufferSizeHWID = 0
	[Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($my_devs, [ref]$my_dev_info, [Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_HARDWAREID, [ref]$propTypeHWID, $propBufferHWID, 0, [ref]$propBufferSizeHWID) | Out-null
	[byte[]]$propBufferHWID = new-object byte[] $propBufferSizeHWID

	#Get DeviceDesc (this name will be used if no friendly name is found)
	$propTypeDD = 0
	[byte[]]$propBufferDD = $null
	$propBufferSizeDD = 0
	[Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($my_devs, [ref]$my_dev_info, [Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_DEVICEDESC, [ref]$propTypeDD, $propBufferDD, 0, [ref]$propBufferSizeDD) | Out-null
	[byte[]]$propBufferDD = new-object byte[] $propBufferSizeDD

	#Get Install State
	$propTypeIS = 0
	[byte[]]$propBufferIS = $null
	$propBufferSizeIS = 0
	[Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($my_devs, [ref]$my_dev_info, [Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_INSTALL_STATE, [ref]$propTypeIS, $propBufferIS, 0, [ref]$propBufferSizeIS) | Out-null
	[byte[]]$propBufferIS = new-object byte[] $propBufferSizeIS

	if(![Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($my_devs, [ref]$my_dev_info,[Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_FRIENDLYNAME, [ref]$propType, $propBuffer, $propBufferSize, [ref]$propBufferSize)){
		[Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($my_devs, [ref]$my_dev_info,[Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_DEVICEDESC, [ref]$propTypeDD, $propBufferDD, $propBufferSizeDD, [ref]$propBufferSizeDD)  | out-null
		$my_friendlyname = [System.Text.Encoding]::Unicode.GetString($propBufferDD)
		if ($my_friendlyname.Length -ge 1) {
			$my_friendlyname = $my_friendlyname.Substring(0,$my_friendlyname.Length-1)
		}
	} else {
		$my_friendlyname = [System.Text.Encoding]::Unicode.GetString($propBuffer)
		if ($my_friendlyname.Length -ge 1) {
			$my_friendlyname = $my_friendlyname.Substring(0,$my_friendlyname.Length-1)
		}
	}

	$my_installstate = [Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($my_devs, [ref]$my_dev_info,[Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_INSTALL_STATE, [ref]$propTypeIS, $propBufferIS, $propBufferSizeIS, [ref]$propBufferSizeIS)

	if(![Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($my_devs, [ref]$my_dev_info,[Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_HARDWAREID, [ref]$propTypeHWID, $propBufferHWID, $propBufferSizeHWID, [ref]$propBufferSizeHWID)){
		$my_hwid = ""
	} else {
		$my_hwid = [System.Text.Encoding]::Unicode.GetString($propBufferHWID)
		$my_hwid = $my_hwid.split([char]0x0000)[0].ToUpper()
	}

	$my_devObj = new-object system.object
	$my_devObj | add-member -type NoteProperty -name FriendlyName -value $my_friendlyname
	$my_devObj | add-member -type NoteProperty -name HWID -value $my_hwid
	$my_devObj | add-member -type NoteProperty -name InstallState -value $my_installstate
	if ($my_devicearray.count -le 0) { sleep 1 }
	$my_devicearray += @($my_devObj)

	if ($my_remove_ghost_devices -eq $true) {
		$my_matchFilter = filter-device -my_dev $my_devObj
		if ($my_installstate -eq $false) {
				write-coloroutput yellow "[$(get-date -format 'yyyy-MM-dd HH:mm:ss')] - Attempting to remove device:[$($my_friendlyname)]"
				if ($my_confirmed -eq $true) {
					$my_removeObj = new-object system.object
					$my_removeObj | add-member -type NoteProperty -name FriendlyName -value $my_friendlyname
					$my_removeObj | add-member -type NoteProperty -name HWID -value $my_hwid
					$my_removeObj | add-member -type NoteProperty -name InstallState -value $my_installstate
					if ([Win32.SetupApi]::SetupDiRemoveDevice($my_devs, [ref]$my_dev_info)) {
						$my_removeArray += @($my_removeObj)
						write-coloroutput green "  Removed device:[$($my_friendlyname)]"
					} else {
						write-coloroutput red "  Failed to remove device:[$($my_friendlyname)]"
					}
				} else {
					write-coloroutput red "  Skipping removal of device:[$($my_friendlyname)], please use ""confirm"" option."
				}
		}
	}
	$my_devCount++
}
if (($my_list_ghost_devices_only) -and (!($my_remove_ghost_devices))) {
	write-coloroutput white "Ghosted Devices"
	write-coloroutput white "**********************"
	$my_ghost_devices = get-ghost-devices -my_devices $my_devicearray
	$my_filteredghostdevices = filter-devices -my_devices $my_ghost_devices
	$my_filteredghostdevices  | sort -property friendlyname | format-table  -autosize
	write-coloroutput white "Total ghosted devices found: $($my_ghost_devices.count)"
}

if ($my_remove_ghost_devices -eq $true) {
	write-coloroutput white "`n"
	write-coloroutput white "**********************"
	write-coloroutput white "Removed Ghosted Devices:"
	write-coloroutput white "**********************"
	$my_removearray  | sort -property friendlyname | format-table  -autosize
	write-coloroutput white "Total removed ghosted devices: $($my_removeArray.count)"
}
write-coloroutput white "`nFinished!"
write-coloroutput cyan "Log file located at: $($my_logfile)`n"
try { stop-transcript | out-null } catch [system.invalidoperationexception] {}