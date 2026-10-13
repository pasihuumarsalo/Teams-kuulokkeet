<#
.SYNOPSIS
    Kysyy Teams-puhelun tai -kokouksen alkaessa, yhdistetäänkö Bluetooth-kuulokkeet (oletus: AirPods)
    tähän koneeseen. Sisältää myös pikanäppäimellä käynnistettävän "yhdistä nyt" -toiminnon.

.DESCRIPTION
    Toimintaperiaate
    - Valvonta (oletustila) pyörii ilmaisinalueella (tray). Se lukee Windowsin äänisessioista 4 kertaa
      sekunnissa, soittaako Teams (uusi ms-teams.exe tai klassinen Teams.exe) ääntä. Kun Teamsista kuuluu
      yhtäjaksoisesti ääntä (soittoääni tai kokouksen ääni) eivätkä kuulokkeet ole yhdistettyinä tähän
      koneeseen, ruudun oikeaan yläkulmaan avautuu kysely: Yhdistä / Ei / Ei tuntiin.
    - Lyhyet viesti-ilmoitusten piippaukset eivät laukaise kyselyä.
    - Yhdistäminen tehdään samalla Windowsin rajapinnalla, jota Bluetooth-asetusten "Yhdistä"-painike
      käyttää (IKsControl + KSPROPSETID_BtAudio / KSPROPERTY_ONESHOT_RECONNECT). Kuulokkeiden pitää olla
      paritettuina koneeseen ennestään.
    - Ei tarvitse järjestelmänvalvojan oikeuksia eikä asenna mitään kolmannen osapuolen ohjelmia.

    Käyttö (asennuspaketin Asenna.cmd / Poista.cmd kutsuvat näitä)
      .\TeamsKuulokkeet.ps1 -Install       Kysyy kuulokkeet listasta, asentaa kansioon %LOCALAPPDATA%\TeamsKuulokkeet,
                                           luo Käynnistä-valikon kansion, automaattisen käynnistyksen ja pikanäppäimen
                                           (oletus Ctrl+Alt+H), lisää merkinnän Asennetut sovellukset -listaan ja
                                           käynnistää valvonnan. Uudelleenajo = päivitys / kuulokkeiden vaihto.
      .\TeamsKuulokkeet.ps1                Käynnistää valvonnan (tray-ikoni).
      .\TeamsKuulokkeet.ps1 -ConnectNow    Yhdistää kuulokkeet heti ja lopettaa.
      .\TeamsKuulokkeet.ps1 -Diagnose      Näyttää konsolissa kuulokkeiden tilan ja Teamsin äänisessiot.
      .\TeamsKuulokkeet.ps1 -Uninstall     Pysäyttää valvonnan ja poistaa kaiken asennetun.

    Asetukset: %LOCALAPPDATA%\TeamsKuulokkeet\asetukset.json
    Loki:      %LOCALAPPDATA%\TeamsKuulokkeet\loki.txt

.NOTES
    Versio 1.2.0. Vaatii Windows 10/11:n ja Windows PowerShell 5.1:n (powershell.exe) FullLanguage-tilassa.
#>
[CmdletBinding()]
param(
    [switch]$ConnectNow,
    [switch]$Diagnose,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$FromSettings,   # poisto käynnistetty Windowsin Asennetut sovellukset -listasta
    [switch]$Welcome,        # valvonta käynnistetty asennuksen päätteeksi

    # Kuulokkeiden nimi (tai osa siitä) sellaisena kuin se näkyy Windowsissa. Oletus luetaan asetustiedostosta.
    [string]$HeadsetName = 'AirPods',

    # Teamsin prosessinimet: uusi Teams = ms-teams, klassinen Teams = Teams.
    [string[]]$TeamsProcessNames = @('ms-teams', 'Teams'),

    # Äänen huipputaso (0..1), jota suurempi lasketaan "ääneksi".
    [double]$PeakThreshold = 0.01,

    # Kuinka monta sekuntia ääntä 3 sekunnin ikkunassa tarvitaan kyselyn avaamiseen.
    [double]$SoundSeconds = 1.5,

    # Kyselyn jälkeen uutta kyselyä ei tehdä ennen kuin Teams on ollut hiljaa näin monta sekuntia.
    [int]$QuietResetSeconds = 60,

    # Kysely sulkeutuu itsestään tämän ajan jälkeen.
    [int]$PromptTimeoutSeconds = 25,

    # "Yhdistä nyt" -pikakuvakkeen pikanäppäin (asennuksessa).
    [string]$Hotkey = 'CTRL+ALT+H'
)

