import Foundation

/// Builds `autounattend.xml`, the answer file Windows Setup reads from the
/// SILICONWIN tools disc.
///
/// Always included (so Setup works at all in a VM):
///   - Windows 11 hardware-check bypass (no TPM / Secure Boot in the VM)
///   - a hook that installs SiliconWin's guest tools at the end of Setup
/// Included only for automatic setup (and only if the user accepted the
/// Microsoft license terms): disk layout, edition, account, region, OOBE.
enum UnattendXML {
    static func make(for config: VMConfiguration) -> String {
        let setup = config.setup
        let arch = config.guest.architecture.unattendName
        let automatic = setup.enabled && setup.acceptedLicense

        func component(_ name: String, _ body: String) -> String {
            """
                    <component name="\(name)" processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            \(body)
                    </component>
            """
        }

        // MARK: windowsPE

        var bypass = ""
        if config.guest.needsRequirementBypass {
            let checks = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassStorageCheck", "BypassCPUCheck"]
            bypass = checks.enumerated().map { index, value in
                """
                                <RunSynchronousCommand wcm:action="add">
                                    <Order>\(index + 1)</Order>
                                    <Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v \(value) /t REG_DWORD /d 1 /f</Path>
                                </RunSynchronousCommand>
                """
            }.joined(separator: "\n")
        }

        var setupBody = ""
        if !bypass.isEmpty {
            setupBody += """
                            <RunSynchronous>
            \(bypass)
                            </RunSynchronous>

            """
        }
        if automatic {
            setupBody += """
                            <DiskConfiguration>
                                <WillShowUI>OnError</WillShowUI>
                                <Disk wcm:action="add">
                                    <DiskID>0</DiskID>
                                    <WillWipeDisk>true</WillWipeDisk>
                                    <CreatePartitions>
            \(createPartitions(uefi: config.guest.usesUEFI))
                                    </CreatePartitions>
                                    <ModifyPartitions>
            \(modifyPartitions(uefi: config.guest.usesUEFI))
                                    </ModifyPartitions>
                                </Disk>
                            </DiskConfiguration>
                            <ImageInstall>
                                <OSImage>
                                    <InstallFrom>
                                        <MetaData wcm:action="add">
                                            <Key>/IMAGE/NAME</Key>
                                            <Value>\(escape(config.guest.edition))</Value>
                                        </MetaData>
                                    </InstallFrom>
                                    <InstallTo>
                                        <DiskID>0</DiskID>
                                        <PartitionID>\(config.guest.usesUEFI ? 3 : 2)</PartitionID>
                                    </InstallTo>
                                    <WillShowUI>OnError</WillShowUI>
                                </OSImage>
                            </ImageInstall>
                            <UserData>
                                <ProductKey>
                                    <Key>\(config.guest.genericInstallKey)</Key>
                                    <WillShowUI>OnError</WillShowUI>
                                </ProductKey>
                                <AcceptEula>true</AcceptEula>
                                <FullName>\(escape(setup.userName))</FullName>
                                <Organization></Organization>
                            </UserData>

            """
        }

        var windowsPE = ""
        if automatic {
            windowsPE += component("Microsoft-Windows-International-Core-WinPE", """
                            <SetupUILanguage>
                                <UILanguage>\(setup.language)</UILanguage>
                            </SetupUILanguage>
                            <InputLocale>0409:00000409</InputLocale>
                            <SystemLocale>\(setup.language)</SystemLocale>
                            <UILanguage>\(setup.language)</UILanguage>
                            <UserLocale>\(setup.language)</UserLocale>
            """) + "\n"
        }
        if !setupBody.isEmpty {
            windowsPE += component("Microsoft-Windows-Setup", setupBody)
        }

        // MARK: specialize — install the guest-tools hook (runs as SYSTEM at
        // the end of Setup via SetupComplete.cmd, for both setup modes).

        let hook = "cmd.exe /c \"mkdir %WINDIR%\\Setup\\Scripts 2>nul &amp; for %d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %d:\\SiliconWin\\SetupComplete.cmd copy /y %d:\\SiliconWin\\SetupComplete.cmd %WINDIR%\\Setup\\Scripts\\SetupComplete.cmd\""
        var specialize = component("Microsoft-Windows-Deployment", """
                        <RunSynchronous>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>1</Order>
                                <Path>\(hook)</Path>
                            </RunSynchronousCommand>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>2</Order>
                                <Path>reg.exe add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                        </RunSynchronous>
        """)
        if automatic {
            specialize += "\n" + component("Microsoft-Windows-Shell-Setup", """
                            <ComputerName>\(escape(setup.computerName))</ComputerName>
                            <TimeZone>\(escape(setup.timeZone))</TimeZone>
                            <RegisteredOwner>\(escape(setup.userName))</RegisteredOwner>
            """)
        }

        // MARK: oobeSystem

        var oobe = ""
        if automatic {
            let password = """
                                    <Password>
                                        <Value>\(escape(setup.password))</Value>
                                        <PlainText>true</PlainText>
                                    </Password>
            """
            oobe = component("Microsoft-Windows-International-Core", """
                            <InputLocale>\(escape(setup.inputLocales))</InputLocale>
                            <SystemLocale>\(setup.language)</SystemLocale>
                            <UILanguage>\(setup.language)</UILanguage>
                            <UserLocale>\(setup.language)</UserLocale>
            """) + "\n" + component("Microsoft-Windows-Shell-Setup", """
                            <OOBE>
                                <HideEULAPage>true</HideEULAPage>
                                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                                <ProtectYourPC>3</ProtectYourPC>
                            </OOBE>
                            <UserAccounts>
                                <LocalAccounts>
                                    <LocalAccount wcm:action="add">
                                        <Name>\(escape(setup.userName))</Name>
                                        <DisplayName>\(escape(setup.userName))</DisplayName>
                                        <Group>Administrators</Group>
            \(password)
                                    </LocalAccount>
                                </LocalAccounts>
                            </UserAccounts>
                            <AutoLogon>
                                <Enabled>true</Enabled>
                                <Username>\(escape(setup.userName))</Username>
                                <LogonCount>9999999</LogonCount>
            \(password)
                            </AutoLogon>
                            <TimeZone>\(escape(setup.timeZone))</TimeZone>
            """)
        }

        func pass(_ name: String, _ body: String) -> String {
            body.isEmpty ? "" : "    <settings pass=\"\(name)\">\n\(body)\n    </settings>\n"
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- Generated by SiliconWin for "\(escape(config.name))" (\(config.guest.displayName)). -->
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
        \(pass("windowsPE", windowsPE))\(pass("specialize", specialize))\(pass("oobeSystem", oobe))</unattend>

        """
    }

    private static func createPartitions(uefi: Bool) -> String {
        let partitions: [(String, String)] = uefi
            ? [("EFI", "<Size>260</Size>"), ("MSR", "<Size>16</Size>"), ("Primary", "<Extend>true</Extend>")]
            : [("Primary", "<Size>100</Size>"), ("Primary", "<Extend>true</Extend>")]
        return partitions.enumerated().map { index, partition in
            """
                                        <CreatePartition wcm:action="add">
                                            <Order>\(index + 1)</Order>
                                            <Type>\(partition.0)</Type>
                                            \(partition.1)
                                        </CreatePartition>
            """
        }.joined(separator: "\n")
    }

    private static func modifyPartitions(uefi: Bool) -> String {
        let partitions: [String] = uefi
            ? ["<Label>System</Label><Format>FAT32</Format>", "", "<Label>Windows</Label><Letter>C</Letter><Format>NTFS</Format>"]
            : ["<Label>System Reserved</Label><Format>NTFS</Format><Active>true</Active>", "<Label>Windows</Label><Letter>C</Letter><Format>NTFS</Format>"]
        return partitions.enumerated().map { index, settings in
            """
                                        <ModifyPartition wcm:action="add">
                                            <Order>\(index + 1)</Order>
                                            <PartitionID>\(index + 1)</PartitionID>
                                            \(settings)
                                        </ModifyPartition>
            """
        }.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