$script:AppName       = 'Teams-kuulokkeet'
$script:Version       = '1.2.0'
$script:InstallDir    = Join-Path $env:LOCALAPPDATA 'TeamsKuulokkeet'
$script:InstalledPath = Join-Path $script:InstallDir 'TeamsKuulokkeet.ps1'
$script:ConfigFile    = Join-Path $script:InstallDir 'asetukset.json'
$script:LogDir        = $script:InstallDir
$script:LogFile       = Join-Path $script:LogDir 'loki.txt'
$script:UninstallKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\TeamsKuulokkeet'
$script:MutexName     = 'Local\TeamsKuulokkeetValvonta'
$script:StopEventName = 'Local\TeamsKuulokkeetLopeta'
$script:PsExe         = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Asetustiedosto ohittaa oletukset, jos arvoa ei annettu komentorivillä.
$script:Config = $null
try {
    if (Test-Path $script:ConfigFile) {
        $script:Config = Get-Content -Path $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
} catch { }
if ($script:Config) {
    if (-not $PSBoundParameters.ContainsKey('HeadsetName') -and $script:Config.HeadsetName) { $HeadsetName = [string]$script:Config.HeadsetName }
    if (-not $PSBoundParameters.ContainsKey('Hotkey') -and $script:Config.Hotkey) { $Hotkey = [string]$script:Config.Hotkey }
}

# ---------------------------------------------------------------------------------------------
# C#-apuluokka: Core Audio -rajapinnat (äänisessiot, laitteet) ja Bluetooth-yhdistäminen.
# Kirjoitettu C# 5 -yhteensopivaksi, jotta Windows PowerShell 5.1:n kääntäjä hyväksyy sen.
# ---------------------------------------------------------------------------------------------
$script:CSharp = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace TeamsKuulokkeetAudio
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPVARIANT { public ushort vt; public ushort r1; public ushort r2; public ushort r3; public IntPtr p1; public IntPtr p2; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KSPROPERTY { public Guid Set; public uint Id; public uint Flags; }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PROCESS_BASIC_INFORMATION
    {
        public IntPtr ExitStatus; public IntPtr PebBaseAddress; public IntPtr AffinityMask;
        public IntPtr BasePriority; public IntPtr UniqueProcessId; public IntPtr InheritedFromUniqueProcessId;
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        void EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        void GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        void GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        void RegisterEndpointNotificationCallback(IntPtr client);
        void UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceCollection
    {
        void GetCount(out int count);
        void Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        void Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        void OpenPropertyStore(int access, out IPropertyStore store);
        void GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        void GetState(out int state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        void GetCount(out int count);
        void GetAt(int index, out PROPERTYKEY key);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        void SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        void Commit();
    }

    [ComImport, Guid("2A07407E-6497-4A18-9787-32F79BD0D98F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IDeviceTopology
    {
        void GetConnectorCount(out int count);
        void GetConnector(int index, out IConnector connector);
        void GetSubunitCount(out int count);
        void GetSubunit(int index, out IntPtr subunit);
        void GetPartById(int id, out IntPtr part);
        void GetDeviceId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        void GetSignalPath(IntPtr partFrom, IntPtr partTo, int rejectMixedPaths, out IntPtr parts);
    }

    [ComImport, Guid("9C2C4058-23F5-41DE-877A-DF3AF236A09E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IConnector
    {
        void GetConnectorType(out int type);
        void GetDataFlow(out int flow);
        void ConnectTo(IntPtr connectTo);
        void Disconnect();
        void IsConnected(out int connected);
        void GetConnectedTo(out IConnector connectedTo);
        void GetConnectorIdConnectedTo([MarshalAs(UnmanagedType.LPWStr)] out string id);
        void GetDeviceIdConnectedTo([MarshalAs(UnmanagedType.LPWStr)] out string id);
    }

    [ComImport, Guid("AE2DE0E4-5BCA-4F2D-AA46-5D13F8FDB3A9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPart
    {
        void GetName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        void GetLocalId(out int id);
        void GetGlobalId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        void GetPartType(out int type);
        void GetSubType(out Guid subType);
        void GetControlInterfaceCount(out int count);
        void GetControlInterface(int index, out IntPtr control);
        void EnumPartsIncoming(out IntPtr parts);
        void EnumPartsOutgoing(out IntPtr parts);
        void GetTopologyObject(out IDeviceTopology topology);
    }

    [ComImport, Guid("28F54685-06FD-11D2-B27A-00A0C9223196"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IKsControl
    {
        [PreserveSig]
        int KsProperty(ref KSPROPERTY property, int propertyLength, IntPtr data, int dataLength, out int bytesReturned);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionManager2
    {
        void GetAudioSessionControl(IntPtr sessionGuid, int streamFlags, out IntPtr control);
        void GetSimpleAudioVolume(IntPtr sessionGuid, int streamFlags, out IntPtr volume);
        void GetSessionEnumerator(out IAudioSessionEnumerator sessionEnum);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionEnumerator
    {
        void GetCount(out int count);
        void GetSession(int index, [MarshalAs(UnmanagedType.IUnknown)] out object session);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl2
    {
        // IAudioSessionControl
        void GetState(out int state);
        void GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        void SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr eventContext);
        void GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        void SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr eventContext);
        void GetGroupingParam(out Guid groupingParam);
        void SetGroupingParam(ref Guid groupingParam, IntPtr eventContext);
        void RegisterAudioSessionNotification(IntPtr client);
        void UnregisterAudioSessionNotification(IntPtr client);
        // IAudioSessionControl2
        void GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        void GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        void GetProcessId(out uint pid);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioMeterInformation
    {
        void GetPeakValue(out float peak);
    }

    public class HeadsetStatus
    {
        public bool Found;
        public bool Connected;
        public int FilterCount;
        public string EndpointNames;
    }

    public static class Audio
    {
        const int CLSCTX_ALL = 23;
        const int eRender = 0;
        const int eAll = 2;
        const int DEVICE_STATE_ACTIVE = 1;
        const int DEVICE_STATE_UNPLUGGED = 8;
        const int AudioSessionStateActive = 1;
        const uint KSPROPERTY_ONESHOT_RECONNECT = 0;
        const uint KSPROPERTY_ONESHOT_DISCONNECT = 1;
        const uint KSPROPERTY_TYPE_GET = 1;
        const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        static readonly Guid CLSID_MMDeviceEnumerator = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        static readonly Guid IID_IDeviceTopology = new Guid("2A07407E-6497-4A18-9787-32F79BD0D98F");
        static readonly Guid IID_IKsControl = new Guid("28F54685-06FD-11D2-B27A-00A0C9223196");
        static readonly Guid IID_IAudioSessionManager2 = new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");
        static readonly Guid KSPROPSETID_BtAudio = new Guid("7FA06C40-B8F6-4C7E-8556-E8C33A12E54D");
        static readonly Guid PKEY_Device_FriendlyName_fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0");

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PROPVARIANT pvar);

        [DllImport("kernel32.dll")]
        static extern IntPtr OpenProcess(int access, bool inheritHandle, uint processId);

        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);

        [DllImport("ntdll.dll")]
        static extern int NtQueryInformationProcess(IntPtr process, int infoClass, ref PROCESS_BASIC_INFORMATION info, int length, out int returnLength);

        static IMMDeviceEnumerator enumerator;
        static readonly Dictionary<uint, bool> teamsCache = new Dictionary<uint, bool>();

        static IMMDeviceEnumerator Enumerator
        {
            get
            {
                if (enumerator == null)
                    enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_MMDeviceEnumerator));
                return enumerator;
            }
        }

        static object ActivateOn(IMMDevice device, Guid iid)
        {
            object o;
            device.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o);
            return o;
        }

        static string FriendlyName(IMMDevice device)
        {
            IPropertyStore store = null;
            try
            {
                device.OpenPropertyStore(0, out store);
                PROPERTYKEY key = new PROPERTYKEY();
                key.fmtid = PKEY_Device_FriendlyName_fmtid;
                key.pid = 14;
                PROPVARIANT pv;
                store.GetValue(ref key, out pv);
                string name = (pv.vt == 31) ? Marshal.PtrToStringUni(pv.p1) : "";
                PropVariantClear(ref pv);
                return name ?? "";
            }
            catch { return ""; }
            finally { if (store != null) Marshal.ReleaseComObject(store); }
        }

        // Laitteen KS-suodattimen tunniste: päätepisteen liitin -> vastaliitin -> suodattimen topologia.
        static string FilterId(IMMDevice device)
        {
            try
            {
                IDeviceTopology topology = (IDeviceTopology)ActivateOn(device, IID_IDeviceTopology);
                IConnector connector;
                topology.GetConnector(0, out connector);
                IConnector peer;
                connector.GetConnectedTo(out peer);
                IPart part = (IPart)peer;
                IDeviceTopology filterTopology;
                part.GetTopologyObject(out filterTopology);
                string id;
                filterTopology.GetDeviceId(out id);
                return id;
            }
            catch { return null; }
        }

        static bool IsBluetoothFilter(string id)
        {
            if (string.IsNullOrEmpty(id)) return false;
            string l = id.ToLowerInvariant();
            return l.Contains("bthenum") || l.Contains("bthhfenum") || l.Contains("bthleenum");
        }

        class Endpoint
        {
            public string Name;
            public int State;
            public string Filter;
        }

        // "Kuulokkeet (AirPods Pro)" / "Headset (AirPods Pro Hands-Free)" -> "AirPods Pro"
        public static string CleanDeviceName(string endpointName)
        {
            if (endpointName == null) return "";
            int l = endpointName.IndexOf('(');
            int r = endpointName.LastIndexOf(')');
            string inner = (l >= 0 && r > l) ? endpointName.Substring(l + 1, r - l - 1) : endpointName;
            string[] suffixes = new string[] { " Hands-Free AG Audio", " Hands-Free AG", " Hands-Free", " Stereo" };
            foreach (string s in suffixes)
            {
                if (inner.EndsWith(s, StringComparison.OrdinalIgnoreCase))
                {
                    inner = inner.Substring(0, inner.Length - s.Length);
                    break;
                }
            }
            return inner.Trim();
        }

        // Koneeseen paritettujen Bluetooth-äänilaitteiden nimet (yksi nimi per laite).
        public static string[] ListDeviceNames()
        {
            List<string> names = new List<string>();
            foreach (Endpoint e in AllBluetoothEndpoints())
            {
                string n = CleanDeviceName(e.Name);
                if (n.Length == 0) continue;
                bool exists = false;
                foreach (string x in names)
                    if (string.Equals(x, n, StringComparison.OrdinalIgnoreCase)) { exists = true; break; }
                if (!exists) names.Add(n);
            }
            return names.ToArray();
        }

        // Ensisijaisesti täsmälleen samanniminen laite, muuten kaikki joiden nimessä annettu teksti esiintyy.
        static List<Endpoint> FindBluetoothEndpoints(string namePart)
        {
            List<Endpoint> all = AllBluetoothEndpoints();
            if (string.IsNullOrEmpty(namePart)) return all;
            List<Endpoint> exact = new List<Endpoint>();
            List<Endpoint> partial = new List<Endpoint>();
            foreach (Endpoint e in all)
            {
                if (string.Equals(CleanDeviceName(e.Name), namePart.Trim(), StringComparison.OrdinalIgnoreCase)) exact.Add(e);
                else if (e.Name.IndexOf(namePart.Trim(), StringComparison.OrdinalIgnoreCase) >= 0) partial.Add(e);
            }
            return exact.Count > 0 ? exact : partial;
        }

        static List<Endpoint> AllBluetoothEndpoints()
        {
            List<Endpoint> result = new List<Endpoint>();
            IMMDeviceCollection collection;
            Enumerator.EnumAudioEndpoints(eAll, DEVICE_STATE_ACTIVE | DEVICE_STATE_UNPLUGGED, out collection);
            int count;
            collection.GetCount(out count);
            for (int i = 0; i < count; i++)
            {
                IMMDevice device;
                collection.Item(i, out device);
                string name = FriendlyName(device);
                string filter = FilterId(device);
                if (!IsBluetoothFilter(filter))
                    continue;
                int state;
                device.GetState(out state);
                Endpoint e = new Endpoint();
                e.Name = name;
                e.State = state;
                e.Filter = filter;
                result.Add(e);
            }
            return result;
        }

        public static HeadsetStatus GetStatus(string namePart)
        {
            HeadsetStatus status = new HeadsetStatus();
            HashSet<string> filters = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            List<string> names = new List<string>();
            foreach (Endpoint e in FindBluetoothEndpoints(namePart))
            {
                status.Found = true;
                if (e.State == DEVICE_STATE_ACTIVE) status.Connected = true;
                filters.Add(e.Filter);
                names.Add(e.Name);
            }
            status.FilterCount = filters.Count;
            status.EndpointNames = string.Join("; ", names.ToArray());
            return status;
        }

        // Palauttaa yhteenvedon lähetetyistä pyynnöistä lokia varten. Heittää virheen, jos yksikään ei onnistunut.
        public static string Connect(string namePart) { return SendBluetoothRequest(namePart, KSPROPERTY_ONESHOT_RECONNECT); }

        public static string Disconnect(string namePart) { return SendBluetoothRequest(namePart, KSPROPERTY_ONESHOT_DISCONNECT); }

        static int ProfileOrder(string filter, uint propertyId)
        {
            bool hfp = filter.IndexOf("bthhfenum", StringComparison.OrdinalIgnoreCase) >= 0;
            // Katkaistaessa ensin puheluprofiili (HFP), sitten musiikkiprofiili (A2DP); yhdistettäessä päinvastoin.
            if (propertyId == KSPROPERTY_ONESHOT_DISCONNECT) return hfp ? 0 : 1;
            return hfp ? 1 : 0;
        }

        static string ProfileName(string filter)
        {
            string l = filter.ToLowerInvariant();
            if (l.Contains("bthhfenum")) return "HFP";
            if (l.Contains("bthleenum")) return "LE";
            return "A2DP";
        }

        static string SendBluetoothRequest(string namePart, uint propertyId)
        {
            List<Endpoint> endpoints = FindBluetoothEndpoints(namePart);
            if (endpoints.Count == 0)
                throw new InvalidOperationException("Paritettua Bluetooth-äänilaitetta nimellä '" + namePart + "' ei löytynyt.");

            // Yksi pyyntö per KS-suodatin (saman profiilin toisto- ja nauhoituspäätepisteillä on yhteinen suodatin).
            List<string> filters = new List<string>();
            foreach (Endpoint e in endpoints)
            {
                bool exists = false;
                foreach (string f in filters)
                    if (string.Equals(f, e.Filter, StringComparison.OrdinalIgnoreCase)) { exists = true; break; }
                if (!exists) filters.Add(e.Filter);
            }
            uint pid = propertyId;
            filters.Sort(delegate(string a, string b) { return ProfileOrder(a, pid).CompareTo(ProfileOrder(b, pid)); });

            int succeeded = 0;
            int lastHr = 0;
            List<string> details = new List<string>();
            foreach (string filter in filters)
            {
                int hr;
                try
                {
                    IMMDevice filterDevice;
                    Enumerator.GetDevice(filter, out filterDevice);
                    IKsControl ks = (IKsControl)ActivateOn(filterDevice, IID_IKsControl);
                    KSPROPERTY p = new KSPROPERTY();
                    p.Set = KSPROPSETID_BtAudio;
                    p.Id = propertyId;
                    p.Flags = KSPROPERTY_TYPE_GET;
                    int returned;
                    hr = ks.KsProperty(ref p, Marshal.SizeOf(typeof(KSPROPERTY)), IntPtr.Zero, 0, out returned);
                }
                catch (Exception ex) { hr = Marshal.GetHRForException(ex); }
                if (hr >= 0) succeeded++; else lastHr = hr;
                details.Add(string.Format("{0}=0x{1:X8}", ProfileName(filter), hr));
            }
            string summary = string.Join(", ", details.ToArray());
            if (succeeded == 0)
                throw new InvalidOperationException(string.Format("Bluetooth-pyyntö epäonnistui (HRESULT 0x{0:X8}; {1}).", lastHr, summary));
            return summary;
        }

        // Teamsin äänisessioiden suurin huipputaso (0..1). -1 = Teamsilla ei aktiivista äänisessiota.
        public static float TeamsPeak(string[] processNames)
        {
            float max = -1f;
            IMMDeviceCollection collection;
            Enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, out collection);
            int count;
            collection.GetCount(out count);
            for (int i = 0; i < count; i++)
            {
                IMMDevice device;
                collection.Item(i, out device);
                IAudioSessionEnumerator sessions;
                try
                {
                    IAudioSessionManager2 manager = (IAudioSessionManager2)ActivateOn(device, IID_IAudioSessionManager2);
                    manager.GetSessionEnumerator(out sessions);
                }
                catch { continue; }

                int sessionCount;
                sessions.GetCount(out sessionCount);
                for (int j = 0; j < sessionCount; j++)
                {
                    object session = null;
                    try
                    {
                        sessions.GetSession(j, out session);
                        IAudioSessionControl2 control = (IAudioSessionControl2)session;
                        int state;
                        control.GetState(out state);
                        if (state != AudioSessionStateActive) continue;
                        uint pid;
                        control.GetProcessId(out pid);
                        if (!IsTeamsProcess(pid, processNames)) continue;
                        float peak = 0f;
                        IAudioMeterInformation meter = session as IAudioMeterInformation;
                        if (meter != null) meter.GetPeakValue(out peak);
                        if (peak > max) max = peak;
                    }
                    catch { }
                    finally { if (session != null) Marshal.ReleaseComObject(session); }
                }
            }
            return max;
        }

        // Teams-prosessi itse tai sen WebView2-aliprosessi (uusi Teams soittaa äänet WebView2:n kautta).
        public static bool IsTeamsProcess(uint pid, string[] processNames)
        {
            if (pid == 0) return false;
            bool cached;
            if (teamsCache.TryGetValue(pid, out cached)) return cached;

            bool result = false;
            uint current = pid;
            for (int depth = 0; depth < 4 && current != 0; depth++)
            {
                string name = ProcessName(current);
                if (name == null) break;
                if (MatchesAny(name, processNames)) { result = true; break; }
                if (!string.Equals(name, "msedgewebview2", StringComparison.OrdinalIgnoreCase)) break;
                uint parent = ParentProcessId(current);
                if (parent == current) break;
                current = parent;
            }
            if (teamsCache.Count > 500) teamsCache.Clear();
            teamsCache[pid] = result;
            return result;
        }

        static bool MatchesAny(string name, string[] names)
        {
            foreach (string n in names)
                if (string.Equals(name, n, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        static string ProcessName(uint pid)
        {
            try { using (Process p = Process.GetProcessById((int)pid)) { return p.ProcessName; } }
            catch { return null; }
        }

        static uint ParentProcessId(uint pid)
        {
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return 0;
            try
            {
                PROCESS_BASIC_INFORMATION info = new PROCESS_BASIC_INFORMATION();
                int len;
                int status = NtQueryInformationProcess(h, 0, ref info, Marshal.SizeOf(typeof(PROCESS_BASIC_INFORMATION)), out len);
                if (status != 0) return 0;
                return (uint)info.InheritedFromUniqueProcessId.ToInt64();
            }
            finally { CloseHandle(h); }
        }

        static string StateName(int state)
        {
            switch (state)
            {
                case 1: return "YHDISTETTY";
                case 2: return "pois käytöstä";
                case 4: return "ei läsnä";
                case 8: return "ei yhdistetty";
                default: return state.ToString();
            }
        }

        // Diagnostiikka: Bluetooth-äänipäätepisteet (namePart tyhjä = kaikki).
        public static string[] DebugEndpoints(string namePart)
        {
            List<string> lines = new List<string>();
            foreach (Endpoint e in FindBluetoothEndpoints(namePart))
                lines.Add(string.Format("{0,-50} {1,-14} {2}", e.Name, StateName(e.State), e.Filter));
            return lines.ToArray();
        }

        // Diagnostiikka: kaikkien aktiivisten toistolaitteiden äänisessiot.
        public static string[] DebugSessions(string[] processNames)
        {
            List<string> lines = new List<string>();
            IMMDeviceCollection collection;
            Enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, out collection);
            int count;
            collection.GetCount(out count);
            for (int i = 0; i < count; i++)
            {
                IMMDevice device;
                collection.Item(i, out device);
                string deviceName = FriendlyName(device);
                IAudioSessionEnumerator sessions;
                try
                {
                    IAudioSessionManager2 manager = (IAudioSessionManager2)ActivateOn(device, IID_IAudioSessionManager2);
                    manager.GetSessionEnumerator(out sessions);
                }
                catch { continue; }
                int sessionCount;
                sessions.GetCount(out sessionCount);
                for (int j = 0; j < sessionCount; j++)
                {
                    object session = null;
                    try
                    {
                        sessions.GetSession(j, out session);
                        IAudioSessionControl2 control = (IAudioSessionControl2)session;
                        int state;
                        control.GetState(out state);
                        uint pid;
                        control.GetProcessId(out pid);
                        float peak = 0f;
                        IAudioMeterInformation meter = session as IAudioMeterInformation;
                        if (meter != null) meter.GetPeakValue(out peak);
                        bool teams = IsTeamsProcess(pid, processNames);
                        if (state != AudioSessionStateActive && !teams) continue;
                        lines.Add(string.Format("{0,-28} pid {1,-6} {2,-16} teams={3,-5} tila={4} huippu={5:0.000}",
                            deviceName.Length > 28 ? deviceName.Substring(0, 28) : deviceName,
                            pid, ProcessName(pid) ?? "?", teams, state == AudioSessionStateActive ? "aktiivinen" : "passiivinen", peak));
                    }
                    catch { }
                    finally { if (session != null) Marshal.ReleaseComObject(session); }
                }
            }
            return lines.ToArray();
        }
    }
}
'@

# ---------------------------------------------------------------------------------------------
# Yleiset apufunktiot
# ---------------------------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 1MB)) {
            Move-Item -Path $script:LogFile -Destination ($script:LogFile + '.old') -Force
        }
        Add-Content -Path $script:LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message) -Encoding UTF8
    } catch { }
}

function Initialize-Types {
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw "PowerShell on tilassa '$($ExecutionContext.SessionState.LanguageMode)'. Skripti tarvitsee FullLanguage-tilan (Add-Type). Tarkista asia IT:ltä."
    }
    if (-not ('TeamsKuulokkeetAudio.Audio' -as [type])) {
        Add-Type -TypeDefinition $script:CSharp -Language CSharp
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

function New-AppIcon {
    # Kuulokekuvake Windowsin omasta ikonifontista sinisellä pohjalla (näkyy sekä vaaleassa että tummassa teemassa).
    try {
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 70, 80, 200))
        $g.FillEllipse($bg, 0, 0, 31, 31)
        $font = $null
        foreach ($family in @('Segoe Fluent Icons', 'Segoe MDL2 Assets')) {
            $candidate = New-Object System.Drawing.Font($family, 15, [System.Drawing.GraphicsUnit]::Pixel)
            if ($candidate.Name -eq $family) { $font = $candidate; break }
            $candidate.Dispose()
        }
        if ($font) {
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $g.DrawString([string][char]0xE7F6, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 1, 32, 32)), $sf)
        }
        $g.Dispose()
        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    } catch {
        return [System.Drawing.SystemIcons]::Information
    }
}

function Get-HeadsetStatus { [TeamsKuulokkeetAudio.Audio]::GetStatus($HeadsetName) }

function Format-Hotkey {
    param([string]$Value)
    (($Value -split '\+') | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1).ToLower() }) -join '+'
}

# ---------------------------------------------------------------------------------------------
# Valvonta (tray)
# ---------------------------------------------------------------------------------------------
function Show-Balloon {
    param([string]$Title, [string]$Text, [string]$Kind = 'Info')
    if ($script:Notify) {
        $script:Notify.ShowBalloonTip(5000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::$Kind)
    }
}

function Start-Connect {
    param([string]$Source)
    try {
        $st = Get-HeadsetStatus
        if (-not $st.Found) {
            Write-Log "Yhdistä ($Source): laitetta '$HeadsetName' ei löytynyt"
            Show-Balloon $script:AppName "Paritettua laitetta '$HeadsetName' ei löytynyt. Parita kuulokkeet ensin Windowsin Bluetooth-asetuksissa." 'Warning'
            return
        }
        if ($st.Connected) {
            Show-Balloon $script:AppName "$HeadsetName on jo yhdistetty tähän koneeseen."
            return
        }
        $detail = [TeamsKuulokkeetAudio.Audio]::Connect($HeadsetName)
        Write-Log "Yhdistä ($Source): pyyntö lähetetty ($detail)"
        Show-Balloon $script:AppName "Yhdistetään $HeadsetName..."
        $script:VerifyMode = 'connect'
        $script:VerifyTries = 0
        $script:VerifyTimer.Start()
    } catch {
        Write-Log "Yhdistä ($Source) virhe: $($_.Exception.Message)"
        Show-Balloon $script:AppName "Yhdistäminen epäonnistui: $($_.Exception.Message)" 'Error'
    }
}

function Start-Disconnect {
    try {
        $st = Get-HeadsetStatus
        if (-not $st.Connected) {
            Show-Balloon $script:AppName "$HeadsetName ei ole yhdistettynä tähän koneeseen."
            return
        }
        $detail = [TeamsKuulokkeetAudio.Audio]::Disconnect($HeadsetName)
        Write-Log "Irrota: pyyntö lähetetty ($detail)"
        # Ei kysytä heti uudelleen, jos Teams-ääni jatkuu (käyttäjä irrotti tarkoituksella).
        $script:Suppressed = $true
        $script:VerifyMode = 'disconnect'
        $script:VerifyTries = 0
        $script:VerifyTimer.Start()
    } catch {
        Write-Log "Irrota virhe: $($_.Exception.Message)"
        Show-Balloon $script:AppName "Irrottaminen epäonnistui: $($_.Exception.Message)" 'Error'
    }
}

function Close-Prompt {
    if ($script:PromptForm) { $script:PromptForm.Close() }   # FormClosed-käsittelijä siivoaa
}

function Show-ConnectPrompt {
    if ($script:PromptForm) { $script:PromptForm.Activate(); return }

    $font = New-Object System.Drawing.Font('Segoe UI', 10)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Teams - $HeadsetName"
    $f.Font = $font
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.TopMost = $true
    $f.ShowInTaskbar = $true
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ClientSize = New-Object System.Drawing.Size(400, 150)
    $f.Icon = $script:AppIcon

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Teams soi tai kokous alkoi.`r`nYhdistetäänkö $HeadsetName tähän koneeseen?"
    $lbl.SetBounds(14, 10, 380, 62)
    $f.Controls.Add($lbl)

    $btnYes = New-Object System.Windows.Forms.Button
    $btnYes.Text = 'Yhdistä'
    $btnYes.SetBounds(14, 78, 120, 34)
    $btnYes.Add_Click({ Write-Log 'Kysely: Yhdistä'; Close-Prompt; Start-Connect 'kysely' })
    $f.Controls.Add($btnYes)

    $btnNo = New-Object System.Windows.Forms.Button
    $btnNo.Text = 'Ei'
    $btnNo.SetBounds(142, 78, 100, 34)
    $btnNo.Add_Click({ Write-Log 'Kysely: Ei'; Close-Prompt })
    $f.Controls.Add($btnNo)

    $btnSnooze = New-Object System.Windows.Forms.Button
    $btnSnooze.Text = 'Ei tuntiin'
    $btnSnooze.SetBounds(250, 78, 136, 34)
    $btnSnooze.Add_Click({
        $script:SnoozeUntil = (Get-Date).AddHours(1)
        Write-Log 'Kysely: Ei tuntiin'
        Close-Prompt
        Show-Balloon $script:AppName ('Kysely tauolla klo {0:HH:mm} asti.' -f $script:SnoozeUntil)
    })
    $f.Controls.Add($btnSnooze)

    $script:PromptCountdown = New-Object System.Windows.Forms.Label
    $script:PromptCountdown.ForeColor = [System.Drawing.Color]::Gray
    $script:PromptCountdown.SetBounds(14, 120, 380, 22)
    $f.Controls.Add($script:PromptCountdown)

    $f.AcceptButton = $btnYes
    $f.CancelButton = $btnNo
    $f.Add_FormClosed({
        $script:PromptTimer.Stop()
        $script:PromptForm = $null
    })

    # Oikeaan yläkulmaan, ettei peitä Teamsin omaa puheluilmoitusta (oikea alakulma).
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f.Location = New-Object System.Drawing.Point(($wa.Right - $f.Width - 16), ($wa.Top + 16))

    $script:PromptRemaining = $PromptTimeoutSeconds
    $script:PromptCountdown.Text = "Sulkeutuu itsestään $($script:PromptRemaining) s kuluttua"
    $script:PromptForm = $f
    $f.Show()
    $f.Activate()
    $script:PromptTimer.Start()
    [System.Media.SystemSounds]::Asterisk.Play()
}

function Invoke-MonitorTick {
    if (-not $script:Enabled) { return }
    $now = Get-Date

    $peak = [TeamsKuulokkeetAudio.Audio]::TeamsPeak($TeamsProcessNames)
    $loud = ($peak -ge $PeakThreshold)
    $script:Samples.Enqueue($loud)
    while ($script:Samples.Count -gt $script:WindowSamples) { [void]$script:Samples.Dequeue() }
    if ($loud) { $script:LastLoud = $now }

    if ($script:Suppressed -and (($now - $script:LastLoud).TotalSeconds -ge $QuietResetSeconds)) {
        $script:Suppressed = $false
    }
    if ($script:Suppressed -or $script:PromptForm -or ($now -lt $script:SnoozeUntil)) { return }

    $loudCount = 0
    foreach ($s in $script:Samples) { if ($s) { $loudCount++ } }
    if ($loudCount -lt $script:NeededSamples) { return }

    # Teamsista kuuluu ääntä: kysytään kerran, kunnes Teams on taas ollut hiljaa.
    $script:Suppressed = $true
    $st = Get-HeadsetStatus
    if (-not $st.Found) {
        Write-Log "Teams-ääni havaittu, mutta laitetta '$HeadsetName' ei löytynyt"
        return
    }
    if ($st.Connected) {
        Write-Log 'Teams-ääni havaittu, kuulokkeet jo yhdistetty'
        return
    }
    Write-Log ('Teams-ääni havaittu (huippu {0:0.000}) -> kysely' -f $peak)
    Show-ConnectPrompt
}

function Start-Monitor {
    $created = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, $script:MutexName, [ref]$created)
    if (-not $created) {
        Write-Host 'Valvonta on jo käynnissä (katso ilmaisinalueen kuuloke-ikoni).'
        return
    }
    # Asennus/poisto pyytää valvontaa lopettamaan tämän nimetyn tapahtuman kautta.
    $script:StopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $script:StopEventName)
    [void]$script:StopEvent.Reset()

    $intervalMs = 250
    $script:WindowSamples = [int][math]::Ceiling(([math]::Max(3.0, $SoundSeconds + 1.0) * 1000) / $intervalMs)
    $script:NeededSamples = [int][math]::Ceiling(($SoundSeconds * 1000) / $intervalMs)
    $script:Samples = New-Object 'System.Collections.Generic.Queue[bool]'
    $script:LastLoud = [datetime]::MinValue
    $script:SnoozeUntil = [datetime]::MinValue
    $script:Suppressed = $false
    $script:Enabled = $true
    $script:PromptForm = $null
    $script:LastTickError = ''

    [System.Windows.Forms.Application]::EnableVisualStyles()
    $script:AppIcon = New-AppIcon

    # Kyselyn lähtölaskenta
    $script:PromptTimer = New-Object System.Windows.Forms.Timer
    $script:PromptTimer.Interval = 1000
    $script:PromptTimer.Add_Tick({
        $script:PromptRemaining--
        if ($script:PromptCountdown) { $script:PromptCountdown.Text = "Sulkeutuu itsestään $($script:PromptRemaining) s kuluttua" }
        if ($script:PromptRemaining -le 0) { Write-Log 'Kysely: aikakatkaisu'; Close-Prompt }
    })

    # Yhdistämisen / irrottamisen varmistus (max 12 s)
    $script:VerifyMode = 'connect'
    $script:VerifyTimer = New-Object System.Windows.Forms.Timer
    $script:VerifyTimer.Interval = 1000
    $script:VerifyTimer.Add_Tick({
        try {
            $script:VerifyTries++
            $st = Get-HeadsetStatus
            if ($script:VerifyMode -eq 'connect') {
                if ($st.Connected) {
                    $script:VerifyTimer.Stop()
                    Write-Log 'Yhdistetty'
                    Show-Balloon $script:AppName "$HeadsetName yhdistetty."
                } elseif ($script:VerifyTries -ge 12) {
                    $script:VerifyTimer.Stop()
                    Write-Log 'Yhdistäminen ei valmistunut 12 s:ssa'
                    Show-Balloon $script:AppName "$HeadsetName ei yhdistynyt. Ovatko kuulokkeet korvilla tai kotelo auki? Puhelimen aktiivinen puhelu voi myös pitää ne." 'Warning'
                }
            } else {
                if (-not $st.Connected) {
                    $script:VerifyTimer.Stop()
                    Write-Log 'Irrotettu'
                    Show-Balloon $script:AppName "$HeadsetName irrotettu tästä koneesta. Valitse ne puhelimen Bluetooth-asetuksista, jos ne eivät siirry sinne itsestään."
                } elseif ($script:VerifyTries -eq 4) {
                    # Toinen yritys: osa kuulokkeista avaa yhteyden heti uudelleen tai profiili jää auki.
                    try {
                        $detail = [TeamsKuulokkeetAudio.Audio]::Disconnect($HeadsetName)
                        Write-Log "Irrota: uusi yritys ($detail)"
                    } catch { Write-Log "Irrota: uusi yritys epäonnistui: $($_.Exception.Message)" }
                } elseif ($script:VerifyTries -ge 12) {
                    $script:VerifyTimer.Stop()
                    Write-Log "Irrottaminen ei onnistunut 12 s:ssa (päätepisteet: $($st.EndpointNames))"
                    Show-Balloon $script:AppName "$HeadsetName ei irronnut. Kuulokkeet voivat yhdistyä automaattisesti takaisin. Valitse ne puhelimesta tai irrota Windowsin Bluetooth-asetuksista." 'Warning'
                }
            }
        } catch { $script:VerifyTimer.Stop() }
    })

    # Valvonta
    $script:MonitorTimer = New-Object System.Windows.Forms.Timer
    $script:MonitorTimer.Interval = $intervalMs
    $script:MonitorTimer.Add_Tick({
        if ($script:StopEvent.WaitOne(0)) {
            Write-Log 'Valvonta lopetettu (asennus/poisto)'
            $script:MonitorTimer.Stop()
            $script:Notify.Visible = $false
            [System.Windows.Forms.Application]::Exit()
            return
        }
        try { Invoke-MonitorTick }
        catch {
            $msg = $_.Exception.Message
            if ($msg -ne $script:LastTickError) { Write-Log "Valvontavirhe: $msg"; $script:LastTickError = $msg }
        }
    })

    # Tray-ikoni ja valikko
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miConnect = $menu.Items.Add("Yhdistä $HeadsetName nyt")
    $miConnect.Font = New-Object System.Drawing.Font($miConnect.Font, [System.Drawing.FontStyle]::Bold)
    $miConnect.Add_Click({ Start-Connect 'valikko' })
    $miDisconnect = $menu.Items.Add("Irrota $HeadsetName tästä koneesta")
    $miDisconnect.Add_Click({ Start-Disconnect })
    $script:MenuConnect = $miConnect
    $script:MenuDisconnect = $miDisconnect
    # Valikon avautuessa näytetään vain järkevä toiminto (yhdistä / irrota) kuulokkeiden tilan mukaan.
    $menu.Add_Opening({
        try {
            $st = Get-HeadsetStatus
            $script:MenuConnect.Enabled = -not $st.Connected
            $script:MenuDisconnect.Enabled = [bool]$st.Connected
        } catch {
            $script:MenuConnect.Enabled = $true
            $script:MenuDisconnect.Enabled = $true
        }
    })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miEnabled = New-Object System.Windows.Forms.ToolStripMenuItem('Kysy Teams-puheluissa')
    $miEnabled.CheckOnClick = $true
    $miEnabled.Checked = $true
    $miEnabled.Add_CheckedChanged({ $script:Enabled = $this.Checked; Write-Log "Kysely päällä: $($this.Checked)" })
    [void]$menu.Items.Add($miEnabled)
    $miTest = $menu.Items.Add('Testaa kysely')
    $miTest.Add_Click({ Show-ConnectPrompt })
    $miChange = $menu.Items.Add('Vaihda kuulokkeet...')
    $miChange.Add_Click({
        $path = $script:InstalledPath
        if (-not (Test-Path $path)) { $path = $PSCommandPath }
        Start-Process -FilePath $script:PsExe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$path`" -Install"
    })
    $miLog = $menu.Items.Add('Avaa loki')
    $miLog.Add_Click({ if (Test-Path $script:LogFile) { Start-Process notepad.exe -ArgumentList "`"$($script:LogFile)`"" } })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miExit = $menu.Items.Add('Lopeta')
    $miExit.Add_Click({
        Write-Log 'Valvonta lopetettu'
        $script:MonitorTimer.Stop()
        $script:Notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })

    $script:Notify = New-Object System.Windows.Forms.NotifyIcon
    $script:Notify.Icon = $script:AppIcon
    $tip = "$($script:AppName): $HeadsetName"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }   # NotifyIcon-tekstin raja
    $script:Notify.Text = $tip
    $script:Notify.ContextMenuStrip = $menu
    $script:Notify.Add_MouseDoubleClick({ Start-Connect 'tuplaklikkaus' })
    $script:Notify.Visible = $true

    $st = Get-HeadsetStatus
    if (-not $st.Found) {
        Show-Balloon $script:AppName "Valvonta käynnissä, mutta paritettua laitetta '$HeadsetName' ei löytynyt. Parita kuulokkeet tai valitse ne uudelleen ikonin valikosta (Vaihda kuulokkeet)." 'Warning'
    } elseif ($Welcome) {
        Show-Balloon $script:AppName "Valvonta käynnissä ($HeadsetName). Pikanäppäin $(Format-Hotkey $Hotkey) yhdistää kuulokkeet heti."
    }
    Write-Log "Valvonta käynnistyi (laite '$HeadsetName', löytyi: $($st.Found), päätepisteet: $($st.EndpointNames))"

    $script:MonitorTimer.Start()
    try {
        [System.Windows.Forms.Application]::Run()
    } finally {
        $script:MonitorTimer.Stop()
        $script:Notify.Visible = $false
        $script:Notify.Dispose()
        $script:StopEvent.Dispose()
        $script:Mutex.ReleaseMutex()
    }
}

# ---------------------------------------------------------------------------------------------
# Pikanäppäintoiminto: yhdistä heti
# ---------------------------------------------------------------------------------------------
function Wait-UI {
    param([int]$Milliseconds)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Milliseconds) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
}

function Invoke-ConnectNow {
    $script:Notify = New-Object System.Windows.Forms.NotifyIcon
    $script:Notify.Icon = New-AppIcon
    $script:Notify.Text = $script:AppName
    $script:Notify.Visible = $true
    try {
        $st = Get-HeadsetStatus
        if (-not $st.Found) {
            Show-Balloon $script:AppName "Paritettua laitetta '$HeadsetName' ei löytynyt." 'Warning'
            Wait-UI 5000; return
        }
        if ($st.Connected) {
            Show-Balloon $script:AppName "$HeadsetName on jo yhdistetty."
            Wait-UI 3000; return
        }
        $detail = [TeamsKuulokkeetAudio.Audio]::Connect($HeadsetName)
        Write-Log "Yhdistä (pikanäppäin): pyyntö lähetetty ($detail)"
        Show-Balloon $script:AppName "Yhdistetään $HeadsetName..."
        $ok = $false
        for ($i = 0; $i -lt 24 -and -not $ok; $i++) {
            Wait-UI 500
            $ok = (Get-HeadsetStatus).Connected
        }
        if ($ok) {
            Write-Log 'Yhdistetty (pikanäppäin)'
            Show-Balloon $script:AppName "$HeadsetName yhdistetty."
        } else {
            Write-Log 'Yhdistäminen ei valmistunut 12 s:ssa (pikanäppäin)'
            Show-Balloon $script:AppName "$HeadsetName ei yhdistynyt. Ovatko kuulokkeet korvilla tai kotelo auki?" 'Warning'
        }
        Wait-UI 4000
    } catch {
        Write-Log "Yhdistä (pikanäppäin) virhe: $($_.Exception.Message)"
        Show-Balloon $script:AppName "Virhe: $($_.Exception.Message)" 'Error'
        Wait-UI 5000
    } finally {
        $script:Notify.Visible = $false
        $script:Notify.Dispose()
    }
}

# ---------------------------------------------------------------------------------------------
# Diagnostiikka
# ---------------------------------------------------------------------------------------------
function Invoke-Diagnose {
    Write-Host "Diagnostiikka. Pyydä joku soittamaan Teams-puhelu tai liity testikokoukseen. Ctrl+C lopettaa.`n" -ForegroundColor Cyan
    Write-Host "Kaikki paritetut Bluetooth-äänilaitteet:" -ForegroundColor Yellow
    $all = [TeamsKuulokkeetAudio.Audio]::DebugEndpoints('')
    if ($all.Count -eq 0) { Write-Host '  (ei yhtään)' } else { $all | ForEach-Object { Write-Host "  $_" } }
    Write-Host ''
    while ($true) {
        Write-Host ('--- {0:HH:mm:ss} ---' -f (Get-Date)) -ForegroundColor Yellow
        $eps = [TeamsKuulokkeetAudio.Audio]::DebugEndpoints($HeadsetName)
        if ($eps.Count -eq 0) { Write-Host "  Laitetta '$HeadsetName' ei löytynyt." -ForegroundColor Red }
        else { $eps | ForEach-Object { Write-Host "  $_" } }
        $sessions = [TeamsKuulokkeetAudio.Audio]::DebugSessions($TeamsProcessNames)
        if ($sessions.Count -eq 0) { Write-Host '  (ei aktiivisia äänisessioita)' } else { $sessions | ForEach-Object { Write-Host "  $_" } }
        $peak = [TeamsKuulokkeetAudio.Audio]::TeamsPeak($TeamsProcessNames)
        $color = 'Gray'
        if ($peak -ge $PeakThreshold) { $color = 'Green' }
        Write-Host ('  => Teams-huippu: {0:0.000} (raja {1})' -f $peak, $PeakThreshold) -ForegroundColor $color
        Start-Sleep -Seconds 1
    }
}

# ---------------------------------------------------------------------------------------------
# Asennus / poisto. Kaikki käyttäjäkohtaista: ei järjestelmänvalvojan oikeuksia.
# Asennus kirjoittaa: %LOCALAPPDATA%\TeamsKuulokkeet, Käynnistä-valikon kansion, Käynnistys-kansion
# pikakuvakkeen ja Asennetut sovellukset -merkinnän (HKCU\...\Uninstall\TeamsKuulokkeet).
# ---------------------------------------------------------------------------------------------
function Get-ShortcutPaths {
    $programs = [Environment]::GetFolderPath('Programs')
    $menuDir = Join-Path $programs $script:AppName
    @{
        Startup    = Join-Path ([Environment]::GetFolderPath('Startup')) 'Teams-kuulokevalvonta.lnk'
        MenuDir    = $menuDir
        Connect    = Join-Path $menuDir 'Yhdistä kuulokkeet.lnk'
        Monitor    = Join-Path $menuDir 'Käynnistä valvonta.lnk'
        Change     = Join-Path $menuDir 'Vaihda kuulokkeet.lnk'
        Diagnose   = Join-Path $menuDir 'Vianmääritys.lnk'
        Remove     = Join-Path $menuDir 'Poista Teams-kuulokkeet.lnk'
        OldConnect = Join-Path $programs 'Yhdistä kuulokkeet.lnk'   # versio 1.0
    }
}

function Get-PsArguments {
    param([string]$ScriptPath, [bool]$Hidden, [string]$Extra = '')
    $a = '-NoProfile -STA -ExecutionPolicy Bypass'
    if ($Hidden) { $a += ' -WindowStyle Hidden' }
    $a += " -File `"$ScriptPath`""
    if ($Extra) { $a += " $Extra" }
    return $a
}

function New-AppShortcut {
    param([string]$Path, [string]$ScriptPath, [bool]$Hidden, [string]$Extra, [string]$Description, [string]$ShortcutHotkey)
    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut($Path)
    $lnk.TargetPath = $script:PsExe
    $lnk.Arguments = Get-PsArguments -ScriptPath $ScriptPath -Hidden $Hidden -Extra $Extra
    $lnk.WorkingDirectory = $script:InstallDir
    if ($Hidden) { $lnk.WindowStyle = 7 } else { $lnk.WindowStyle = 1 }
    $lnk.IconLocation = (Join-Path $env:SystemRoot 'System32\SndVol.exe') + ',0'
    $lnk.Description = $Description
    if ($ShortcutHotkey) { $lnk.Hotkey = $ShortcutHotkey }
    $lnk.Save()
}

function Remove-AppShortcuts {
    $p = Get-ShortcutPaths
    foreach ($item in @($p.Startup, $p.OldConnect)) {
        if (Test-Path -LiteralPath $item) { Remove-Item -LiteralPath $item -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $p.MenuDir) { Remove-Item -LiteralPath $p.MenuDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Stop-RunningMonitor {
    # 1) Pyydetään käynnissä olevaa valvontaa lopettamaan siististi.
    try {
        $ev = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $script:StopEventName)
        [void]$ev.Set()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 4000) {
            $m = $null
            if (-not [System.Threading.Mutex]::TryOpenExisting($script:MutexName, [ref]$m)) { break }
            $m.Dispose()
            Start-Sleep -Milliseconds 250
        }
        [void]$ev.Reset()
        $ev.Dispose()
    } catch { }
    # 2) Varmistus: vanhat versiot tai jumiutunut prosessi.
    try {
        Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop |
            Where-Object {
                $_.ProcessId -ne $PID -and $_.CommandLine -and
                $_.CommandLine -like '*TeamsKuulokkeet.ps1*' -and
                $_.CommandLine -notlike '*-Install*' -and $_.CommandLine -notlike '*-Uninstall*'
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Select-Headset {
    $names = @([TeamsKuulokkeetAudio.Audio]::ListDeviceNames())
    $current = $null
    if ($script:Config -and $script:Config.HeadsetName) { $current = [string]$script:Config.HeadsetName }

    if ($names.Count -gt 0) {
        $default = 0
        $found = $false
        for ($i = 0; $i -lt $names.Count; $i++) {
            if ($current -and $names[$i] -eq $current) { $default = $i; $found = $true }
        }
        if (-not $found) {
            for ($i = $names.Count - 1; $i -ge 0; $i--) { if ($names[$i] -like '*AirPods*') { $default = $i } }
        }
        Write-Host 'Koneeseen paritetut Bluetooth-kuulokkeet:' -ForegroundColor Yellow
        for ($i = 0; $i -lt $names.Count; $i++) {
            $mark = ''
            if ($current -and $names[$i] -eq $current) { $mark = '   (nykyinen valinta)' }
            Write-Host ('  [{0}] {1}{2}' -f ($i + 1), $names[$i], $mark)
        }
        Write-Host ''
        Write-Host "Kirjoita numero ja paina Enter. Pelkkä Enter valitsee [$($default + 1)]."
        Write-Host 'Voit myös kirjoittaa kuulokkeiden nimen tai osan siitä. Q peruuttaa.'
    } else {
        Write-Host 'Koneeseen ei ole paritettu yhtään Bluetooth-kuuloketta.' -ForegroundColor Yellow
        Write-Host 'Parita kuulokkeet ensin: Asetukset > Bluetooth ja laitteet > Lisää laite, ja aja asennus sitten uudelleen.'
        Write-Host 'Voit myös kirjoittaa kuulokkeiden nimen nyt (esim. AirPods). Pelkkä Enter peruuttaa.'
    }

    while ($true) {
        $answer = (Read-Host 'Valinta').Trim()
        if ($answer -eq '') {
            if ($names.Count -gt 0) { return $names[$default] }
            return $null
        }
        if ($answer -eq 'q' -or $answer -eq 'Q') { return $null }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n)) {
            if ($n -ge 1 -and $n -le $names.Count) { return $names[$n - 1] }
            Write-Host "Anna numero väliltä 1-$($names.Count)." -ForegroundColor Red
            continue
        }
        return $answer
    }
}

# Aiempien versioiden Asennetut sovellukset -merkinnät (eri avainnimellä, sama näyttönimi).
function Remove-OldUninstallEntries {
    $root = Split-Path $script:UninstallKey -Parent
    $own = Split-Path $script:UninstallKey -Leaf
    try {
        Get-ChildItem -Path $root -ErrorAction Stop | ForEach-Object {
            $dn = $null
            try { $dn = (Get-ItemProperty -Path $_.PSPath -Name DisplayName -ErrorAction Stop).DisplayName } catch { }
            if ($dn -eq $script:AppName -and $_.PSChildName -ne $own) {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

function Register-Uninstall {
    param([string]$ScriptPath)
    $key = $script:UninstallKey
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    $uninstall = "`"$($script:PsExe)`" " + (Get-PsArguments -ScriptPath $ScriptPath -Hidden $true -Extra '-Uninstall -FromSettings')
    $values = @{
        DisplayName     = $script:AppName
        DisplayVersion  = $script:Version
        Comments        = 'Kysyy Teams-puhelun alkaessa, yhdistetäänkö Bluetooth-kuulokkeet tähän koneeseen.'
        InstallLocation = $script:InstallDir
        InstallDate     = (Get-Date -Format 'yyyyMMdd')
        DisplayIcon     = (Join-Path $env:SystemRoot 'System32\SndVol.exe') + ',0'
        UninstallString = $uninstall
    }
    foreach ($k in $values.Keys) { New-ItemProperty -Path $key -Name $k -Value $values[$k] -PropertyType String -Force | Out-Null }
    foreach ($k in @('NoModify', 'NoRepair')) { New-ItemProperty -Path $key -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'EstimatedSize' -Value 100 -PropertyType DWord -Force | Out-Null
}

function Install-App {
    $Host.UI.RawUI.WindowTitle = "$($script:AppName) $($script:Version) - asennus"
    Write-Host ''
    Write-Host "  $($script:AppName) $($script:Version) - asennus" -ForegroundColor Cyan
    Write-Host '  Kysyy Teams-puhelun alkaessa, yhdistetäänkö kuulokkeet tähän koneeseen.'
    Write-Host ''

    Initialize-Types
    $name = Select-Headset
    if (-not $name) {
        Write-Host ''
        Write-Host 'Asennus peruttu. Mitään ei muutettu.' -ForegroundColor Yellow
        return $false
    }
    $HeadsetName = $name
    Write-Host ''
    Write-Host "Valittu: $HeadsetName" -ForegroundColor Green

    Write-Host 'Pysäytetään mahdollinen aiempi valvonta...'
    Stop-RunningMonitor

    Write-Host "Kopioidaan tiedostot kansioon $($script:InstallDir)..."
    if (-not (Test-Path $script:InstallDir)) { New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null }
    if ($PSCommandPath -ne $script:InstalledPath) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $script:InstalledPath -Force
    }
    try { Unblock-File -LiteralPath $script:InstalledPath -ErrorAction SilentlyContinue } catch { }

    $cfg = [ordered]@{ HeadsetName = $HeadsetName; Hotkey = $Hotkey; Version = $script:Version }
    ($cfg | ConvertTo-Json) | Set-Content -Path $script:ConfigFile -Encoding UTF8

    Write-Host 'Luodaan pikakuvakkeet...'
    Remove-AppShortcuts
    $p = Get-ShortcutPaths
    New-Item -ItemType Directory -Path $p.MenuDir -Force | Out-Null
    $s = $script:InstalledPath
    New-AppShortcut -Path $p.Startup  -ScriptPath $s -Hidden $true  -Extra ''            -Description 'Teams-kuulokkeiden valvonta (käynnistyy kirjautuessa)'
    New-AppShortcut -Path $p.Monitor  -ScriptPath $s -Hidden $true  -Extra ''            -Description 'Käynnistää Teams-kuulokkeiden valvonnan'
    New-AppShortcut -Path $p.Connect  -ScriptPath $s -Hidden $true  -Extra '-ConnectNow' -Description 'Yhdistää kuulokkeet tähän koneeseen' -ShortcutHotkey $Hotkey
    New-AppShortcut -Path $p.Change   -ScriptPath $s -Hidden $false -Extra '-Install'    -Description 'Valitse kuulokkeet uudelleen'
    New-AppShortcut -Path $p.Diagnose -ScriptPath $s -Hidden $false -Extra '-Diagnose'   -Description 'Näyttää kuulokkeiden ja Teamsin äänen tilan'
    New-AppShortcut -Path $p.Remove   -ScriptPath $s -Hidden $false -Extra '-Uninstall'  -Description 'Poistaa Teams-kuulokkeet'

    Write-Host 'Lisätään Asennetut sovellukset -listaan...'
    Remove-OldUninstallEntries
    Register-Uninstall -ScriptPath $s

    Write-Host 'Käynnistetään valvonta...'
    Start-Process -FilePath $script:PsExe -ArgumentList (Get-PsArguments -ScriptPath $s -Hidden $true -Extra '-Welcome') -WindowStyle Hidden
    Write-Log "Asennettu versio $($script:Version), kuulokkeet '$HeadsetName'"

    Write-Host ''
    Write-Host '  Valmis!' -ForegroundColor Green
    Write-Host "  - Kuulokeikoni näkyy ilmaisinalueella (kellon vieressä, tarvittaessa ^-nuolen takana)."
    Write-Host "  - Kun Teams soi, ruudun oikeaan yläkulmaan tulee kysymys: Yhdistä / Ei / Ei tuntiin."
    Write-Host "  - Pikanäppäin $(Format-Hotkey $Hotkey) yhdistää kuulokkeet milloin tahansa."
    Write-Host "  - Käynnistä-valikko > $($script:AppName): vaihda kuulokkeet, vianmääritys, poisto."
    Write-Host ''
    return $true
}

function Uninstall-App {
    if (-not $FromSettings) {
        Write-Host ''
        Write-Host "  $($script:AppName) - poisto" -ForegroundColor Cyan
        Write-Host ''
        $answer = Read-Host 'Poistetaanko Teams-kuulokkeet tästä koneesta? (K/E)'
        if ($answer -notmatch '^\s*[kKyY]') { Write-Host 'Poisto peruttu.'; return }
    }

    # Ettei oma työhakemisto estä asennuskansion poistoa.
    Set-Location -Path $env:TEMP
    [Environment]::CurrentDirectory = $env:TEMP

    Stop-RunningMonitor
    Remove-AppShortcuts
    if (Test-Path $script:UninstallKey) { Remove-Item -Path $script:UninstallKey -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-OldUninstallEntries
    $leftover = $false
    if (Test-Path $script:InstallDir) {
        Remove-Item -LiteralPath $script:InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        $leftover = Test-Path $script:InstallDir
    }

    $msg = 'Teams-kuulokkeet on poistettu.'
    if ($leftover) { $msg += "`r`n`r`nKansiota $($script:InstallDir) ei saatu kokonaan poistettua. Voit poistaa sen käsin." }
    if ($FromSettings) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($msg, $script:AppName, 'OK', 'Information')
    } else {
        Write-Host ''
        Write-Host $msg -ForegroundColor Green
        Write-Host ''
    }
}

function Wait-Enter {
    if (-not $FromSettings) { [void](Read-Host 'Paina Enter sulkeaksesi') }
}

# ---------------------------------------------------------------------------------------------
# Pääohjelma
# ---------------------------------------------------------------------------------------------
if ($Install) {
    try { [void](Install-App) }
    catch {
        Write-Host ''
        Write-Host "Asennus epäonnistui: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "Asennus epäonnistui: $($_.Exception.Message)"
    }
    Wait-Enter
    return
}
if ($Uninstall) {
    try { Uninstall-App }
    catch { Write-Host "Poisto epäonnistui: $($_.Exception.Message)" -ForegroundColor Red }
    Wait-Enter
    return
}

try {
    Initialize-Types
} catch {
    Write-Log "Käynnistys epäonnistui: $($_.Exception.Message)"
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("Käynnistys epäonnistui:`r`n$($_.Exception.Message)", $script:AppName, 'OK', 'Error')
    return
}

if ($Diagnose)   { Invoke-Diagnose; return }
if ($ConnectNow) { Invoke-ConnectNow; return }
Start-Monitor
